// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GenesisGovernance {
    enum Status { Draft, Proposed, Accepted, Rejected, Superseded }
    struct GiP { bytes32 id; address proposer; string title; string specificationURI; bytes32 specificationHash; uint64 votingEnds; Status status; }
    address public owner;
    uint64 public constant MIN_VOTING_PERIOD = 7 days;
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
    function vote(bytes32 id, bool support) external onlyOwner {
        GiP storage proposal = proposals[id];
        require(proposal.status == Status.Proposed && block.timestamp < proposal.votingEnds && !voted[id][msg.sender], "GenesisGovernance: vote unavailable");
        voted[id][msg.sender] = true;
        if (support) approvals[id]++; else rejections[id]++;
        emit GiPVoted(id, msg.sender, support);
    }
    function resolve(bytes32 id) external onlyOwner {
        GiP storage proposal = proposals[id];
        require(proposal.status == Status.Proposed && block.timestamp >= proposal.votingEnds, "GenesisGovernance: voting active");
        proposal.status = approvals[id] > rejections[id] ? Status.Accepted : Status.Rejected;
    }
}