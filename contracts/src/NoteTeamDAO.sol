// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INoteDAOERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Open-ended recycling/maintenance grant treasury. Proposal metadata is
/// represented by a content hash; on-chain authorization and all token movements
/// remain auditable. This treasury only receives the Note Team 2% allocation.
contract NoteTeamDAO {
    enum ProposalState { None, Proposed, Approved, Paid, Completed, Rejected }
    struct Proposal {
        address proposer;
        address recipient;
        uint128 amount;
        uint64 createdAt;
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

    function setRole(address account, uint8 role, bool enabled) external onlyOwner {
        require(account != address(0) && role <= 4, "NoteDAO: invalid role");
        if (role == 0) proposalCreators[account] = enabled;
        else if (role == 1) technicalReviewers[account] = enabled;
        else if (role == 2) treasuryApprovers[account] = enabled;
        else if (role == 3) auditors[account] = enabled;
        else owner = account;
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
        proposals[id] = Proposal(msg.sender, recipient, amount, uint64(block.timestamp), deadline, metadataHash, ProposalState.Proposed);
        emit ProposalCreated(id, msg.sender, recipient, amount, metadataHash);
    }

    function reviewProposal(uint256 id, bool accepted) external {
        require(technicalReviewers[msg.sender], "NoteDAO: reviewer only");
        Proposal storage proposal = proposals[id];
        require(proposal.state == ProposalState.Proposed && !reviewed[id][msg.sender], "NoteDAO: not reviewable");
        reviewed[id][msg.sender] = true;
        if (!accepted) proposal.state = ProposalState.Rejected;
        emit ProposalReviewed(id, msg.sender, accepted);
    }

    function approveProposal(uint256 id) external {
        require(treasuryApprovers[msg.sender], "NoteDAO: approver only");
        Proposal storage proposal = proposals[id];
        require(proposal.state == ProposalState.Proposed && _hasAcceptedReview(id), "NoteDAO: review required");
        require(!approved[id][msg.sender], "NoteDAO: already approved");
        require(treasuryBalance >= proposal.amount, "NoteDAO: insufficient treasury");
        approved[id][msg.sender] = true;
        proposal.state = ProposalState.Approved;
        emit ProposalApproved(id, msg.sender);
    }

    function executeGrant(uint256 id) external {
        Proposal storage proposal = proposals[id];
        require(proposal.state == ProposalState.Approved && block.timestamp <= proposal.deadline, "NoteDAO: grant not payable");
        require(_hasApprover(id), "NoteDAO: authorization missing");
        treasuryBalance -= proposal.amount;
        proposal.state = ProposalState.Paid;
        require(token.transfer(proposal.recipient, proposal.amount), "NoteDAO: transfer failed");
        emit GrantPaid(id, proposal.recipient, proposal.amount);
    }

    function verifyCompletion(uint256 id, bytes32 evidenceHash) external {
        require(auditors[msg.sender], "NoteDAO: auditor only");
        Proposal storage proposal = proposals[id];
        require(proposal.state == ProposalState.Paid && evidenceHash != bytes32(0), "NoteDAO: grant not paid or empty evidence");
        proposal.state = ProposalState.Completed;
        emit WorkVerified(id, msg.sender, evidenceHash);
    }

    function _hasAcceptedReview(uint256 id) internal view returns (bool) {
        for (uint256 i = 0; i < _roleAccountsCount; i++) {
            address reviewer = _roleAccounts[i];
            if (technicalReviewers[reviewer] && reviewed[id][reviewer]) return true;
        }
        return false;
    }

    function _hasApprover(uint256 id) internal view returns (bool) {
        for (uint256 i = 0; i < _roleAccountsCount; i++) {
            address approver = _roleAccounts[i];
            if (treasuryApprovers[approver] && approved[id][approver]) return true;
        }
        return false;
    }

    address[] private _roleAccounts;
    uint256 private _roleAccountsCount;
}
