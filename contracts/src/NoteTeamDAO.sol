// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INoteDAOERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Open-ended, adjustable maintenance treasury for the README's Note Team
/// 2% slice. It cannot access the hardware bounty or active-presence distributor pools.
contract NoteTeamDAO {
    enum ProposalState { None, Proposed, Approved, Paid, Completed, Rejected }
    struct Proposal {
        address proposer;
        address recipient;
        uint128 amount;
        uint64 deadline;
        bytes32 metadataHash;
        ProposalState state;
    }
    address public owner;
    address public immutable distributor;
    INoteDAOERC20 public immutable token;
    uint256 public treasuryBalance;
    uint256 public nextProposalId = 1;
    mapping(address => bool) public proposalCreators;
    mapping(address => bool) public technicalReviewers;
    mapping(address => bool) public treasuryApprovers;
    mapping(address => bool) public auditors;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public reviewed;
    mapping(uint256 => mapping(address => bool)) public approved;
    address[] private roleAccounts;
    mapping(address => bool) private roleAccountSeen;

    event RoleUpdated(address indexed account, uint8 indexed role, bool enabled);
    event FundingReceived(uint64 indexed epoch, uint256 amount);
    event ProposalCreated(uint256 indexed id, address indexed proposer, address indexed recipient, uint256 amount, bytes32 metadataHash);
    event ProposalReviewed(uint256 indexed id, address indexed reviewer, bool accepted);
    event ProposalApproved(uint256 indexed id, address indexed approver);
    event GrantPaid(uint256 indexed id, address indexed recipient, uint256 amount);
    event WorkVerified(uint256 indexed id, address indexed auditor, bytes32 evidenceHash);

    modifier onlyOwner() { require(msg.sender == owner, "NoteDAO: owner only"); _; }
    constructor(address tokenAddress, address distributorAddress) {
        require(tokenAddress != address(0) && distributorAddress != address(0), "NoteDAO: zero address");
        owner = msg.sender;
        token = INoteDAOERC20(tokenAddress);
        distributor = distributorAddress;
    }
    function transferOwnership(address nextOwner) external onlyOwner {
        require(nextOwner != address(0), "NoteDAO: zero owner");
        owner = nextOwner;
    }
    function setRole(address account, uint8 role, bool enabled) external onlyOwner {
        require(account != address(0) && role <= 3, "NoteDAO: invalid role");
        if (!roleAccountSeen[account]) { roleAccountSeen[account] = true; roleAccounts.push(account); }
        if (role == 0) proposalCreators[account] = enabled;
        else if (role == 1) technicalReviewers[account] = enabled;
        else if (role == 2) treasuryApprovers[account] = enabled;
        else auditors[account] = enabled;
        emit RoleUpdated(account, role, enabled);
    }
    function notifyFunding(uint64 fundingEpoch, uint256 amount) external {
        require(msg.sender == distributor && amount > 0, "NoteDAO: distributor only");
        require(token.balanceOf(address(this)) >= treasuryBalance + amount, "NoteDAO: funding not backed");
        treasuryBalance += amount;
        emit FundingReceived(fundingEpoch, amount);
    }
    function createProposal(address recipient, uint128 amount, uint64 deadline, bytes32 metadataHash) external returns (uint256 id) {
        require(proposalCreators[msg.sender], "NoteDAO: proposer only");
        require(recipient != address(0) && amount > 0 && metadataHash != bytes32(0), "NoteDAO: invalid proposal");
        require(deadline > block.timestamp, "NoteDAO: invalid deadline");
        id = nextProposalId++;
        proposals[id] = Proposal(msg.sender, recipient, amount, deadline, metadataHash, ProposalState.Proposed);
        emit ProposalCreated(id, msg.sender, recipient, amount, metadataHash);
    }
    function reviewProposal(uint256 id, bool accepted) external {
        require(technicalReviewers[msg.sender], "NoteDAO: reviewer only");
        Proposal storage p = proposals[id];
        require(p.state == ProposalState.Proposed && !reviewed[id][msg.sender], "NoteDAO: not reviewable");
        reviewed[id][msg.sender] = true;
        if (!accepted) p.state = ProposalState.Rejected;
        emit ProposalReviewed(id, msg.sender, accepted);
    }
    function approveProposal(uint256 id) external {
        require(treasuryApprovers[msg.sender], "NoteDAO: approver only");
        Proposal storage p = proposals[id];
        require(p.state == ProposalState.Proposed && _hasAcceptedReview(id), "NoteDAO: accepted review required");
        require(!approved[id][msg.sender] && treasuryBalance >= p.amount, "NoteDAO: duplicate approval or insufficient treasury");
        approved[id][msg.sender] = true;
        p.state = ProposalState.Approved;
        emit ProposalApproved(id, msg.sender);
    }
    function executeGrant(uint256 id) external {
        Proposal storage p = proposals[id];
        require(p.state == ProposalState.Approved && block.timestamp <= p.deadline && _hasApprover(id), "NoteDAO: grant not authorized or expired");
        treasuryBalance -= p.amount;
        p.state = ProposalState.Paid;
        require(token.transfer(p.recipient, p.amount), "NoteDAO: transfer failed");
        emit GrantPaid(id, p.recipient, p.amount);
    }
    function verifyCompletion(uint256 id, bytes32 evidenceHash) external {
        require(auditors[msg.sender], "NoteDAO: auditor only");
        Proposal storage p = proposals[id];
        require(p.state == ProposalState.Paid && evidenceHash != bytes32(0), "NoteDAO: grant not paid or evidence empty");
        p.state = ProposalState.Completed;
        emit WorkVerified(id, msg.sender, evidenceHash);
    }
    function _hasAcceptedReview(uint256 id) internal view returns (bool) {
        for (uint256 i; i < roleAccounts.length; i++) {
            address reviewer = roleAccounts[i];
            if (technicalReviewers[reviewer] && reviewed[id][reviewer]) return true;
        }
        return false;
    }
    function _hasApprover(uint256 id) internal view returns (bool) {
        for (uint256 i; i < roleAccounts.length; i++) {
            address approver = roleAccounts[i];
            if (treasuryApprovers[approver] && approved[id][approver]) return true;
        }
        return false;
    }
}
