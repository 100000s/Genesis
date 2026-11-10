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
/// The 2026 launch allocation (50 federal + 50 state tokens) remains the active base
/// through July 1, 2027 UTC. Starting on that date, the existing annual ALFRED budget
/// ratio and compounding rules apply unchanged.
contract GenesisIssuance {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant BASE_CLAIM = 50 * WAD;
    uint256 public constant LAUNCH_YEAR = 2026;
    /// @dev 2027-07-01 00:00:00 UTC. Launch-year claims use the 50/50 bases until then.
    uint256 public constant LAUNCH_CLAIM_END = 1_814_400_000;
    uint256 public constant BOOTSTRAP_WITHDRAWALS = 100;
    uint256 public constant BOOTSTRAP_MAX_CLAIM = 100 * WAD;
    uint256 public constant BOOTSTRAP_SUPPLY_CAP = 20_000 * WAD;
    uint256 public constant FEDERAL = 0;
    uint256 public constant STATE = 1;
    uint256 public constant EPOCH_DURATION = 30 days;
    uint256 public constant MIN_CLAIM_FLOOR = 0.01 * WAD;
    uint256 public constant REFERRAL_THRESHOLD = 40 * WAD;
    uint256 public constant REFERRAL_CAP = 100 * WAD;

    address public owner;
    IGenesisToken public immutable token;
    IGenesisIdentity public immutable identity;
    IGenesisOracleRatios public immutable oracle;
    address public workerSplit;

    uint256 public bootstrapWithdrawals;
    uint256 public bootstrapMinted;
    mapping(uint256 => uint256) public federalBase;
    mapping(uint8 => mapping(uint256 => uint256)) public stateBase;
    mapping(address => uint256) public claimedFederal;
    mapping(address => uint256) public claimedState;
    mapping(address => uint256) public workerMinted;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public directReferrals;
    mapping(address => uint256) public referralRewardsEarned;
    mapping(uint256 => bool) public federalRatioApplied;
    mapping(uint8 => mapping(uint256 => bool)) public stateRatioApplied;
    mapping(uint256 => uint256) public dailyVolume;
    uint256 public rolling30DayVolume;
    uint256 public priorDayVolume;
    uint256 public currentDayVolume;
    uint256 public lastDayId;
    uint256 public lastEpochId;
    mapping(uint256 => uint256) public dailyClaimantCount;
    uint256 public priorDayClaimantCount;
    uint256 public currentDayClaimants;
    mapping(uint256 => mapping(address => bool)) public dayClaimedAlready;
    uint256 public immutable initialTwapPriceWad;

    event ClaimMinted(address indexed claimant, uint8 indexed kind, uint256 indexed year, uint256 amount);
    event RatioApplied(uint256 indexed year, uint8 indexed stateId, uint256 ratio);
    event DailyVolumeUpdated(uint256 indexed dayId, uint256 priorDayVolume_, uint256 currentDayVolume_, uint256 priorClaimants, uint256 currentClaimants);
    event Rolling30DayVolumeUpdated(uint256 rolling30DayVolume_, uint256 twapMultiplier);
    event ReferrerSet(address indexed account, address indexed referrer);
    event ReferralRewardMinted(address indexed referrer, address indexed referred, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "Issuance: owner only"); _; }
    modifier onlyWorker() { require(msg.sender == workerSplit, "Issuance: worker only"); _; }

    constructor(address tokenAddress, address identityAddress, address oracleAddress) {
        require(tokenAddress != address(0) && identityAddress != address(0) && oracleAddress != address(0), "Issuance: zero address");
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

    function setReferrer(address account, address referrer) external {
        require(account != address(0) && referrer != address(0), "Issuance: zero address");
        require(account != referrer, "Issuance: self-referral");
        require(msg.sender == owner || msg.sender == account, "Issuance: invalid caller");
        require(referrerOf[account] == address(0), "Issuance: referrer already set");
        referrerOf[account] = referrer;
        directReferrals[referrer] += 1;
        emit ReferrerSet(account, referrer);
    }

    function currentYear() public view returns (uint256) {
        // Preserve the launch-year 50/50 entitlement through July 1, 2027;
        // thereafter continue the pre-existing calendar/ALFRED year calculation.
        if (block.timestamp < LAUNCH_CLAIM_END) return LAUNCH_YEAR;
        if (block.timestamp < 1767225600) return LAUNCH_YEAR;
        return LAUNCH_YEAR + (block.timestamp - 1767225600) / 365 days;
    }

    function currentDay() public view returns (uint256) { return block.timestamp / 1 days; }
    function currentEpoch() public view returns (uint256) { return block.timestamp / EPOCH_DURATION; }

    function _updateRollingWindows() internal {
        uint256 dayId = currentDay();
        uint256 epochId = currentEpoch();
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
        if (epochId != lastEpochId) {
            rolling30DayVolume = _calculateRolling30Days();
            lastEpochId = epochId;
            emit Rolling30DayVolumeUpdated(rolling30DayVolume, oracle.getTwapMultiplier());
        }
    }

    function _calculateRolling30Days() internal view returns (uint256 total) {
        uint256 dayId = currentDay();
        for (uint256 i = 1; i <= 30; i++) if (dayId > i) total += dailyVolume[dayId - i];
    }

    function _applyRatio(uint256 year, uint8 stateId) internal {
        if (year <= LAUNCH_YEAR) return;
        if (stateId == FEDERAL) {
            if (!federalRatioApplied[year]) {
                (uint256 ratio,, bool set) = oracle.federalRatio(year);
                require(set, "Issuance: federal ratio not yet set");
                federalBase[year] = (federalBase[year - 1] * ratio) / WAD;
                federalRatioApplied[year] = true;
                emit RatioApplied(year, FEDERAL, ratio);
            }
        } else if (stateId > 0 && stateId <= 50 && !stateRatioApplied[stateId][year]) {
            (uint256 ratio,, bool set) = oracle.stateRatio(stateId, year);
            require(set, "Issuance: state ratio not yet set");
            stateBase[stateId][year] = (stateBase[stateId][year - 1] * ratio) / WAD;
            stateRatioApplied[stateId][year] = true;
            emit RatioApplied(year, stateId, ratio);
        }
    }

    function setStateBaseForBootstrap(uint8 stateId) external onlyOwner {
        require(stateId > 0 && stateId <= 50, "Issuance: invalid state");
        if (stateBase[stateId][LAUNCH_YEAR] == 0) stateBase[stateId][LAUNCH_YEAR] = 50 * WAD;
    }

    function setFederalBaseForBootstrap() external onlyOwner {
        if (federalBase[LAUNCH_YEAR] == 0) federalBase[LAUNCH_YEAR] = 50 * WAD;
    }

    function getTargetDailySystemVolume() public view returns (uint256) {
        uint256 base30Day = rolling30DayVolume > 0 ? rolling30DayVolume : BOOTSTRAP_MAX_CLAIM * BOOTSTRAP_WITHDRAWALS;
        uint256 scaledMonthlyCap = (base30Day * oracle.getBaseGrowthMultiplier()) / WAD;
        uint256 adjustedMonthlyCap = (scaledMonthlyCap * oracle.getTwapMultiplier()) / WAD;
        return adjustedMonthlyCap / 30;
    }

    function getIndividualDailyLimit() public view returns (uint256) {
        if (bootstrapWithdrawals < BOOTSTRAP_WITHDRAWALS) return BOOTSTRAP_MAX_CLAIM;
        uint256 targetDaily = getTargetDailySystemVolume();
        if (priorDayVolume == 0 || priorDayVolume <= targetDaily) return BASE_CLAIM;
        uint256 scaledLimit = (targetDaily * BASE_CLAIM) / priorDayVolume;
        return scaledLimit < MIN_CLAIM_FLOOR ? MIN_CLAIM_FLOOR : scaledLimit;
    }

    function availableFederal(address account) public view returns (uint256) {
        if (!identity.canClaim(account, FEDERAL)) return 0;
        uint256 year = currentYear();
        uint256 base = federalBase[year];
        if (base == 0) base = federalBase[year > LAUNCH_YEAR ? year - 1 : LAUNCH_YEAR];
        if (base == 0) base = 50 * WAD;
        uint256 claimed = claimedFederal[account];
        return claimed >= base ? 0 : base - claimed;
    }

    function availableState(address account, uint8 stateId) public view returns (uint256) {
        require(stateId > 0 && stateId <= 50, "Issuance: invalid state");
        if (!identity.canClaim(account, STATE)) return 0;
        uint256 year = currentYear();
        uint256 base = stateBase[stateId][year];
        if (base == 0) base = stateBase[stateId][year > LAUNCH_YEAR ? year - 1 : LAUNCH_YEAR];
        if (base == 0) base = 50 * WAD;
        uint256 claimed = claimedState[account];
        return claimed >= base ? 0 : base - claimed;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    function _referralRewardFor(address referrer) internal view returns (uint256) {
        uint256 directCount = directReferrals[referrer];
        if (directCount == 0) return 0;
        if (referralRewardsEarned[referrer] < REFERRAL_CAP) return WAD;
        uint256 reward = _sqrt(directCount) * WAD;
        return reward > REFERRAL_CAP ? REFERRAL_CAP : reward;
    }

    function _processReferralRewards(address claimant) internal {
        address currentReferrer = referrerOf[claimant];
        address[256] memory seen;
        uint256 depth;
        while (currentReferrer != address(0) && depth < seen.length) {
            bool duplicate;
            for (uint256 i; i < depth; i++) if (seen[i] == currentReferrer) { duplicate = true; break; }
            if (duplicate) break;
            seen[depth++] = currentReferrer;
            uint256 reward = _referralRewardFor(currentReferrer);
            if (reward > 0) {
                referralRewardsEarned[currentReferrer] += reward;
                token.mint(currentReferrer, reward);
                emit ReferralRewardMinted(currentReferrer, claimant, reward);
            }
            currentReferrer = referrerOf[currentReferrer];
        }
    }

    function withdraw(uint8 kind, uint8 stateId, uint256 amount) external {
        require(kind == FEDERAL || (kind == STATE && stateId > 0 && stateId <= 50), "Issuance: invalid kind");
        require(amount > 0, "Issuance: zero amount");
        _updateRollingWindows();
        uint256 year = currentYear();
        uint256 dayId = currentDay();
        _applyRatio(year, kind == FEDERAL ? FEDERAL : stateId);
        uint256 available = kind == FEDERAL ? availableFederal(msg.sender) : availableState(msg.sender, stateId);
        require(available > 0, "Issuance: no available balance");
        if (!dayClaimedAlready[dayId][msg.sender]) { dayClaimedAlready[dayId][msg.sender] = true; currentDayClaimants++; }
        uint256 dailyLimit = getIndividualDailyLimit();
        uint256 toMint = amount;
        if (toMint > available) toMint = available;
        if (toMint > dailyLimit) toMint = dailyLimit;
        require(toMint > 0, "Issuance: insufficient daily limit");
        if (kind == FEDERAL) claimedFederal[msg.sender] += toMint;
        else claimedState[msg.sender] += toMint;
        currentDayVolume += toMint;
        if (bootstrapWithdrawals < BOOTSTRAP_WITHDRAWALS) { bootstrapWithdrawals++; bootstrapMinted += toMint; }
        token.mint(msg.sender, toMint);
        emit ClaimMinted(msg.sender, kind, year, toMint);
        if (toMint > REFERRAL_THRESHOLD) _processReferralRewards(msg.sender);
    }

    function mintWorkerReward(address recipient, uint256 amount) external onlyWorker {
        require(recipient != address(0) && amount > 0, "Issuance: invalid reward");
        workerMinted[recipient] += amount;
        token.mint(recipient, amount);
    }
}
