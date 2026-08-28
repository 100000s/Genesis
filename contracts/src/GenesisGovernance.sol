// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisGovernance {
    enum Status { Draft, Proposed, Accepted, Rejected, Superseded }
    struct GiP { bytes32 id; address proposer; string title; string specificationURI; bytes32 specificationHash; uint64 votingEnds; Status status; }
    address public owner;
    uint64 public constant MIN_VOTING_PERIOD = 7 days;
    uint64 public constant LAST_CALL_PERIOD = 28 days;
    uint64 public constant ACTIVATION_WINDOW = 12 weeks;
    uint256 public constant QUORUM_BPS = 5001;
    mapping(address => mapping(uint8 => uint256)) public quarterlyCredits;
    mapping(address => mapping(uint8 => address)) public delegate;
    mapping(bytes32 => GiP) public proposals;
    mapping(bytes32 => mapping(address => bool)) public voted;
    mapping(bytes32 => uint256) public approvals;
    mapping(bytes32 => uint256) public rejections;
    event GiPProposed(bytes32 indexed id, address indexed proposer, string title, bytes32 specificationHash, uint64 votingEnds);
    event GiPVoted(bytes32 indexed id, address indexed voter, bool support);
    modifier onlyOwner() { require(msg.sender == owner, "GenesisGovernance: owner only"); _; }
    constructor() { owner = msg.sender; }
    function propose(bytes32 id, string calldata title, string calldata specificationURI, bytes32 specificationHash, uint64 votingPeriod) external {
        require(proposals[id].proposer == address(0) && votingPeriod >= MIN_VOTING_PERIOD, "GenesisGovernance: invalid proposal");
        proposals[id] = GiP(id, msg.sender, title, specificationURI, specificationHash, uint64(block.timestamp) + votingPeriod, Status.Proposed);
        emit GiPProposed(id, msg.sender, title, specificationHash, uint64(block.timestamp) + votingPeriod);
    }
    function setCredits(uint8 group, uint256 credits) external onlyOwner { require(group < 6 && credits <= 150, "GenesisGovernance: invalid credits"); quarterlyCredits[msg.sender][group] = credits; }
    function setDelegate(uint8 group, address delegateAddress) external { require(group < 6, "GenesisGovernance: invalid group"); delegate[msg.sender][group] = delegateAddress; }
    function vote(bytes32 id, uint8 group, uint256 credits, bool support) external {
        GiP storage proposal = proposals[id];
        require(proposal.status == Status.Proposed && block.timestamp < proposal.votingEnds && !voted[id][msg.sender], "GenesisGovernance: vote unavailable");
        require(group < 6 && credits > 0 && credits <= quarterlyCredits[msg.sender][group], "GenesisGovernance: insufficient credits");
        voted[id][msg.sender] = true;
        uint256 weight = credits * credits;
        if (support) approvals[id] += weight; else rejections[id] += weight;
        emit GiPVoted(id, msg.sender, support);
    }
    function resolve(bytes32 id) external onlyOwner {
        GiP storage proposal = proposals[id];
        require(proposal.status == Status.Proposed && block.timestamp >= proposal.votingEnds, "GenesisGovernance: voting active");
        proposal.status = approvals[id] > rejections[id] ? Status.Accepted : Status.Rejected;
    }
}