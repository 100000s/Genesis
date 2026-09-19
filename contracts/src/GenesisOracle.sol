// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Native oracle boundary. External feeds are collected off-chain, hashed,
/// and submitted by an automated relayer; Solidity cannot fetch HTTP data itself.
contract GenesisOracle {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_PRICE_INTERVAL = 1 hours;
    uint256 public constant TWAP_WINDOW = 24 hours;
    address public owner;
    mapping(address => bool) public reporters;

    struct Observation { uint64 timestamp; uint256 cumulative; uint256 price; }
    struct Ratio { uint256 value; bytes32 sourceHash; bool set; }
    Observation[] public observations;
    mapping(uint256 => Ratio) public federalRatio;
    mapping(uint8 => mapping(uint256 => Ratio)) public stateRatio;
    uint256 public exchangePriceWad;

    event ReporterUpdated(address indexed reporter, bool enabled);
    event PriceUpdated(uint256 priceWad, uint256 observedAt, bytes32 sourceHash);
    event FederalRatioUpdated(uint256 indexed year, uint256 ratioWad, bytes32 sourceHash);
    event StateRatioUpdated(uint8 indexed stateId, uint256 indexed year, uint256 ratioWad, bytes32 sourceHash);

    modifier onlyOwner() { require(msg.sender == owner, "Oracle: owner only"); _; }
    modifier onlyReporter() { require(reporters[msg.sender], "Oracle: reporter only"); _; }

    constructor(uint256 initialPriceWad) {
        owner = msg.sender; reporters[msg.sender] = true;
        exchangePriceWad = initialPriceWad;
        observations.push(Observation(uint64(block.timestamp), 0, initialPriceWad));
    }
    function setReporter(address account, bool enabled) external onlyOwner {
        require(account != address(0), "Oracle: zero address"); reporters[account] = enabled; emit ReporterUpdated(account, enabled);
    }
    function updateExchangePrice(uint256 priceWad, uint256 observedAt, bytes32 sourceHash) external onlyReporter {
        require(priceWad > 0 && observedAt <= block.timestamp, "Oracle: invalid price");
        Observation storage last = observations[observations.length - 1];
        require(block.timestamp - last.timestamp >= MIN_PRICE_INTERVAL, "Oracle: interval");
        uint256 cumulative = last.cumulative + last.price * (uint64(block.timestamp) - last.timestamp);
        observations.push(Observation(uint64(block.timestamp), cumulative, priceWad)); exchangePriceWad = priceWad;
        emit PriceUpdated(priceWad, observedAt, sourceHash);
    }
    function setExchangePrice(uint256 priceWad) external onlyReporter { updateExchangePrice(priceWad, block.timestamp, bytes32(0)); }
    function updateFedRatio(uint256 year, uint256 ratioWad, bytes32 sourceHash) external onlyReporter {
        require(year > 2026 && ratioWad > 0 && !federalRatio[year].set, "Oracle: federal ratio locked");
        federalRatio[year] = Ratio(ratioWad, sourceHash, true); emit FederalRatioUpdated(year, ratioWad, sourceHash);
    }
    function updateStateRatio(uint8 stateId, uint256 year, uint256 ratioWad, bytes32 sourceHash) external onlyReporter {
        require(stateId > 0 && stateId <= 50 && year > 2026 && ratioWad > 0 && !stateRatio[stateId][year].set, "Oracle: state ratio locked");
        stateRatio[stateId][year] = Ratio(ratioWad, sourceHash, true); emit StateRatioUpdated(stateId, year, ratioWad, sourceHash);
    }
    function getTwapPrice() public view returns (uint256) {
        if (observations.length < 2) return exchangePriceWad;
        Observation memory latest = observations[observations.length - 1];
        uint256 target = block.timestamp > TWAP_WINDOW ? block.timestamp - TWAP_WINDOW : 0;
        Observation memory prior = observations[0];
        for (uint256 i = observations.length - 1; i > 0; i--) if (observations[i - 1].timestamp <= target) { prior = observations[i - 1]; break; }
        uint256 elapsed = latest.timestamp - prior.timestamp; return elapsed == 0 ? latest.price : (latest.cumulative - prior.cumulative) / elapsed;
    }
    /// @dev The two protected components are each floored at 50 bps; total is 100 bps.
    function getDynamicIssuanceRateBps() external pure returns (uint256) { return 100; }
}
