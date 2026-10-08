// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GenesisGovernance
 * @notice Canonical GIP (Genesis Improvement Proposal) protocol with activation gates,
 * multi-stakeholder weighted voting, and AppTeam credit integration.
 *
 * GIP Process:
 * 1. Draft -> Review (7 days) -> LastCall (28 days) -> Staged -> Implemented
 * 2. Voting requires >50% positive signals from weighted stakeholder groups
 * 3. Activation gated on bootstrap prerequisites:
 *    - At least 30 unique digital transactions across 30 states
 *    - At least 10 unique ATM transactions across 10 states
 *    - All activation-signal mechanisms enabled and instructions published
 *
 * Signal Weights (must sum to >50% positive):
 * - Verifiers: 15% (validator credit pool)
 * - Validators: 15% (validator credit pool)
 * - ATM operators: 15% (ATM operator registry)
 * - Note Team: 15% (note team worker pool)
 * - AppTeam: 15% (AppTeamDAO credit pool, quadratic voting)
 * - ATM Customers: 25% (1%+ of verified unique ATM customer votes)
 *
 * Voting: Quadratic cost function (credits spent^2 = votes cast)
 */

interface IAppTeamDAO {
    function appTeamProposalActivated(bytes32 id) external view returns (bool);
    function credits(address who) external view returns (uint256);
    function delegateOf(address who) external view returns (address);
}

interface IValidatorRegistry {
    function validators(address who) external view returns (bool);
    function activeValidatorCount() external view returns (uint256);
}

interface IVerifierRegistry {
    function verifiers(address who) external view returns (bool);
    function activeVerifierCount() external view returns (uint256);
}

interface INoteTeamRegistry {
    function noteTeamMembers(address who) external view returns (bool);
    function activeNoteTeamCount() external view returns (uint256);
}

interface IATMOperatorRegistry {
    function atmOperators(address who) external view returns (bool);
    function activeATMOperatorCount() external view returns (uint256);
}

interface IATMCustomerRegistry {
    function uniqueCustomerCount() external view returns (uint256);
    function verifyCustomerVote(address who) external view returns (bool);
}

contract GenesisGovernance {
    enum Track { Authentication, Core, Interface, Knowledge, Oracle, Process }
    enum Status { Draft, Review, LastCall, Staged, Implemented, NotImplemented }

    // Timing constants
    uint64 public constant REVIEW_PERIOD = 7 days;
    uint64 public constant LAST_CALL_PERIOD = 28 days;
    uint64 public constant ACTIVATION_WINDOW = 12 weeks;

    // Voting and signal constants
    uint256 public constant BPS = 10_000;
    uint256 public constant REQUIRED_BPS = 5001; // >50%
    uint256 public constant MAX_CREDITS = 150;

    // Signal weight allocations (sum = 10,000 bps)
    uint256 public constant VERIFIER_WEIGHT = 1500;      // 15%
    uint256 public constant VALIDATOR_WEIGHT = 1500;     // 15%
    uint256 public constant ATM_OPERATOR_WEIGHT = 1500;  // 15%
    uint256 public constant NOTE_TEAM_WEIGHT = 1500;     // 15%
    uint256 public constant APP_TEAM_WEIGHT = 1500;      // 15%
    uint256 public constant CUSTOMER_WEIGHT = 2500;      // 25%

    // Bootstrap activation gate constants
    uint256 public constant REQUIRED_DIGITAL_STATES = 30;
    uint256 public constant REQUIRED_ATM_STATES = 10;

    // Core governance state
    address public owner;
    IAppTeamDAO public appTeamDAO;
    IValidatorRegistry public validatorRegistry;
    IVerifierRegistry public verifierRegistry;
    INoteTeamRegistry public noteTeamRegistry;
    IATMOperatorRegistry public atmOperatorRegistry;
    IATMCustomerRegistry public customerRegistry;

    // Bootstrap gate state
    uint256 public digitalTransactionStates;
    uint256 public atmTransactionStates;
    bool public activationSignalsEnabled;

    // GIP proposal state
    struct GiP {
        bytes32 id;
        Track track;
        address proposer;
        bytes32 specificationHash;
        bytes32 ordinalHash;
        uint64 createdAt;
        uint64 lastCallEnds;
        Status status;
    }

    mapping(bytes32 => GiP) public proposals;
    mapping(bytes32 => mapping(address => bool)) public voted;
    
    // Signal tracking: verifier, validator, atmOperator, noteTeam, appTeam, customer
    mapping(bytes32 => uint256) public verifierYes;
    mapping(bytes32 => uint256) public verifierNo;
    mapping(bytes32 => uint256) public validatorYes;
    mapping(bytes32 => uint256) public validatorNo;
    mapping(bytes32 => uint256) public atmOperatorYes;
    mapping(bytes32 => uint256) public atmOperatorNo;
    mapping(bytes32 => uint256) public noteTeamYes;
    mapping(bytes32 => uint256) public noteTeamNo;
    mapping(bytes32 => uint256) public appTeamYes;
    mapping(bytes32 => uint256) public appTeamNo;
    mapping(bytes32 => uint256) public customerYes;
    mapping(bytes32 => uint256) public customerNo;

    // Credit ledger for GIP voting
    mapping(address => uint256) public credits;
    mapping(address => address) public delegateOf;

    // Events
    event GiPProposed(bytes32 indexed id, Track track, bytes32 specificationHash, bytes32 ordinalHash);
    event ReviewEntered(bytes32 indexed id);
    event LastCallEntered(bytes32 indexed id);
    event VoteCast(
        bytes32 indexed id,
        address indexed voter,
        string indexed stakeholderType,
        bool support,
        uint256 creditSpent,
        uint256 weight
    );
    event StatusChanged(bytes32 indexed id, Status status);
    event BootstrapGateUpdated(uint256 digitalStates, uint256 atmStates, bool signalsEnabled);
    event AppTeamDAORegistered(address indexed dao);
    event RegistryUpdated(string registryType, address indexed registry);
    event CreditsIssued(address indexed member, uint256 amount);
    event Delegated(address indexed from, address indexed to);

    modifier onlyOwner() {
        require(msg.sender == owner, "GenesisGovernance: owner only");
        _;
    }

    constructor(address appTeamDAOAddress) {
        require(appTeamDAOAddress != address(0), "GenesisGovernance: zero address");
        owner = msg.sender;
        appTeamDAO = IAppTeamDAO(appTeamDAOAddress);
    }

    // ============ Registry Setup ============

    function setAppTeamDAO(address dao) external onlyOwner {
        require(dao != address(0), "GenesisGovernance: zero address");
        appTeamDAO = IAppTeamDAO(dao);
        emit AppTeamDAORegistered(dao);
    }

    function setValidatorRegistry(address registry) external onlyOwner {
        require(registry != address(0), "GenesisGovernance: zero address");
        validatorRegistry = IValidatorRegistry(registry);
        emit RegistryUpdated("ValidatorRegistry", registry);
    }

    function setVerifierRegistry(address registry) external onlyOwner {
        require(registry != address(0), "GenesisGovernance: zero address");
        verifierRegistry = IVerifierRegistry(registry);
        emit RegistryUpdated("VerifierRegistry", registry);
    }

    function setNoteTeamRegistry(address registry) external onlyOwner {
        require(registry != address(0), "GenesisGovernance: zero address");
        noteTeamRegistry = INoteTeamRegistry(registry);
        emit RegistryUpdated("NoteTeamRegistry", registry);
    }

    function setATMOperatorRegistry(address registry) external onlyOwner {
        require(registry != address(0), "GenesisGovernance: zero address");
        atmOperatorRegistry = IATMOperatorRegistry(registry);
        emit RegistryUpdated("ATMOperatorRegistry", registry);
    }

    function setCustomerRegistry(address registry) external onlyOwner {
        require(registry != address(0), "GenesisGovernance: zero address");
        customerRegistry = IATMCustomerRegistry(registry);
        emit RegistryUpdated("CustomerRegistry", registry);
    }

    // ============ Bootstrap Gate Management ============

    /**
     * @notice Update bootstrap activation gate state
     * Called by owner when digital/ATM transaction state counts reach thresholds
     * @param digitalStates Count of unique states with digital transactions
     * @param atmStates Count of unique states with ATM transactions
     * @param signalsEnabled True if all activation-signal mechanisms are in place
     */
    function setBootstrapGate(uint256 digitalStates, uint256 atmStates, bool signalsEnabled) external onlyOwner {
        digitalTransactionStates = digitalStates;
        atmTransactionStates = atmStates;
        activationSignalsEnabled = signalsEnabled;
        emit BootstrapGateUpdated(digitalStates, atmStates, signalsEnabled);
    }

    /**
     * @notice Check if bootstrap activation gate is satisfied
     */
    function isBootstrapGatePassed() public view returns (bool) {
        return
            digitalTransactionStates >= REQUIRED_DIGITAL_STATES &&
            atmTransactionStates >= REQUIRED_ATM_STATES &&
            activationSignalsEnabled;
    }

    // ============ Credits and Delegation ============

    /**
     * @notice Issue voting credits to a member
     * @param member Address to issue credits to
     * @param amount Credits to issue (capped at MAX_CREDITS)
     */
    function issueCredits(address member, uint256 amount) external onlyOwner {
        require(amount <= MAX_CREDITS, "GenesisGovernance: credits exceed max");
        credits[member] = amount;
        emit CreditsIssued(member, amount);
    }

    /**
     * @notice Delegate voting credits to another address
     * @param to Address to delegate to
     */
    function setDelegate(address to) external {
        delegateOf[msg.sender] = to;
        emit Delegated(msg.sender, to);
    }

    /**
     * @notice Get effective voting credits (considering delegation)
     */
    function getEffectiveCredits(address member) external view returns (uint256) {
        if (delegateOf[member] != address(0)) {
            return 0; // Delegated credits don't count for delegator
        }
        return credits[member];
    }

    // ============ GIP Proposal Lifecycle ============

    /**
     * @notice Propose a new GIP
     * @param id Unique proposal ID (keccak256 of spec hash and ordinal hash)
     * @param track GIP track (Authentication, Core, Interface, Knowledge, Oracle, Process)
     * @param specificationHash Hash of proposal specification
     * @param ordinalHash Hash of ordinal/sequence identifier
     */
    function propose(bytes32 id, Track track, bytes32 specificationHash, bytes32 ordinalHash) external {
        require(proposals[id].proposer == address(0), "GenesisGovernance: proposal exists");

        proposals[id] = GiP({
            id: id,
            track: track,
            proposer: msg.sender,
            specificationHash: specificationHash,
            ordinalHash: ordinalHash,
            createdAt: uint64(block.timestamp),
            lastCallEnds: uint64(block.timestamp) + REVIEW_PERIOD + LAST_CALL_PERIOD,
            status: Status.Review
        });

        emit GiPProposed(id, track, specificationHash, ordinalHash);
    }

    /**
     * @notice Transition proposal from Review to LastCall
     * Only owner; requires REVIEW_PERIOD to have elapsed
     */
    function enterLastCall(bytes32 id) external onlyOwner {
        GiP storage p = proposals[id];
        require(p.proposer != address(0), "GenesisGovernance: proposal not found");
        require(p.status == Status.Review, "GenesisGovernance: not in review");
        require(block.timestamp >= p.createdAt + REVIEW_PERIOD, "GenesisGovernance: review period active");

        p.status = Status.LastCall;
        emit LastCallEntered(id);
    }

    /**
     * @notice Cast a vote on a GIP proposal using quadratic voting
     * Stakeholder type is determined by caller's registry membership
     * Quadratic cost: credits spent^2 = votes cast
     *
     * @param id Proposal ID to vote on
     * @param support True for yes, false for no
     * @param spent Credits to spend (quadratic voting)
     */
    function vote(bytes32 id, bool support, uint256 spent) external {
        GiP storage p = proposals[id];
        require(p.proposer != address(0), "GenesisGovernance: proposal not found");
        require(p.status == Status.Review || p.status == Status.LastCall, "GenesisGovernance: inactive");
        require(block.timestamp < p.lastCallEnds, "GenesisGovernance: voting closed");
        require(!voted[id][msg.sender], "GenesisGovernance: already voted");
        require(spent > 0 && spent <= credits[msg.sender], "GenesisGovernance: insufficient credits");

        voted[id][msg.sender] = true;

        // Quadratic voting: weight = spent^2
        uint256 weight = spent * spent;

        // Determine stakeholder type and route vote to appropriate ledger
        string memory stakeholderType;

        if (address(verifierRegistry) != address(0) && isVerifier(msg.sender)) {
            if (support) verifierYes[id] += weight;
            else verifierNo[id] += weight;
            stakeholderType = "Verifier";
        } else if (address(validatorRegistry) != address(0) && isValidator(msg.sender)) {
            if (support) validatorYes[id] += weight;
            else validatorNo[id] += weight;
            stakeholderType = "Validator";
        } else if (address(atmOperatorRegistry) != address(0) && isATMOperator(msg.sender)) {
            if (support) atmOperatorYes[id] += weight;
            else atmOperatorNo[id] += weight;
            stakeholderType = "ATMOperator";
        } else if (address(noteTeamRegistry) != address(0) && isNoteTeamMember(msg.sender)) {
            if (support) noteTeamYes[id] += weight;
            else noteTeamNo[id] += weight;
            stakeholderType = "NoteTeam";
        } else if (address(appTeamDAO) != address(0) && isAppTeamMember(msg.sender)) {
            if (support) appTeamYes[id] += weight;
            else appTeamNo[id] += weight;
            stakeholderType = "AppTeam";
        } else if (address(customerRegistry) != address(0) && isCustomer(msg.sender)) {
            if (support) customerYes[id] += weight;
            else customerNo[id] += weight;
            stakeholderType = "Customer";
        } else {
            revert("GenesisGovernance: not a stakeholder");
        }

        emit VoteCast(id, msg.sender, stakeholderType, support, spent, weight);
    }

    /**
     * @notice Resolve proposal: compute weighted signals and determine pass/fail
     * Only owner; requires LastCall period to have ended
     */
    function resolve(bytes32 id) external onlyOwner {
        GiP storage p = proposals[id];
        require(p.proposer != address(0), "GenesisGovernance: proposal not found");
        require(p.status == Status.LastCall, "GenesisGovernance: not in last call");
        require(block.timestamp >= p.lastCallEnds, "GenesisGovernance: last call active");

        bool passed = computeWeightedSignals(id);

        if (passed) {
            p.status = Status.Staged;
        } else {
            p.status = Status.NotImplemented;
        }

        emit StatusChanged(id, p.status);
    }

    /**
     * @notice Activate proposal to Implemented state
     * Only owner; requires bootstrap gate to be passed and activation window still open
     */
    function activate(bytes32 id) external onlyOwner {
        GiP storage p = proposals[id];
        require(p.proposer != address(0), "GenesisGovernance: proposal not found");
        require(p.status == Status.Staged, "GenesisGovernance: not staged");
        require(isBootstrapGatePassed(), "GenesisGovernance: bootstrap gate not passed");
        require(
            block.timestamp <= p.lastCallEnds + ACTIVATION_WINDOW,
            "GenesisGovernance: activation window closed"
        );

        p.status = Status.Implemented;
        emit StatusChanged(id, p.status);
    }

    // ============ Weighted Signal Calculation ============

    /**
     * @notice Compute weighted signals across all stakeholder groups
     * Returns true if >50% positive signals across the weighted portfolio
     */
    function computeWeightedSignals(bytes32 id) public view returns (bool) {
        // Get positive signals for each stakeholder type
        uint256 verifierPositive = verifierYes[id];
        uint256 verifierTotal = verifierYes[id] + verifierNo[id];

        uint256 validatorPositive = validatorYes[id];
        uint256 validatorTotal = validatorYes[id] + validatorNo[id];

        uint256 atmOperatorPositive = atmOperatorYes[id];
        uint256 atmOperatorTotal = atmOperatorYes[id] + atmOperatorNo[id];

        uint256 noteTeamPositive = noteTeamYes[id];
        uint256 noteTeamTotal = noteTeamYes[id] + noteTeamNo[id];

        uint256 appTeamPositive = appTeamYes[id];
        uint256 appTeamTotal = appTeamYes[id] + appTeamNo[id];

        uint256 customerPositive = customerYes[id];
        uint256 customerTotal = customerYes[id] + customerNo[id];

        // Compute positive signal ratios (as basis points)
        uint256 verifierRatio = verifierTotal == 0 ? 0 : (verifierPositive * BPS) / verifierTotal;
        uint256 validatorRatio = validatorTotal == 0 ? 0 : (validatorPositive * BPS) / validatorTotal;
        uint256 atmOperatorRatio = atmOperatorTotal == 0 ? 0 : (atmOperatorPositive * BPS) / atmOperatorTotal;
        uint256 noteTeamRatio = noteTeamTotal == 0 ? 0 : (noteTeamPositive * BPS) / noteTeamTotal;
        uint256 appTeamRatio = appTeamTotal == 0 ? 0 : (appTeamPositive * BPS) / appTeamTotal;
        uint256 customerRatio = customerTotal == 0 ? 0 : (customerPositive * BPS) / customerTotal;

        // Compute weighted aggregate (sum of weight * ratio / BPS)
        uint256 aggregatePositive =
            (VERIFIER_WEIGHT * verifierRatio) / BPS +
            (VALIDATOR_WEIGHT * validatorRatio) / BPS +
            (ATM_OPERATOR_WEIGHT * atmOperatorRatio) / BPS +
            (NOTE_TEAM_WEIGHT * noteTeamRatio) / BPS +
            (APP_TEAM_WEIGHT * appTeamRatio) / BPS +
            (CUSTOMER_WEIGHT * customerRatio) / BPS;

        return aggregatePositive >= REQUIRED_BPS;
    }

    // ============ Stakeholder Membership Checks ============

    function isVerifier(address member) public view returns (bool) {
        if (address(verifierRegistry) == address(0)) return false;
        return verifierRegistry.verifiers(member);
    }

    function isValidator(address member) public view returns (bool) {
        if (address(validatorRegistry) == address(0)) return false;
        return validatorRegistry.validators(member);
    }

    function isATMOperator(address member) public view returns (bool) {
        if (address(atmOperatorRegistry) == address(0)) return false;
        return atmOperatorRegistry.atmOperators(member);
    }

    function isNoteTeamMember(address member) public view returns (bool) {
        if (address(noteTeamRegistry) == address(0)) return false;
        return noteTeamRegistry.noteTeamMembers(member);
    }

    function isAppTeamMember(address member) public view returns (bool) {
        if (address(appTeamDAO) == address(0)) return false;
        uint256 memberCredits = appTeamDAO.credits(member);
        return memberCredits > 0;
    }

    function isCustomer(address member) public view returns (bool) {
        if (address(customerRegistry) == address(0)) return false;
        return customerRegistry.verifyCustomerVote(member);
    }

    // ============ View Functions ============

    /**
     * @notice Get proposal details
     */
    function getProposal(bytes32 id) external view returns (GiP memory) {
        return proposals[id];
    }

    /**
     * @notice Get signal counts for all stakeholder types
     */
    function getSignalCounts(bytes32 id)
        external
        view
        returns (
            uint256 vYes, uint256 vNo,
            uint256 valYes, uint256 valNo,
            uint256 atmYes, uint256 atmNo,
            uint256 ntYes, uint256 ntNo,
            uint256 atYes, uint256 atNo,
            uint256 cYes, uint256 cNo
        )
    {
        return (
            verifierYes[id], verifierNo[id],
            validatorYes[id], validatorNo[id],
            atmOperatorYes[id], atmOperatorNo[id],
            noteTeamYes[id], noteTeamNo[id],
            appTeamYes[id], appTeamNo[id],
            customerYes[id], customerNo[id]
        );
    }

    /**
     * @notice Get bootstrap gate status
     */
    function getBootstrapStatus() external view returns (uint256 digital, uint256 atm, bool signals, bool passed) {
        return (digitalTransactionStates, atmTransactionStates, activationSignalsEnabled, isBootstrapGatePassed());
    }
}
