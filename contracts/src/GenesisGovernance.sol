// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAppDAO { function appTeamProposalActivated(bytes32 id) external view returns (bool); }

contract GenesisGovernance {
    enum Track { Authentication, Core, Interface, Knowledge, Oracle, Process }
    enum Status { Draft, Review, LastCall, Staged, Implemented, NotImplemented }
    uint64 public constant REVIEW_PERIOD = 7 days; uint64 public constant LAST_CALL_PERIOD = 28 days; uint64 public constant ACTIVATION_WINDOW = 12 weeks;
    uint256 public constant REQUIRED_BPS = 5001; uint256 public constant MAX_CREDITS = 150;
    address public owner; address public appTeamDAO; uint256 public distinctATMTransactions; bool public activationSignalsOperable;
    struct GiP { bytes32 id; Track track; address proposer; bytes32 specificationHash; bytes32 ordinalHash; uint64 createdAt; uint64 lastCallEnds; Status status; }
    mapping(bytes32 => GiP) public proposals; mapping(bytes32 => mapping(address => bool)) public voted; mapping(bytes32 => uint256) public yes; mapping(bytes32 => uint256) public no;
    mapping(address => uint256) public credits; mapping(address => address) public delegateOf;
    event GiPProposed(bytes32 indexed id, Track track, bytes32 specificationHash, bytes32 ordinalHash); event VoteCast(bytes32 indexed id, address indexed voter, bool support, uint256 weight); event StatusChanged(bytes32 indexed id, Status status); event ATMTransactionRecorded(address indexed atm, uint256 distinctCount); event ActivationSignalsSet(bool operable); event AppTeamDAOSet(address indexed dao);
    modifier onlyOwner() { require(msg.sender == owner, "Governance: owner"); _; }
    constructor() { owner = msg.sender; }
    function setAppTeamDAO(address dao) external onlyOwner { require(dao != address(0), "Governance: zero"); appTeamDAO = dao; emit AppTeamDAOSet(dao); }
    function recordATMTransaction(address atm) external onlyOwner { require(atm != address(0), "Governance: zero"); if (distinctATMTransactions < 3) distinctATMTransactions++; emit ATMTransactionRecorded(atm, distinctATMTransactions); }
    function setActivationSignalsOperable(bool operable) external onlyOwner { activationSignalsOperable = operable; emit ActivationSignalsSet(operable); }
    function propose(bytes32 id, Track track, bytes32 specificationHash, bytes32 ordinalHash) external { require(proposals[id].proposer == address(0), "Governance: exists"); proposals[id] = GiP(id, track, msg.sender, specificationHash, ordinalHash, uint64(block.timestamp), 0, Status.Review); emit GiPProposed(id, track, specificationHash, ordinalHash); }
    function issueCredits(address who, uint256 amount) external onlyOwner { require(amount <= MAX_CREDITS, "Governance: credits"); credits[who] = amount; }
    function setDelegate(address who) external { require(who != msg.sender, "Governance: self"); delegateOf[msg.sender] = who; }
    function revokeDelegate() external { delete delegateOf[msg.sender]; }
    function enterLastCall(bytes32 id) external onlyOwner { GiP storage p = proposals[id]; require(p.status == Status.Review && block.timestamp >= p.createdAt + REVIEW_PERIOD, "Governance: review"); p.status = Status.LastCall; p.lastCallEnds = uint64(block.timestamp + LAST_CALL_PERIOD); emit StatusChanged(id, p.status); }
    function vote(bytes32 id, bool support, uint256 spent) external { GiP memory p = proposals[id]; require(p.status == Status.Review || p.status == Status.LastCall, "Governance: inactive"); require(block.timestamp <= p.lastCallEnds || p.lastCallEnds == 0, "Governance: window"); require(!voted[id][msg.sender] && spent > 0 && spent <= credits[msg.sender], "Governance: vote"); voted[id][msg.sender] = true; uint256 weight = spent * spent; if (support) yes[id] += weight; else no[id] += weight; emit VoteCast(id, msg.sender, support, weight); }
    function resolve(bytes32 id) external onlyOwner { GiP storage p = proposals[id]; require(p.status == Status.LastCall && block.timestamp >= p.lastCallEnds, "Governance: window"); p.status = yes[id] * 10000 / (yes[id] + no[id]) >= REQUIRED_BPS ? Status.Staged : Status.NotImplemented; emit StatusChanged(id, p.status); }
    function activate(bytes32 id) external onlyOwner { GiP storage p = proposals[id]; require(p.status == Status.Staged && block.timestamp <= p.lastCallEnds + ACTIVATION_WINDOW, "Governance: activation"); require(distinctATMTransactions >= 3 && activationSignalsOperable, "Governance: genesis gate"); p.status = Status.Implemented; emit StatusChanged(id, p.status); }
    function appTeamProposalActivated(bytes32 id) external view returns (bool) { return appTeamDAO != address(0) && IAppDAO(appTeamDAO).appTeamProposalActivated(id); }
}
