// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAppGovernanceGate { function appTeamProposalActivated(bytes32 id) external view returns (bool); }

contract AppTeamDAO {
    uint256 public constant MAX_CREDITS = 150; uint256 public constant QUARTER = 90 days; uint256 public constant BPS = 10_000;
    uint8 public constant CORE = 0; uint8 public constant UX = 1; uint8 public constant MOBILE = 2; uint8 public constant ESCROW = 3; uint8 public constant COMMUNITY = 4;
    // App Team pool categories: one third each; sub-weights are basis points of a bucket.
    uint8 public constant NOTE_RND = 0; uint8 public constant MERCHANT = 1; uint8 public constant ANDROID_IOS = 2; uint8 public constant OLD_PC = 3; uint8 public constant OLD_PHONE = 4; uint8 public constant SATELLITE = 5; uint8 public constant RADIO = 6; uint8 public constant GENESIS_MALL = 7; uint8 public constant SECOND_LIFE = 8; uint8 public constant DECENTRALAND = 9;
    address public owner; address public governance; address public workerSplit; address public oracle;
    uint64 public cycle; uint64 public cycleStart; uint256 public appPool;
    mapping(address => uint256) public credits; mapping(address => uint256) public usedCredits; mapping(address => address) public delegateOf; mapping(address => bool) public members;
    mapping(address => uint256) public slashed; mapping(bytes32 => uint256) public proposalYes; mapping(bytes32 => uint256) public proposalNo; mapping(bytes32 => mapping(address => bool)) public voted;
    mapping(uint8 => uint256) public categoryPool; mapping(uint8 => mapping(address => uint256)) public categoryRewards;
    struct Proposal { bytes32 id; bytes32 specificationHash; address proposer; uint64 createdAt; bool executed; }
    mapping(bytes32 => Proposal) public proposals;
    event CreditsIssued(address indexed who, uint256 amount); event CreditsSlashed(address indexed who, uint256 amount, bytes32 reason); event Delegated(address indexed from, address indexed to); event DAOProposal(bytes32 indexed id, address indexed proposer); event DAOClockVote(bytes32 indexed id, address indexed voter, bool support, uint256 spent, uint256 weight); event RewardAllocated(uint8 indexed category, address indexed worker, uint256 amount);
    modifier onlyOwner() { require(msg.sender == owner, "AppTeamDAO: owner"); _; }
    modifier onlyGovernance() { require(msg.sender == governance, "AppTeamDAO: governance"); _; }
    modifier onlyOracle() { require(msg.sender == oracle || msg.sender == owner, "AppTeamDAO: oracle"); _; }
    constructor(address governanceAddress, address workerSplitAddress, address oracleAddress) { require(governanceAddress != address(0) && workerSplitAddress != address(0), "AppTeamDAO: zero"); owner = msg.sender; governance = governanceAddress; workerSplit = workerSplitAddress; oracle = oracleAddress; cycleStart = uint64(block.timestamp); cycle = 1; }
    receive() external payable { revert("AppTeamDAO: no native fees"); }
    function setMember(address who, bool enabled) external onlyOwner { members[who] = enabled; }
    function issueCredits(address who, uint256 amount) external onlyOracle { require(amount <= MAX_CREDITS, "AppTeamDAO: max"); _roll(who); credits[who] = amount; usedCredits[who] = 0; emit CreditsIssued(who, amount); }
    function _roll(address who) internal { if (block.timestamp >= cycleStart + QUARTER) { cycle++; cycleStart = uint64(block.timestamp); usedCredits[who] = 0; } }
    function delegate(address who) external { require(who != msg.sender, "AppTeamDAO: self"); delegateOf[msg.sender] = who; emit Delegated(msg.sender, who); }
    function revokeDelegation() external { delete delegateOf[msg.sender]; emit Delegated(msg.sender, address(0)); }
    function propose(bytes32 id, bytes32 specificationHash) external { require(members[msg.sender] && proposals[id].proposer == address(0), "AppTeamDAO: proposal"); proposals[id] = Proposal(id, specificationHash, msg.sender, uint64(block.timestamp), false); emit DAOProposal(id, msg.sender); }
    function vote(bytes32 id, bool support, uint256 spent) external { require(proposals[id].proposer != address(0) && !voted[id][msg.sender], "AppTeamDAO: vote"); _roll(msg.sender); require(spent > 0 && spent <= credits[msg.sender] && usedCredits[msg.sender] + spent <= MAX_CREDITS, "AppTeamDAO: credits"); voted[id][msg.sender] = true; usedCredits[msg.sender] += spent; uint256 weight = spent * spent; if (support) proposalYes[id] += weight; else proposalNo[id] += weight; emit DAOClockVote(id, msg.sender, support, spent, weight); }
    function slash(address who, uint256 amount, bytes32 reason) external onlyGovernance { require(amount <= credits[who], "AppTeamDAO: slash"); credits[who] -= amount; slashed[who] += amount; emit CreditsSlashed(who, amount, reason); }
    function receiveWorkerPool(uint256 amount) external { require(msg.sender == workerSplit, "AppTeamDAO: worker split"); appPool += amount; }
    function allocate(uint8 category, address worker, uint256 amount) external onlyGovernance { require(category <= DECENTRALAND && amount <= appPool, "AppTeamDAO: allocation"); appPool -= amount; categoryPool[category] += amount; categoryRewards[category][worker] += amount; emit RewardAllocated(category, worker, amount); }
    function claim(uint8 category) external { uint256 amount = categoryRewards[category][msg.sender]; require(amount > 0, "AppTeamDAO: none"); categoryRewards[category][msg.sender] = 0; (bool ok,) = msg.sender.call{value: 0}(""); require(ok); }
    function appTeamProposalActivated(bytes32 id) external view returns (bool) { return proposals[id].executed; }
    function execute(bytes32 id) external onlyGovernance { require(!proposals[id].executed && proposalYes[id] > proposalNo[id], "AppTeamDAO: rejected"); proposals[id].executed = true; }
}
