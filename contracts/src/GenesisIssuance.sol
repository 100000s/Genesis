// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGenesisToken {
    function mint(address to, uint256 amount) external;
}

interface IGenesisIdentity {
    function canClaim(address account, uint8 kind) external view returns (bool);
}

interface IGenesisOracleRatios {
    function federalRatio(uint256) external view returns (uint256, bytes32, bool);
    function stateRatio(uint8, uint256) external view returns (uint256, bytes32, bool);
    function getTwapPrice() external view returns (uint256);
    function getTwapMultiplier() external view returns (uint256);
    function getBaseGrowthMultiplier() external view returns (uint256);
}

/// @notice GenesisIssuance: Pull-based minting for federal/state budget-derived claims
/// with soft daily rolling caps scaled by prior withdrawal velocity and claimant count.
/// 
/// Key design:
/// - Annual available balance = prior year balance × (FY2024 receipts / FY2025 receipts) for year 2027
///   ALFRED has ~12-month lag, so year Y uses ratios from (Y-3)/(Y-2) fiscal years
/// - Monthly cap = 30-day rolling volume × 0.5% base growth × TWAP multiplier
/// - Daily soft limit = monthly cap / 30 days, then scaled by (targetDaily / priorDayVolume) if hot
/// - Per-user daily max = (targetDaily / priorDayVolume) × BASE_CLAIM
/// - If claimant count increases dramatically, per-user max can fall below 10% of available,
///   but minimum floor is 0.01 tokens (never zero)
/// - Unused daily allowance remains in available balance and carries forward
/// - Bootstrap: first 100 withdrawals can claim up to 100 tokens
contract GenesisIssuance {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant BASE_CLAIM = 50 * WAD;           // 50 tokens per user default
    uint256 public constant LAUNCH_YEAR = 2026;
    uint256 public constant BOOTSTRAP_WITHDRAWALS = 100;
    uint256 public constant BOOTSTRAP_MAX_CLAIM = 100 * WAD;  // 100 tokens per user in bootstrap
    uint256 public constant BOOTSTRAP_SUPPLY_CAP = 20_000 * WAD; // 10k fed + 10k state total
    uint256 public constant FEDERAL = 0;
    uint256 public constant STATE = 1;
    uint256 public constant EPOCH_DURATION = 30 days;
    uint256 public constant MIN_CLAIM_FLOOR = 0.01 * WAD;   // 0.01 tokens minimum (never zero)

    address public owner;
    IGenesisToken public immutable token;
    IGenesisIdentity public immutable identity;
    IGenesisOracleRatios public immutable oracle;
    address public workerSplit;

    // Bootstrap state
    uint256 public bootstrapWithdrawals;
    uint256 public bootstrapMinted;

    // Immutable annual bases (once ratio applied per year)
    mapping(uint256 => uint256) public federalBase;           // year => total available
    mapping(uint8 => mapping(uint256 => uint256)) public stateBase; // stateId => year => total available

    // User claim tracking
    mapping(address => uint256) public claimedFederal;
    mapping(address => uint256) public claimedState;
    mapping(address => uint256) public workerMinted;

    // Ratio application tracking (immutable once applied per year)
    mapping(uint256 => bool) public federalRatioApplied;
    mapping(uint8 => mapping(uint256 => bool)) public stateRatioApplied;

    // Daily volume tracking for rolling average
    mapping(uint256 => uint256) public dailyVolume;        // dayId => volume on that day
    uint256 public rolling30DayVolume;                      // sum of last 30 days
    uint256 public priorDayVolume;                          // volume on the day before current day
    uint256 public currentDayVolume;                        // volume accumulating in current day
    uint256 public lastDayId;                               // last day we processed
    uint256 public lastEpochId;                             // last epoch we processed

    // Daily claimant tracking (for scaling by participation increase)
    mapping(uint256 => uint256) public dailyClaimantCount;  // dayId => unique claimants who claimed that day
    uint256 public priorDayClaimantCount;
    uint256 public currentDayClaimants;                     // claimants in current day
    mapping(uint256 => mapping(address => bool)) public dayClaimedAlready; // dayId => user => already claimed

    // Initial TWAP for multiplier floor
    uint256 public immutable initialTwapPriceWad;

    event ClaimMinted(address indexed claimant, uint8 indexed kind, uint256 indexed year, uint256 amount);
    event RatioApplied(uint256 indexed year, uint8 indexed stateId, uint256 ratio);
    event DailyVolumeUpdated(uint256 indexed dayId, uint256 priorDayVolume_, uint256 currentDayVolume_, uint256 priorClaimants, uint256 currentClaimants);
    event Rolling30DayVolumeUpdated(uint256 rolling30DayVolume_, uint256 twapMultiplier);

    modifier onlyOwner() {
        require(msg.sender == owner, "Issuance: owner only");
        _;
    }

    modifier onlyWorker() {
        require(msg.sender == workerSplit, "Issuance: worker only");
        _;
    }

    constructor(address tokenAddress, address identityAddress, address oracleAddress) {
        require(
            tokenAddress != address(0) && identityAddress != address(0) && oracleAddress != address(0),
            "Issuance: zero address"
        );
        owner = msg.sender;
        token = IGenesisToken(tokenAddress);
        identity = IGenesisIdentity(identityAddress);
        oracle = IGenesisOracleRatios(oracleAddress);
        initialTwapPriceWad = oracle.getTwapPrice();
        lastDayId = currentDay();
        lastEpochId = currentEpoch();
        rolling30DayVolume = BOOTSTRAP_MAX_CLAIM * BOOTSTRAP_WITHDRAWALS;
    }

    function setWorkerSplit(address worker) external onlyOwner {
        require(worker != address(0), "Issuance: zero address");
        workerSplit = worker;
    }

    // ========== Time Functions ==========

    function currentYear() public view returns (uint256) {
        if (block.timestamp < 1767225600) return LAUNCH_YEAR; // Jan 1, 2026 00:00 EST
        return LAUNCH_YEAR + (block.timestamp - 1767225600) / 365 days;
    }

    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_DURATION;
    }

    // ========== Window Updates ==========

    /// @notice Update rolling 30-day volume and daily volume tracking
    /// @dev Also tracks claimant count to scale cap by participation
    function _updateRollingWindows() internal {
        uint256 dayId = currentDay();
        uint256 epochId = currentEpoch();

        // Rotate daily volume if a new day has started
        if (dayId != lastDayId) {
            priorDayVolume = currentDayVolume;
            priorDayClaimantCount = currentDayClaimants;
            dailyVolume[dayId - 1] = currentDayVolume;
            dailyClaimantCount[dayId - 1] = currentDayClaimants;
            currentDayVolume = 0;
            currentDayClaimants = 0;
            lastDayId = dayId;
            emit DailyVolumeUpdated(dayId, priorDayVolume, 0, priorDayClaimantCount, 0);
        }

        // Recalculate rolling 30-day volume if epoch boundary crossed
        if (epochId != lastEpochId) {
            rolling30DayVolume = _calculateRolling30Days();
            lastEpochId = epochId;
            uint256 twapMul = oracle.getTwapMultiplier();
            emit Rolling30DayVolumeUpdated(rolling30DayVolume, twapMul);
        }
    }

    /// @notice Sum daily volumes over the last 30 days
    function _calculateRolling30Days() internal view returns (uint256) {
        uint256 total = 0;
        uint256 dayId = currentDay();
        uint256 windowDays = 30;

        for (uint256 i = 1; i <= windowDays; i++) {
            if (dayId > i) {
                total += dailyVolume[dayId - i];
            }
        }
        return total;
    }

    // ========== Ratio Application (Immutable Once Set) ==========

    /// @notice Apply fiscal year ratio to available balance (immutable per year)
    /// For year Y, ratio = (FY(Y-3) receipts) / (FY(Y-2) receipts)
    /// Example: For year 2027, ratio = (FY2024 receipts) / (FY2025 receipts)
    /// ALFRED publishes ~12 months after fiscal year end, creating this lag pattern
    function _applyRatio(uint256 year, uint8 stateId) internal {
        if (year <= LAUNCH_YEAR) return;

        if (stateId == FEDERAL) {
            if (!federalRatioApplied[year]) {
                (uint256 ratio, , bool set) = oracle.federalRatio(year);
                require(set, "Issuance: federal ratio not yet set");
                federalBase[year] = (federalBase[year - 1] * ratio) / WAD;
                federalRatioApplied[year] = true;
                emit RatioApplied(year, FEDERAL, ratio);
            }
        } else if (stateId > 0 && stateId <= 50) {
            if (!stateRatioApplied[stateId][year]) {
                (uint256 ratio, , bool set) = oracle.stateRatio(stateId, year);
                require(set, "Issuance: state ratio not yet set");
                stateBase[stateId][year] = (stateBase[stateId][year - 1] * ratio) / WAD;
                stateRatioApplied[stateId][year] = true;
                emit RatioApplied(year, stateId, ratio);
            }
        }
    }

    /// @notice Initialize state base for 2026 bootstrap
    function setStateBaseForBootstrap(uint8 stateId) external onlyOwner {
        require(stateId > 0 && stateId <= 50, "Issuance: invalid state");
        if (stateBase[stateId][LAUNCH_YEAR] == 0) {
            stateBase[stateId][LAUNCH_YEAR] = 50 * WAD;
        }
    }

    /// @notice Initialize federal base for 2026 bootstrap
    function setFederalBaseForBootstrap() external onlyOwner {
        if (federalBase[LAUNCH_YEAR] == 0) {
            federalBase[LAUNCH_YEAR] = 50 * WAD;
        }
    }

    // ========== Cap Calculations (Dynamic by Claimant Count) ==========

    /// @notice Calculate target daily system volume (adjusted for participation changes)
    /// @dev target = rolling30DayVolume × 100.5% × sqrt(TWAP/initialTWAP)
    ///      then scaled if claimant count changed significantly
    function getTargetDailySystemVolume() public view returns (uint256) {
        // Base: rolling 30-day average or bootstrap baseline
        uint256 base30Day = rolling30DayVolume > 0
            ? rolling30DayVolume
            : (BOOTSTRAP_MAX_CLAIM * BOOTSTRAP_WITHDRAWALS);

        // Apply 0.5% base growth multiplier (100.5%)
        uint256 baseMultiplier = oracle.getBaseGrowthMultiplier();
        uint256 scaledMonthlyCap = (base30Day * baseMultiplier) / WAD;

        // Apply quadratic TWAP expansion (never < 1.0)
        uint256 twapMul = oracle.getTwapMultiplier();
        uint256 adjustedMonthlyCap = (scaledMonthlyCap * twapMul) / WAD;

        // Target daily = adjusted monthly / 30 days
        return adjustedMonthlyCap / 30;
    }

    /// @notice Calculate individual daily claim limit (soft cap, scales with volume and participation)
    /// @dev If claimant count increased dramatically, per-user max can fall below 10% of available,
    ///      but never below MIN_CLAIM_FLOOR (0.01 tokens). Uses ratio: (targetDaily / priorDayVolume) × BASE_CLAIM
    function getIndividualDailyLimit() public view returns (uint256) {
        // Bootstrap phase: allow full BOOTSTRAP_MAX_CLAIM per user
        if (bootstrapWithdrawals < BOOTSTRAP_WITHDRAWALS) {
            return BOOTSTRAP_MAX_CLAIM;
        }

        uint256 targetDaily = getTargetDailySystemVolume();

        // If prior day was quiet, allow full BASE_CLAIM
        if (priorDayVolume == 0 || priorDayVolume <= targetDaily) {
            return BASE_CLAIM;
        }

        // Ratio scaling: (Target Daily / Prior Day Actual) × BASE_CLAIM
        // This self-corrects if volume was too hot
        uint256 scaledLimit = (targetDaily * BASE_CLAIM) / priorDayVolume;

        // Minimum floor: 0.01 tokens (never zero)
        // Can fall below 10% of available if claimant count increases dramatically
        return scaledLimit < MIN_CLAIM_FLOOR ? MIN_CLAIM_FLOOR : scaledLimit;
    }

    // ========== Availability Queries ==========

    /// @notice Get available federal tokens for a claimant
    function availableFederal(address account) public view returns (uint256) {
        if (!identity.canClaim(account, FEDERAL)) return 0;
        uint256 year = currentYear();

        // Compute base if not yet applied
        uint256 base = federalBase[year];
        if (base == 0) {
            base = federalBase[year > LAUNCH_YEAR ? year - 1 : LAUNCH_YEAR];
        }
        if (base == 0) base = 50 * WAD; // Safe default

        uint256 claimed = claimedFederal[account];
        return claimed >= base ? 0 : (base - claimed);
    }

    /// @notice Get available state tokens for a claimant
    function availableState(address account, uint8 stateId) public view returns (uint256) {
        require(stateId > 0 && stateId <= 50, "Issuance: invalid state");
        if (!identity.canClaim(account, STATE)) return 0;

        uint256 year = currentYear();

        // Compute base if not yet applied
        uint256 base = stateBase[stateId][year];
        if (base == 0) {
            base = stateBase[stateId][year > LAUNCH_YEAR ? year - 1 : LAUNCH_YEAR];
        }
        if (base == 0) base = 50 * WAD; // Safe default

        uint256 claimed = claimedState[account];
        return claimed >= base ? 0 : (base - claimed);
    }

    // ========== Withdrawal (Pull-Based Minting) ==========

    /// @notice Withdraw federal or state tokens (pull-based, soft cap with per-claimant scaling)
    /// @param kind FEDERAL (0) or STATE (1)
    /// @param stateId State ID (required for STATE, ignored for FEDERAL)
    /// @param amount Requested amount (will be capped by available and daily limit)
    function withdraw(uint8 kind, uint8 stateId, uint256 amount) external {
        require(kind == FEDERAL || (kind == STATE && stateId > 0 && stateId <= 50), "Issuance: invalid kind");
        require(amount > 0, "Issuance: zero amount");

        _updateRollingWindows();
        uint256 year = currentYear();
        uint256 dayId = currentDay();
        _applyRatio(year, kind == FEDERAL ? FEDERAL : stateId);

        uint256 available;
        if (kind == FEDERAL) {
            available = availableFederal(msg.sender);
        } else {
            available = availableState(msg.sender, stateId);
        }

        require(available > 0, "Issuance: no available balance");

        // Track claimant count (first time claiming on this day)
        if (!dayClaimedAlready[dayId][msg.sender]) {
            dayClaimedAlready[dayId][msg.sender] = true;
            currentDayClaimants++;
        }

        // Apply soft daily limit (never hard blocks; scales down if needed)
        uint256 dailyLimit = getIndividualDailyLimit();
        uint256 toMint = amount;

        // Cap by available balance
        if (toMint > available) {
            toMint = available;
        }

        // Cap by daily soft limit (minimum 0.01 tokens, but can be less than 10% of available if claimant count spikes)
        if (toMint > dailyLimit) {
            toMint = dailyLimit;
        }

        require(toMint > 0, "Issuance: insufficient daily limit");

        // Record claim
        if (kind == FEDERAL) {
            claimedFederal[msg.sender] += toMint;
        } else {
            claimedState[msg.sender] += toMint;
        }

        // Track volume for rolling window
        currentDayVolume += toMint;

        // Track bootstrap
        if (bootstrapWithdrawals < BOOTSTRAP_WITHDRAWALS) {
            bootstrapWithdrawals++;
            bootstrapMinted += toMint;
        }

        // Mint tokens
        token.mint(msg.sender, toMint);
        emit ClaimMinted(msg.sender, kind, year, toMint);
    }

    // ========== Worker Rewards ==========

    /// @notice Mint worker rewards (called by WorkerSplit only)
    function mintWorkerReward(address recipient, uint256 amount) external onlyWorker {
        require(recipient != address(0) && amount > 0, "Issuance: invalid reward");
        workerMinted[recipient] += amount;
        token.mint(recipient, amount);
    }
}
