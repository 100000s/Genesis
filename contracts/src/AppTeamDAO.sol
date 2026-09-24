// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20App { function transfer(address to, uint256 amount) external returns (bool); }

/// @notice App Team treasury, contribution credits, quadratic internal voting and delivery allocation ledger.
contract AppTeamDAO {
    uint256 public constant MAX_CREDITS = 150;
    uint64 public constant CYCLE = 90 days;
    uint8 public constant CATEGORY_COUNT = 10;
    uint8 public constant NOTE_RND = 0; uint8 public constant MERCHANT = 1;
    uint8 public constant ANDROID_IOS = 2; uint8 public constant OLD_PC = 3;
    uint8 public constant OLD_PHONE = 4; uint8 public constant SATELLITE = 5;
    uint8 public constant RADIO = 6; uint8 public constant GENESIS_MALL = 7;
    uint8 public constant SECOND_LIFE = 8; uint8 public constant DECENTRALAND = 9;

    address public owner; address public governance; address public workerSplit; address public token;
    uint64 public cycle; uint64 public cycleStart; uint256 public appPool;
    mapping(address => bool) public members;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public usedCredits;
    mapping(address => uint64) public creditCycle;
    mapping(address => address) public delegateOf;
    mapping(address => uint256) public slashed;
    mapping(uint8 => uint256) public categoryPool;
    mapping(uint8 => mapping(address => uint256)) public categoryRewards;
    mapping(bytes32 => uint256) public proposalYes;
    mapping(bytes32 => uint256) public proposalNo;
    mapping(bytes32 => mapping(address => bool)) public voted;
    mapping(bytes32 => bool) public executed;
    mapping(bytes32 => address) public proposer;

    event CreditsIssued(address indexed who, uint256 amount, uint64 cycle);
    event CreditsSlashed(address indexed who, uint256 amount, bytes32 reason);
    event Delegated(address indexed from, address indexed to);
    event ProposalCreated(bytes32 indexed id, address indexed proposer);
    event VoteCast(bytes32 indexed id, address indexed voter, bool support, uint256 spent, uint256 weight);
    event RewardAllocated(uint8 indexed category, address indexed worker, uint256 amount);
    event RewardClaimed(uint8 indexed category, address indexed worker, uint256 amount);
    event WorkerPoolReceived(uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "AppTeamDAO: owner"); _; }
    modifier onlyGovernance() { require(msg.sender == governance, "AppTeamDAO: governance"); _; }
    modifier onlyCreditOracle() { require(msg.sender == owner || msg.sender == governance, "AppTeamDAO: oracle"); _; }

    constructor(address governanceAddress, address workerSplitAddress, address tokenAddress) {
        require(governanceAddress != address(0) && workerSplitAddress != address(0), "AppTeamDAO: zero");
        owner = msg.sender; governance = governanceAddress; workerSplit = workerSplitAddress; token = tokenAddress;
        cycle = 1; cycleStart = uint64(block.timestamp);
    }
    receive() external payable { revert("AppTeamDAO: no native fees"); }
    function setMember(address who, bool enabled) external onlyOwner { members[who] = enabled; }
    function setToken(address tokenAddress) external onlyOwner { require(tokenAddress != address(0), "AppTeamDAO: zero"); token = tokenAddress; }
    function issueCredits(address who, uint256 amount) external onlyCreditOracle {
        require(amount <= MAX_CREDITS, "AppTeamDAO: max");
        _sync(who); credits[who] = amount; usedCredits[who] = 0; emit CreditsIssued(who, amount, cycle);
    }
    function _sync(address who) internal { if (creditCycle[who] != cycle) { creditCycle[who] = cycle; usedCredits[who] = 0; } }
    function advanceCycle() external { require(block.timestamp >= cycleStart + CYCLE, "AppTeamDAO: cycle"); cycle++; cycleStart = uint64(block.timestamp); }
    function delegate(address to) external { require(to != msg.sender, "AppTeamDAO: self"); delegateOf[msg.sender] = to; emit Delegated(msg.sender, to); }
    function revokeDelegation() external { delete delegateOf[msg.sender]; emit Delegated(msg.sender, address(0)); }
    function propose(bytes32 id, bytes32 specificationHash) external { specificationHash; require(members[msg.sender] && proposer[id] == address(0), "AppTeamDAO: proposal"); proposer[id] = msg.sender; emit ProposalCreated(id, msg.sender); }
    function vote(bytes32 id, bool support, uint256 spent) external {
        require(proposer[id] != address(0) && !voted[id][msg.sender], "AppTeamDAO: vote"); _sync(msg.sender);
        require(spent > 0 && spent <= credits[msg.sender] && usedCredits[msg.sender] + spent <= MAX_CREDITS, "AppTeamDAO: credits");
        voted[id][msg.sender] = true; usedCredits[msg.sender] += spent; uint256 weight = spent * spent;
        if (support) proposalYes[id] += weight; else proposalNo[id] += weight;
        emit VoteCast(id, msg.sender, support, spent, weight);
    }
    function slash(address who, uint256 amount, bytes32 reason) external onlyGovernance { require(amount <= credits[who], "AppTeamDAO: slash"); credits[who] -= amount; slashed[who] += amount; emit CreditsSlashed(who, amount, reason); }
    function notifyWorkerPool(uint256 amount) external { require(msg.sender == workerSplit, "AppTeamDAO: worker split"); appPool += amount; emit WorkerPoolReceived(amount); }
    function allocate(uint8 category, address worker, uint256 amount) external onlyGovernance { require(category < CATEGORY_COUNT && worker != address(0) && amount <= appPool, "AppTeamDAO: allocation"); appPool -= amount; categoryPool[category] += amount; categoryRewards[category][worker] += amount; emit RewardAllocated(category, worker, amount); }
    function claim(uint8 category) external { uint256 amount = categoryRewards[category][msg.sender]; require(amount > 0 && token != address(0), "AppTeamDAO: none"); categoryRewards[category][msg.sender] = 0; require(IERC20App(token).transfer(msg.sender, amount), "AppTeamDAO: transfer"); emit RewardClaimed(category, msg.sender, amount); }
    function execute(bytes32 id) external onlyGovernance { require(!executed[id] && proposalYes[id] > proposalNo[id], "AppTeamDAO: rejected"); executed[id] = true; }
    function appTeamProposalActivated(bytes32 id) external view returns (bool) { return executed[id]; }
}
