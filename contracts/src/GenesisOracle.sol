// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Native oracle boundary. External feeds are collected off-chain, hashed,
/// and submitted by an automated relayer; Solidity cannot fetch HTTP data itself.
/// Provides:
/// - TWAP price for dynamic issuance scaling (never less than 1.0x)
/// - ALFRED budget ratios (federal and state fiscal receipts with 1-year publishing lag)
/// - Immutable storage once set per year for budget integrity
contract GenesisOracle {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_PRICE_INTERVAL = 1 hours;
    uint256 public constant TWAP_WINDOW = 24 hours;
    uint256 public constant BASE_FLOOR_BPS = 50; // 0.5% per component
    uint256 public constant EPOCH_DURATION = 30 days;

    address public owner;
    mapping(address => bool) public reporters;

    struct Observation {
        uint64 timestamp;
        uint256 cumulative;
        uint256 price;
    }

    struct Ratio {
        uint256 value;     // ratio in WAD (e.g., 0.95e18 for 95% of prior year)
        bytes32 sourceHash; // hash of ALFRED data source
        bool set;          // immutable once set
    }

    Observation[] public observations;
    // Budget ratios: stored per year, immutable once set
    // For year Y, ratio = (FY(Y-3) receipts) / (FY(Y-2) receipts)
    // ALFRED data has ~12 month lag before complete, so we use 2-year prior receipts
    mapping(uint256 => Ratio) public federalRatio;              // year => Ratio (immutable)
    mapping(uint8 => mapping(uint256 => Ratio)) public stateRatio; // stateId => year => Ratio (immutable)

    uint256 public exchangePriceWad;
    uint256 public initialTwapPriceWad; // baseline for TWAP multiplier
    uint64 public lastEpochTimestamp;
    uint256 public previousEpochPrice;

    event ReporterUpdated(address indexed reporter, bool enabled);
    event PriceUpdated(uint256 priceWad, uint256 observedAt, bytes32 sourceHash);
    event FederalRatioUpdated(uint256 indexed year, uint256 ratioWad, bytes32 sourceHash);
    event StateRatioUpdated(uint8 indexed stateId, uint256 indexed year, uint256 ratioWad, bytes32 sourceHash);
    event EpochPriceSnapshotted(uint64 indexed epoch, uint256 priceWad);

    modifier onlyOwner() {
        require(msg.sender == owner, "Oracle: owner only");
        _;
    }

    modifier onlyReporter() {
        require(reporters[msg.sender], "Oracle: reporter only");
        _;
    }

    constructor(uint256 initialPriceWad_) {
        owner = msg.sender;
        reporters[msg.sender] = true;
        exchangePriceWad = initialPriceWad_;
        initialTwapPriceWad = initialPriceWad_;
        previousEpochPrice = initialPriceWad_;
        lastEpochTimestamp = uint64(block.timestamp);
        observations.push(Observation(uint64(block.timestamp), 0, initialPriceWad_));
    }

    function setReporter(address account, bool enabled) external onlyOwner {
        require(account != address(0), "Oracle: zero address");
        reporters[account] = enabled;
        emit ReporterUpdated(account, enabled);
    }

    /// @notice Update exchange price from verified DEX or aggregator feed
    function updateExchangePrice(uint256 priceWad, uint256 observedAt, bytes32 sourceHash) external onlyReporter {
        require(priceWad > 0 && observedAt <= block.timestamp, "Oracle: invalid price");
        Observation storage last = observations[observations.length - 1];
        require(block.timestamp - last.timestamp >= MIN_PRICE_INTERVAL, "Oracle: interval");

        uint256 cumulative = last.cumulative + last.price * (uint64(block.timestamp) - last.timestamp);
        observations.push(Observation(uint64(block.timestamp), cumulative, priceWad));
        exchangePriceWad = priceWad;

        emit PriceUpdated(priceWad, observedAt, sourceHash);
    }

    /// @notice Snapshot price at epoch boundary (prevents intra-block manipulation)
    function snapshotEpochPrice() external onlyReporter {
        require(block.timestamp - lastEpochTimestamp >= EPOCH_DURATION, "Oracle: epoch not elapsed");
        previousEpochPrice = getTwapPrice();
        lastEpochTimestamp = uint64(block.timestamp);
        emit EpochPriceSnapshotted((block.timestamp / EPOCH_DURATION), previousEpochPrice);
    }

    /// @notice Immediate price update (convenience method)
    function setExchangePrice(uint256 priceWad) external onlyReporter {
        updateExchangePrice(priceWad, block.timestamp, bytes32(0));
    }

    /// @notice Update federal budget ratio from ALFRED (immutable once set per year)
    /// @param year Fiscal year (e.g., 2027)
    /// @param ratioWad Ratio as WAD: (FY2024 receipts) / (FY2025 receipts) for year 2027
    /// @dev ALFRED publishes data ~12 months after fiscal year end, so year Y uses FY(Y-3)/FY(Y-2)
    /// @param sourceHash Hash of ALFRED data retrieval for audit trail
    function updateFedRatio(uint256 year, uint256 ratioWad, bytes32 sourceHash) external onlyReporter {
        require(year > 2026, "Oracle: year must be > 2026");
        require(ratioWad > 0, "Oracle: zero ratio");
        require(!federalRatio[year].set, "Oracle: federal ratio locked");
        federalRatio[year] = Ratio(ratioWad, sourceHash, true);
        emit FederalRatioUpdated(year, ratioWad, sourceHash);
    }

    /// @notice Update state budget ratio from ALFRED (immutable once set per year per state)
    /// @param stateId State ID (1-50)
    /// @param year Fiscal year
    /// @param ratioWad Ratio as WAD: (FY(year-3) receipts) / (FY(year-2) receipts)
    /// @dev ALFRED publishes data ~12 months after fiscal year end, so year Y uses FY(Y-3)/FY(Y-2)
    /// @param sourceHash Hash of ALFRED data retrieval
    function updateStateRatio(uint8 stateId, uint256 year, uint256 ratioWad, bytes32 sourceHash) external onlyReporter {
        require(stateId > 0 && stateId <= 50, "Oracle: invalid state");
        require(year > 2026, "Oracle: year must be > 2026");
        require(ratioWad > 0, "Oracle: zero ratio");
        require(!stateRatio[stateId][year].set, "Oracle: state ratio locked");
        stateRatio[stateId][year] = Ratio(ratioWad, sourceHash, true);
        emit StateRatioUpdated(stateId, year, ratioWad, sourceHash);
    }

    /// @notice Get Time-Weighted Average Price over TWAP_WINDOW (24 hours)
    function getTwapPrice() public view returns (uint256) {
        if (observations.length < 2) return exchangePriceWad;

        Observation memory latest = observations[observations.length - 1];
        uint256 target = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;
        Observation memory prior = observations[0];

        for (uint256 i = observations.length - 1; i > 0; i--) {
            if (observations[i - 1].timestamp <= target) {
                prior = observations[i - 1];
                break;
            }
        }

        uint256 elapsed = latest.timestamp - prior.timestamp;
        return elapsed == 0 ? latest.price : (latest.cumulative - prior.cumulative) / elapsed;
    }

    /// @notice Calculate quadratic (square root) TWAP multiplier for supply scaling
    /// @dev ALWAYS returns >= 1.0 (1e18). Never reduces supply even if price drops.
    /// @return Multiplier in WAD (e.g., 1.1e18 = 10% expansion allowance)
    function getTwapMultiplier() public view returns (uint256) {
        uint256 twap = getTwapPrice();
        if (twap <= initialTwapPriceWad) {
            return WAD; // Floor at 1.0: price down or stable → no supply reduction
        }

        // Price ratio = twap / initialTwap (always >= 1.0 here)
        uint256 rawRatioWad = (twap * WAD) / initialTwapPriceWad;

        // Quadratic (square root) dampening: sqrt(rawRatio)
        // Example: if price doubled (ratio = 2.0), multiplier = sqrt(2) ≈ 1.414 (41.4% expansion)
        uint256 sqrtRatio = _sqrt(rawRatioWad);

        // Ensure we never drop below 1.0
        return sqrtRatio < WAD ? WAD : sqrtRatio;
    }

    /// @notice Dynamic issuance rate in basis points
    /// @dev Returns 100 bps (1.0%) minimum, scaled upward by TWAP growth
    /// @return Rate in BPS (e.g., 100 = 1.0% per 30-day epoch)
    function getDynamicIssuanceRateBps() external view returns (uint256) {
        // Base: 100 bps total (50 bps WorkerSplit + 50 bps GenesisIssuance)
        uint256 baseBps = 100;

        // Apply TWAP multiplier for upside scaling
        uint256 twapMul = getTwapMultiplier();
        uint256 scaledBps = (baseBps * twapMul) / WAD;

        // Safety: never drop below base floor
        return scaledBps < baseBps ? baseBps : scaledBps;
    }

    /// @notice Get the 0.5% compounding base multiplier (100.5%)
    /// @return Multiplier in WAD (1.005e18)
    function getBaseGrowthMultiplier() external pure returns (uint256) {
        return (1005 * WAD) / 1000;
    }

    /// @notice Babylonian square root (integer approximation)
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
