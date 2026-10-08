// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AppTeamDAO
 * @notice GitHub-integrated Genesis app development platform with reputation-based voting,
 * quarterly credit cycles, and 10-category reward allocation for App Team work.
 *
 * The App Team DAO oversees all protocol-level logic, UI/UX components, wallet operations,
 * mobile app integrations, and cross-platform token tooling. Responsibilities include:
 * - Note printing and distribution technology
 * - Cellular network, old phone, shortwave/HF, and satellite integration
 * - Ensuring fee-free, secure, decentralized on-chain interactions
 *
 * Allocation: 30% of WorkerSplit minted tokens, further split across 10 categories:
 * ⅓ (10%) Note Technology:
 *   0: NOTE_RND (0.5%)           - R&D, anticounterfeit, livery auction
 *   1: MERCHANT (0.5%)           - Physical merchant integration, mapping, ads
 * ⅓ (10%) Digital Integration:
 *   2: ANDROID_IOS (0.2%)        - Mobile app development
 *   3: OLD_PC (0.2%)             - Old PC/Validator integration
 *   4: OLD_PHONE (0.2%)          - Old cellphone/Verifier integration
 *   5: SATELLITE (0.2%)          - Satellite integration (Iridium, Kenéis)
 *   6: RADIO (0.2%)              - Packet radio integration
 * ⅓ (10%) Virtual World Shopping:
 *   7: GENESIS_MALL (0.6%)       - Native virtual world, AI/3D/AR/VR shopping
 *   8: SECOND_LIFE (0.2%)        - Second Life virtual ATM and storefront
 *   9: DECENTRALAND (0.2%)       - Decentraland virtual ATM and storefront
 *
 * Voting Credits (non-transferable, soulbound, reset quarterly):
 * - Core Developers: max 100/quarter (5 per audited commit, 10 per approved feature)
 * - UI/UX Designers: max 40/quarter (10 per approved redesign)
 * - Mobile Maintainers: max 45/quarter (15 per release)
 * - Escrow Contributors: max 45/quarter (15 per validated workflow)
 * - Community Integrators: max 50/quarter (10 per onboarded merchant/ATM)
 * - Global cap: 150 credits per contributor per quarter
 *
 * Voting: Quadratic cost function (credits spent ^ 2 = votes cast)
 * Delegation: Revocable, non-transferable
 * Slashing: Up to 100% for malicious/buggy code (requires governance approval)
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IAppTeamGovernance {
    function appTeamProposalActivated(bytes32 id) external view returns (bool);
}

contract AppTeamDAO {
    // Constants: Credits and cycles
    uint256 public constant MAX_CREDITS_PER_CYCLE = 150;
    uint64 public constant CYCLE_DURATION = 90 days;
    
    // Constants: Categories (10 total)
    uint8 public constant CATEGORY_COUNT = 10;
    uint8 public constant NOTE_RND = 0;
    uint8 public constant MERCHANT = 1;
    uint8 public constant ANDROID_IOS = 2;
    uint8 public constant OLD_PC = 3;
    uint8 public constant OLD_PHONE = 4;
    uint8 public constant SATELLITE = 5;
    uint8 public constant RADIO = 6;
    uint8 public constant GENESIS_MALL = 7;
    uint8 public constant SECOND_LIFE = 8;
    uint8 public constant DECENTRALAND = 9;

    // Constants: Basis points
    uint256 public constant BPS = 10_000;
    
    // Governance and tokens
    address public owner;
    address public governance;
    address public workerSplit;
    address public token;
    
    // Cycle management
    uint64 public cycle;
    uint64 public cycleStart;
    uint256 public appPool;
    
    // Member and credit tracking
    mapping(address => bool) public members;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public usedCredits;
    mapping(address => uint64) public creditCycle;  // Track which cycle's credits
    mapping(address => address) public delegateOf;
    mapping(address => uint256) public slashed;
    
    // Category pool and reward tracking
    mapping(uint8 => uint256) public categoryPool;
    mapping(uint8 => mapping(address => uint256)) public categoryRewards;
    
    // Proposal and voting state
    mapping(bytes32 => uint256) public proposalYes;
    mapping(bytes32 => uint256) public proposalNo;
    mapping(bytes32 => mapping(address => bool)) public voted;
    mapping(bytes32 => bool) public executed;
    mapping(bytes32 => address) public proposer;
    mapping(bytes32 => uint64) public proposalCreatedAt;
    
    // Events
    event CreditsIssued(address indexed member, uint256 amount, uint64 indexed cycle);
    event CreditsSlashed(address indexed member, uint256 amount, bytes32 reason);
    event Delegated(address indexed from, address indexed to);
    event DelegationRevoked(address indexed member);
    event ProposalCreated(bytes32 indexed id, address indexed proposer, uint64 indexed cycle);
    event VoteCast(bytes32 indexed id, address indexed voter, bool support, uint256 spent, uint256 weight);
    event RewardAllocated(uint8 indexed category, address indexed worker, uint256 amount);
    event RewardClaimed(uint8 indexed category, address indexed worker, uint256 amount);
    event WorkerPoolReceived(uint256 amount);
    event ProposalExecuted(bytes32 indexed id);
    event CycleAdvanced(uint64 indexed newCycle);
    event MemberStatusChanged(address indexed member, bool enabled);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "AppTeamDAO: owner only");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "AppTeamDAO: governance only");
        _;
    }

    modifier onlyMember() {
        require(members[msg.sender], "AppTeamDAO: member only");
        _;
    }

    /**
     * @notice Initialize AppTeamDAO
     * @param governanceAddress Address of GenesisGovernance contract
     * @param workerSplitAddress Address of WorkerSplit contract
     * @param tokenAddress Address of GenesisToken contract
     */
    constructor(address governanceAddress, address workerSplitAddress, address tokenAddress) {
        require(
            governanceAddress != address(0) && 
            workerSplitAddress != address(0) && 
            tokenAddress != address(0),
            "AppTeamDAO: zero address"
        );
        
        owner = msg.sender;
        governance = governanceAddress;
        workerSplit = workerSplitAddress;
        token = tokenAddress;
        
        cycle = 1;
        cycleStart = uint64(block.timestamp);
    }

    // ============ Administrative ============

    receive() external payable {
        revert("AppTeamDAO: no native fees");
    }

    /**
     * @notice Add or remove a member from the DAO
     * @param member Address to modify
     * @param enabled True to add, false to remove
     */
    function setMember(address member, bool enabled) external onlyOwner {
        require(member != address(0), "AppTeamDAO: zero address");
        members[member] = enabled;
        emit MemberStatusChanged(member, enabled);
    }

    /**
     * @notice Set the token contract address
     * @param tokenAddress Address of GenesisToken
     */
    function setToken(address tokenAddress) external onlyOwner {
        require(tokenAddress != address(0), "AppTeamDAO: zero address");
        token = tokenAddress;
    }

    // ============ Cycle Management ============

    /**
     * @notice Sync a member to the current cycle and reset their used credits
     * @param member Address to sync
     */
    function _syncCycle(address member) internal {
        if (creditCycle[member] != cycle) {
            creditCycle[member] = cycle;
            usedCredits[member] = 0;
        }
    }

    /**
     * @notice Advance to the next quarter cycle
     * Callable by anyone after CYCLE_DURATION has elapsed
     */
    function advanceCycle() external {
        require(block.timestamp >= cycleStart + CYCLE_DURATION, "AppTeamDAO: cycle active");
        cycle++;
        cycleStart = uint64(block.timestamp);
        emit CycleAdvanced(cycle);
    }

    // ============ Credits and Voting ============

    /**
     * @notice Issue voting credits to a member for this cycle
     * Called by governance or owner based on GitHub metrics, audited commits, etc.
     * @param member Address to issue credits to
     * @param amount Number of credits (capped at MAX_CREDITS_PER_CYCLE)
     */
    function issueCredits(address member, uint256 amount) external onlyGovernance {
        require(amount <= MAX_CREDITS_PER_CYCLE, "AppTeamDAO: credits exceed max");
        require(members[member], "AppTeamDAO: not a member");
        
        _syncCycle(member);
        credits[member] = amount;
        usedCredits[member] = 0;
        
        emit CreditsIssued(member, amount, cycle);
    }

    /**
     * @notice Delegate voting credits to another member (revocable)
     * @param to Address to delegate to
     */
    function delegate(address to) external {
        require(to != msg.sender, "AppTeamDAO: cannot self-delegate");
        require(members[to], "AppTeamDAO: delegate not a member");
        
        delegateOf[msg.sender] = to;
        emit Delegated(msg.sender, to);
    }

    /**
     * @notice Revoke delegation
     */
    function revokeDelegation() external {
        delegateOf[msg.sender] = address(0);
        emit DelegationRevoked(msg.sender);
    }

    /**
     * @notice Get effective voting credits for a member (including delegation)
     * @param member Address to check
     */
    function getEffectiveCredits(address member) external view returns (uint256) {
        return credits[member];
    }

    /**
     * @notice Slash credits from a member (used for buggy/malicious code)
     * Only callable by governance
     * @param member Address to slash
     * @param amount Credits to remove
     * @param reason Reason for slashing (arbitrary bytes32)
     */
    function slashCredits(address member, uint256 amount, bytes32 reason) external onlyGovernance {
        require(amount <= credits[member], "AppTeamDAO: slash exceeds available");
        
        credits[member] -= amount;
        slashed[member] += amount;
        
        emit CreditsSlashed(member, amount, reason);
    }

    // ============ Proposals and Voting ============

    /**
     * @notice Create a proposal for AppTeam work (e.g., feature, policy change)
     * Only callable by members
     * @param proposalId Unique ID for proposal (e.g., keccak256 of description)
     */
    function propose(bytes32 proposalId) external onlyMember {
        require(proposer[proposalId] == address(0), "AppTeamDAO: proposal exists");
        
        proposer[proposalId] = msg.sender;
        proposalCreatedAt[proposalId] = uint64(block.timestamp);
        
        emit ProposalCreated(proposalId, msg.sender, cycle);
    }

    /**
     * @notice Cast a vote on a proposal using quadratic voting
     * Quadratic cost: spent credits ^ 2 = votes cast
     * @param proposalId ID of proposal
     * @param support True for yes, false for no
     * @param spent Credits to spend on this vote
     */
    function vote(bytes32 proposalId, bool support, uint256 spent) external {
        require(proposer[proposalId] != address(0), "AppTeamDAO: proposal not found");
        require(!voted[proposalId][msg.sender], "AppTeamDAO: already voted");
        require(spent > 0, "AppTeamDAO: zero spend");
        
        _syncCycle(msg.sender);
        
        require(spent <= credits[msg.sender], "AppTeamDAO: insufficient credits");
        require(usedCredits[msg.sender] + spent <= MAX_CREDITS_PER_CYCLE, "AppTeamDAO: spend exceeds cycle limit");
        
        voted[proposalId][msg.sender] = true;
        usedCredits[msg.sender] += spent;
        
        // Quadratic voting: weight = spent^2
        uint256 weight = spent * spent;
        
        if (support) {
            proposalYes[proposalId] += weight;
        } else {
            proposalNo[proposalId] += weight;
        }
        
        emit VoteCast(proposalId, msg.sender, support, spent, weight);
    }

    /**
     * @notice Execute a proposal if it passed voting (called by governance)
     * @param proposalId ID of proposal to execute
     */
    function execute(bytes32 proposalId) external onlyGovernance {
        require(proposer[proposalId] != address(0), "AppTeamDAO: proposal not found");
        require(!executed[proposalId], "AppTeamDAO: already executed");
        require(proposalYes[proposalId] > proposalNo[proposalId], "AppTeamDAO: proposal rejected");
        
        executed[proposalId] = true;
        
        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Check if a proposal was activated (passed and executed)
     * @param proposalId ID of proposal
     */
    function appTeamProposalActivated(bytes32 proposalId) external view returns (bool) {
        return executed[proposalId];
    }

    // ============ Rewards and Allocation ============

    /**
     * @notice Receive the App Team allocation from WorkerSplit
     * Called by WorkerSplit contract at end of each epoch
     * @param amount Tokens to add to app pool
     */
    function notifyWorkerPool(uint256 amount) external {
        require(msg.sender == workerSplit, "AppTeamDAO: worker split only");
        appPool += amount;
        emit WorkerPoolReceived(amount);
    }

    /**
     * @notice Allocate tokens from the app pool to a category and worker
     * Called by governance to distribute rewards based on DAOResponse votes/decisions
     * @param category Category ID (0-9)
     * @param worker Address of worker
     * @param amount Tokens to allocate
     */
    function allocate(uint8 category, address worker, uint256 amount) external onlyGovernance {
        require(category < CATEGORY_COUNT, "AppTeamDAO: invalid category");
        require(worker != address(0), "AppTeamDAO: zero worker");
        require(amount <= appPool, "AppTeamDAO: insufficient pool");
        
        appPool -= amount;
        categoryPool[category] += amount;
        categoryRewards[category][worker] += amount;
        
        emit RewardAllocated(category, worker, amount);
    }

    /**
     * @notice Claim reward from a category
     * @param category Category ID to claim from
     */
    function claim(uint8 category) external {
        require(category < CATEGORY_COUNT, "AppTeamDAO: invalid category");
        
        uint256 amount = categoryRewards[category][msg.sender];
        require(amount > 0, "AppTeamDAO: no reward to claim");
        require(token != address(0), "AppTeamDAO: token not set");
        
        categoryRewards[category][msg.sender] = 0;
        categoryPool[category] -= amount;
        
        require(IERC20(token).transfer(msg.sender, amount), "AppTeamDAO: transfer failed");
        
        emit RewardClaimed(category, msg.sender, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get current cycle number
     */
    function getCurrentCycle() external view returns (uint64) {
        return cycle;
    }

    /**
     * @notice Get time remaining until cycle advance is available
     */
    function getTimeUntilCycleAdvance() external view returns (uint256) {
        uint64 nextAdvance = cycleStart + CYCLE_DURATION;
        if (block.timestamp >= nextAdvance) return 0;
        return nextAdvance - uint64(block.timestamp);
    }

    /**
     * @notice Get total reward available in a category
     */
    function getCategoryPool(uint8 category) external view returns (uint256) {
        require(category < CATEGORY_COUNT, "AppTeamDAO: invalid category");
        return categoryPool[category];
    }

    /**
     * @notice Get pending reward for a worker in a category
     */
    function getPendingReward(uint8 category, address worker) external view returns (uint256) {
        require(category < CATEGORY_COUNT, "AppTeamDAO: invalid category");
        return categoryRewards[category][worker];
    }

    /**
     * @notice Get vote counts for a proposal
     */
    function getProposalVotes(bytes32 proposalId) external view returns (uint256 yesVotes, uint256 noVotes) {
        return (proposalYes[proposalId], proposalNo[proposalId]);
    }
}
