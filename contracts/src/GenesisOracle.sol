// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisOracle {
    struct Report { uint256 value; uint64 observedAt; uint64 round; bytes32 sourceHash; }
    address public owner;
    uint256 public immutable quorum;
    mapping(address => bool) public reporters;
    mapping(bytes32 => Report) public latest;
    mapping(bytes32 => uint64) public rounds;
    mapping(bytes32 => mapping(uint64 => mapping(address => bool))) public submitted;
    mapping(bytes32 => mapping(uint64 => uint256[])) private pending;

    event ObservationSubmitted(bytes32 indexed key, uint64 indexed round, address indexed reporter, uint256 value);
    event ReportPublished(bytes32 indexed key, uint64 indexed round, uint256 value, uint64 observedAt);

    modifier onlyOwner() { require(msg.sender == owner, "GenesisOracle: owner only"); _; }

    constructor(uint256 requiredQuorum) {
        require(requiredQuorum > 0, "GenesisOracle: zero quorum");
        owner = msg.sender;
        quorum = requiredQuorum;
    }

    function setReporter(address reporter, bool enabled) external onlyOwner {
        require(reporter != address(0), "GenesisOracle: zero address");
        reporters[reporter] = enabled;
    }

    function submit(bytes32 key, uint256 value, uint64 observedAt, bytes32 sourceHash) external {
        require(reporters[msg.sender], "GenesisOracle: reporter only");
        require(observedAt <= block.timestamp, "GenesisOracle: future report");
        uint64 reportRound = rounds[key] + 1;
        require(!submitted[key][reportRound][msg.sender], "GenesisOracle: duplicate report");
        submitted[key][reportRound][msg.sender] = true;
        pending[key][reportRound].push(value);
        emit ObservationSubmitted(key, reportRound, msg.sender, value);
        if (pending[key][reportRound].length == quorum) {
            uint256[] storage values = pending[key][reportRound];
            uint256 median = _median(values);
            rounds[key] = reportRound;
            latest[key] = Report(median, observedAt, reportRound, sourceHash);
            delete pending[key][reportRound];
            emit ReportPublished(key, reportRound, median, observedAt);
        }
    }

    function _median(uint256[] storage values) private view returns (uint256) {
        uint256[] memory sorted = new uint256[](values.length);
        for (uint256 i = 0; i < values.length; i++) sorted[i] = values[i];
        for (uint256 i = 1; i < sorted.length; i++) {
            uint256 value = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > value) { sorted[j] = sorted[j - 1]; j--; }
            sorted[j] = value;
        }
        return sorted[sorted.length / 2];
    }
}