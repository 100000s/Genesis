// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAppDAO { function appTeamProposalActivated(bytes32 id) external view returns (bool); }

/// @notice Canonical six-track Genesis Improvement Proposal governance.
contract GenesisGovernance {
    enum Track { Authentication, Core, Interface, Knowledge, Oracle, Process }
    enum Group { Verifiers, Validators, ATMOperators, NoteDevelopers, NoteMaintainers, AppTeam }
    enum Status { Draft, Review, LastCall, Staged, Implemented, NotImplemented }

    uint64 public constant REVIEW_PERIOD = 7 days;
    uint64 public constant LAST_CALL_PERIOD = 28 days;
    uint64 public constant ACTIVATION_WINDOW = 12 weeks;
    uint256 public constant REQUIRED_BPS = 5001;
    uint256 public constant MAX_CREDITS = 150;
    uint256 public constant GROUP_COUNT = 6;

    // README weights: 15/15/25/15/15/15 = 100%.
    uint256[6] public GROUP_WEIGHTS_BPS = [uint256(1500), 1500, 2500, 1500, 1500, 1500];

    address public owner;
    address public appTeamDAO;
    uint256 public distinctATMTransactions;
    bool public activationSignalsOperable;

    struct GiP {
        bytes32 id;
        Track track;
        address proposer;
        bytes32 specificationHash;
        bytes32 githubPRHash;
        bytes32 ordinalHash;
        uint64 createdAt;
        uint64 lastCallEnds;
        Status status;
        uint8 acknowledgedAuthors;
        bool peerAuditPassed;
    }

    mapping(bytes32 => GiP) public proposals;
    mapping(bytes32 => mapping(address => bool)) public acknowledgedAuthor;
    mapping(bytes32 => mapping(address => bool)) public peerAuditor;
    mapping(bytes32 => mapping(address => bool)) public voted;
    mapping(bytes32 => mapping(uint8 => mapping(address => bool))) public groupVoted;
    mapping(bytes32 => mapping(uint8 => uint256)) public groupPositiveSignals;
    mapping(bytes32 => uint256) public yes;
    mapping(bytes32 => uint256) public no;
    mapping(address => uint256) public credits;
    mapping(address => address) public delegateOf;

    event GiPProposed(bytes32 indexed id, Track track, bytes32 specificationHash, bytes32 githubPRHash, bytes32 ordinalHash);
    event AuthorAcknowledged(bytes32 indexed id, address indexed author, uint256 authorCount);
    event PeerAuditRecorded(bytes32 indexed id, address indexed auditor, bool passed);
    event VoteCast(bytes32 indexed id, Group indexed group, address indexed voter, bool support, uint256 weight);
    event StatusChanged(bytes32 indexed id, Status status);
    event ATMTransactionRecorded(address indexed atm, uint256 distinctCount);
    event ActivationSignalsSet(bool operable);
    event AppTeamDAOSet(address indexed dao);

    modifier onlyOwner() { require(msg.sender == owner, "Governance: owner"); _; }

    constructor() { owner = msg.sender; }

    function setAppTeamDAO(address dao) external onlyOwner {
        require(dao != address(0), "Governance: zero");
        appTeamDAO = dao;
        emit AppTeamDAOSet(dao);
    }

    function recordATMTransaction(address atm) external onlyOwner {
        require(atm != address(0), "Governance: zero");
        if (distinctATMTransactions < 3) distinctATMTransactions++;
        emit ATMTransactionRecorded(atm, distinctATMTransactions);
    }

    function setActivationSignalsOperable(bool operable) external onlyOwner {
        activationSignalsOperable = operable;
        emit ActivationSignalsSet(operable);
    }

    /// @dev Retained for callers using the prior ABI. Such proposals cannot activate
    /// until a nonzero GitHub PR reference is supplied through the extended overload.
    function propose(bytes32 id, Track track, bytes32 specificationHash, bytes32 ordinalHash) external {
        _propose(id, track, specificationHash, bytes32(0), ordinalHash);
    }

    /// @notice Create a GIP with specification, GitHub PR, and BTC Ordinal content hashes.
    function propose(bytes32 id, Track track, bytes32 specificationHash, bytes32 githubPRHash, bytes32 ordinalHash) external {
        _propose(id, track, specificationHash, githubPRHash, ordinalHash);
    }

    function _propose(bytes32 id, Track track, bytes32 specificationHash, bytes32 githubPRHash, bytes32 ordinalHash) internal {
        require(id != bytes32(0) && proposals[id].proposer == address(0), "Governance: exists");
        require(specificationHash != bytes32(0), "Governance: specification required");
        require(ordinalHash != bytes32(0), "Governance: ordinal required");
        proposals[id] = GiP(id, track, msg.sender, specificationHash, githubPRHash, ordinalHash, uint64(block.timestamp), 0, Status.Review, 0, false);
        emit GiPProposed(id, track, specificationHash, githubPRHash, ordinalHash);
    }

    function acknowledgeAuthor(bytes32 id, address author) external {
        GiP storage p = proposals[id];
        require(p.proposer != address(0) && p.status == Status.Review, "Governance: inactive");
        require(author != address(0) && !acknowledgedAuthor[id][author], "Governance: author");
        acknowledgedAuthor[id][author] = true;
        p.acknowledgedAuthors++;
        emit AuthorAcknowledged(id, author, p.acknowledgedAuthors);
    }

    function submitPeerAudit(bytes32 id, bool passed) external {
        GiP storage p = proposals[id];
        require(p.proposer != address(0) && p.status == Status.Review, "Governance: inactive");
        require(msg.sender != p.proposer && !peerAuditor[id][msg.sender], "Governance: auditor");
        peerAuditor[id][msg.sender] = true;
        if (passed) p.peerAuditPassed = true;
        emit PeerAuditRecorded(id, msg.sender, passed);
    }

    function issueCredits(address who, uint256 amount) external onlyOwner {
        require(who != address(0) && amount <= MAX_CREDITS, "Governance: credits");
        credits[who] = amount;
    }

    function setDelegate(address who) external {
        require(who != msg.sender, "Governance: self");
        delegateOf[msg.sender] = who;
    }

    function revokeDelegate() external { delete delegateOf[msg.sender]; }

    function enterLastCall(bytes32 id) external onlyOwner {
        GiP storage p = proposals[id];
        require(p.status == Status.Review && block.timestamp >= p.createdAt + REVIEW_PERIOD, "Governance: review");
        require(p.acknowledgedAuthors >= 3 && p.peerAuditPassed, "Governance: review gates");
        require(p.githubPRHash != bytes32(0) && p.ordinalHash != bytes32(0), "Governance: references");
        p.status = Status.LastCall;
        p.lastCallEnds = uint64(block.timestamp + LAST_CALL_PERIOD);
        emit StatusChanged(id, p.status);
    }

    /// @notice Positive/negative signal from one of the six weighted governance groups.
    /// Each group has an independent positive-signal path; activation requires all six.
    function signal(bytes32 id, Group group, bool support, uint256 spent) external {
        GiP memory p = proposals[id];
        require(p.status == Status.Review || p.status == Status.LastCall, "Governance: inactive");
        require(uint8(group) < GROUP_COUNT && !groupVoted[id][uint8(group)][msg.sender], "Governance: group vote");
        require(spent > 0 && spent <= credits[msg.sender], "Governance: vote");
        groupVoted[id][uint8(group)][msg.sender] = true;
        uint256 weight = spent * spent;
        if (support) {
            groupPositiveSignals[id][uint8(group)] += weight;
            yes[id] += weight * GROUP_WEIGHTS_BPS[uint8(group)] / 10000;
        } else {
            no[id] += weight * GROUP_WEIGHTS_BPS[uint8(group)] / 10000;
        }
        emit VoteCast(id, group, msg.sender, support, weight);
    }

    /// @dev Legacy vote path retained as an unweighted compatibility signal.
    function vote(bytes32 id, bool support, uint256 spent) external {
        GiP memory p = proposals[id];
        require(p.status == Status.Review || p.status == Status.LastCall, "Governance: inactive");
        require(!voted[id][msg.sender] && spent > 0 && spent <= credits[msg.sender], "Governance: vote");
        voted[id][msg.sender] = true;
        uint256 weight = spent * spent;
        if (support) yes[id] += weight; else no[id] += weight;
        emit VoteCast(id, Group.AppTeam, msg.sender, support, weight);
    }

    function resolve(bytes32 id) external onlyOwner {
        GiP storage p = proposals[id];
        require(p.status == Status.LastCall && block.timestamp >= p.lastCallEnds, "Governance: window");
        uint256 total = yes[id] + no[id];
        require(total > 0, "Governance: no signals");
        p.status = _allGroupsPositive(id) && yes[id] * 10000 / total >= REQUIRED_BPS
            ? Status.Staged : Status.NotImplemented;
        emit StatusChanged(id, p.status);
    }

    function activate(bytes32 id) external onlyOwner {
        GiP storage p = proposals[id];
        require(p.status == Status.Staged && block.timestamp <= p.lastCallEnds + ACTIVATION_WINDOW, "Governance: activation");
        require(distinctATMTransactions >= 3 && activationSignalsOperable, "Governance: genesis gate");
        p.status = Status.Implemented;
        emit StatusChanged(id, p.status);
    }

    function _allGroupsPositive(bytes32 id) internal view returns (bool) {
        for (uint8 i = 0; i < GROUP_COUNT; i++) if (groupPositiveSignals[id][i] == 0) return false;
        return true;
    }

    function appTeamProposalActivated(bytes32 id) external view returns (bool) {
        return appTeamDAO != address(0) && IAppDAO(appTeamDAO).appTeamProposalActivated(id);
    }
}
