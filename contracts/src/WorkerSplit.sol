// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorkerIssuance {
    function mintWorkerReward(address recipient, uint256 amount) external;
}

interface IWorkerOracle {
    function getDynamicIssuanceRateBps() external view returns (uint256);
    function getTwapMultiplier() external view returns (uint256);
}

interface IAppRewardSink {
    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external;
}

interface INoteRewardSink {
    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external;
}

/// @notice Monthly allocation ledger. Earned epoch pools are permanent liabilities:
/// claims remain available indefinitely and are never recycled after allocation.
contract WorkerSplit {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant BASE_FLOOR_BPS = 50;
    uint64 public constant EPOCH_DURATION = 30 days;

    uint8 public constant VALIDATOR = 0;
    uint8 public constant VERIFIER = 1;
    uint8 public constant APP = 2;
    uint8 public constant NOTE = 3;
    uint8 public constant ARBITRATOR = 4;

    uint256 public constant VALIDATOR_RATIO = 2_000;
    uint256 public constant VERIFIER_RATIO = 2_000;
    uint256 public constant APP_RATIO = 3_000;
    uint256 public constant NOTE_RATIO = 2_000;
    uint256 public constant ARBITRATOR_RATIO = 1_000;

    address public owner;
    IWorkerIssuance public immutable issuance;
    IWorkerOracle public immutable oracle;
    IAppRewardSink public appRewardSink;
    INoteRewardSink public noteRewardSink;
    address public chainMaintainerRecipient;

    uint64 public epoch = 1;
    uint64 public epochStart;
    uint256 public activity;

    mapping(address => bool) public reporters;
    mapping(address => bool) public registrationAgents;
    mapping(address => bool) public arbitrationSources;
    mapping(uint8 => address[]) private members;
    mapping(address => uint8) public memberKind; // 0=unregistered; kind+1 otherwise
    mapping(uint64 => mapping(uint8 => uint256)) public pool;
    mapping(uint8 => uint256) public categoryRollover;
    mapping(uint64 => mapping(uint8 => mapping(address => uint256))) public contributionWeight;
    mapping(uint64 => mapping(uint8 => uint256)) public totalContributionWeight;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(uint8 => uint256)) public claimedAmount;
    mapping(uint64 => mapping(address => bool)) public successfulArbitrator;
    mapping(uint64 => uint256) public successfulArbitratorCount;
    mapping(uint64 => mapping(bytes32 => mapping(address => bool))) public arbitrationOutcomeRecorded;
    mapping(uint64 => uint256) public arbitratorFallbackAmount;

    event ReporterUpdated(address indexed reporter, bool enabled);
    event RegistrationAgentUpdated(address indexed agent, bool enabled);
    event ArbitrationSourceUpdated(address indexed source, bool enabled);
    event MemberRegistered(address indexed member, uint8 indexed kind);
    event ActivityReported(address indexed reporter, uint256 amount);
    event ContributionRecorded(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 weight);
    event ArbitratorMarked(uint64 indexed epoch, bytes32 indexed outcomeId, address indexed arbitrator);
    event ArbitrationFallback(uint64 indexed epoch, uint256 amount);
    event EpochFinalized(uint64 indexed epoch, uint256 workerPool, uint256 dynamicRateBps, uint256 twapMul);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 amount);
    event CategoryRolledOver(uint64 indexed epoch, uint8 indexed kind, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "WorkerSplit: owner only");
        _;
    }

    modifier onlyReporter() {
        require(reporters[msg.sender] || msg.sender == owner, "WorkerSplit: reporter only");
        _;
    }

    constructor(address issuanceAddress, address oracleAddress) {
        require(issuanceAddress != address(0) && oracleAddress != address(0), "WorkerSplit: zero address");
        owner = msg.sender;
        issuance = IWorkerIssuance(issuanceAddress);
        oracle = IWorkerOracle(oracleAddress);
        epochStart = uint64(block.timestamp);
    }

    function setReporter(address who, bool enabled) external onlyOwner {
        require(who != address(0), "WorkerSplit: zero address");
        reporters[who] = enabled;
        emit ReporterUpdated(who, enabled);
    }

    function setRegistrationAgent(address who, bool enabled) external onlyOwner {
        require(who != address(0), "WorkerSplit: zero address");
        registrationAgents[who] = enabled;
        emit RegistrationAgentUpdated(who, enabled);
    }

    function setArbitrationSource(address who, bool enabled) external onlyOwner {
        require(who != address(0), "WorkerSplit: zero address");
        arbitrationSources[who] = enabled;
        emit ArbitrationSourceUpdated(who, enabled);
    }

    function setRewardSinks(address appSink, address noteSink, address chainMaintainer) external onlyOwner {
        require(appSink != address(0) && noteSink != address(0) && chainMaintainer != address(0), "WorkerSplit: zero address");
        appRewardSink = IAppRewardSink(appSink);
        noteRewardSink = INoteRewardSink(noteSink);
        chainMaintainerRecipient = chainMaintainer;
    }

    function registerWorker(address member, uint8 kind) external {
        require(msg.sender == owner || registrationAgents[msg.sender], "WorkerSplit: registration agent only");
        require(member != address(0) && kind <= ARBITRATOR, "WorkerSplit: invalid registration");
        require(memberKind[member] == 0, "WorkerSplit: already registered");
        memberKind[member] = kind + 1;
        members[kind].push(member);
        emit MemberRegistered(member, kind);
    }

    function recordActivity(uint256 amount) external onlyReporter {
        require(amount > 0, "WorkerSplit: zero activity");
        activity += amount;
        emit ActivityReported(msg.sender, amount);
    }

    /// @notice Per-epoch, class-specific service weight from an authorized measurement system.
    function recordContribution(uint64 contributionEpoch, uint8 kind, address member, uint256 weight) external onlyReporter {
        require(contributionEpoch == epoch && kind <= VERIFIER, "WorkerSplit: inactive epoch or kind");
        require(memberKind[member] == kind + 1 && weight > 0, "WorkerSplit: invalid contribution");
        contributionWeight[contributionEpoch][kind][member] += weight;
        totalContributionWeight[contributionEpoch][kind] += weight;
        emit ContributionRecorded(contributionEpoch, kind, member, weight);
    }

    /// @notice Record each final-case participant once. Escrow must pass a unique case/outcome ID.
    function markSuccessfulArbitrator(uint64 completionEpoch, bytes32 outcomeId, address arbitrator) external {
        require(arbitrationSources[msg.sender], "WorkerSplit: arbitration source only");
        require(completionEpoch == epoch && outcomeId != bytes32(0), "WorkerSplit: inactive epoch or empty outcome");
        require(memberKind[arbitrator] == ARBITRATOR + 1, "WorkerSplit: arbitrator not registered");
        require(!arbitrationOutcomeRecorded[completionEpoch][outcomeId][arbitrator], "WorkerSplit: outcome already recorded");
        arbitrationOutcomeRecorded[completionEpoch][outcomeId][arbitrator] = true;
        if (!successfulArbitrator[completionEpoch][arbitrator]) {
            successfulArbitrator[completionEpoch][arbitrator] = true;
            successfulArbitratorCount[completionEpoch]++;
        }
        emit ArbitratorMarked(completionEpoch, outcomeId, arbitrator);
    }

    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "WorkerSplit: epoch active");
        uint64 finalizedEpoch = epoch;
        uint256 base = (activity * BASE_FLOOR_BPS) / BPS;
        uint256 dynamicBps = oracle.getDynamicIssuanceRateBps();
        uint256 scaleFactor = (dynamicBps * WAD) / (2 * BASE_FLOOR_BPS);
        uint256 twapMul = oracle.getTwapMultiplier();
        uint256 scaledPool = (((base * scaleFactor) / WAD) * twapMul) / WAD;

        _allocateWeighted(finalizedEpoch, VALIDATOR, (scaledPool * VALIDATOR_RATIO) / BPS);
        _allocateWeighted(finalizedEpoch, VERIFIER, (scaledPool * VERIFIER_RATIO) / BPS);

        uint256 appAmount = (scaledPool * APP_RATIO) / BPS;
        uint256 noteAmount = (scaledPool * NOTE_RATIO) / BPS;
        require(address(appRewardSink) != address(0) && address(noteRewardSink) != address(0), "WorkerSplit: sinks unset");
        if (appAmount > 0) {
            issuance.mintWorkerReward(address(appRewardSink), appAmount);
            appRewardSink.notifyWorkerPool(finalizedEpoch, appAmount);
        }
        if (noteAmount > 0) {
            issuance.mintWorkerReward(address(noteRewardSink), noteAmount);
            noteRewardSink.notifyWorkerPool(finalizedEpoch, noteAmount);
        }

        uint256 arbitratorAmount = (scaledPool * ARBITRATOR_RATIO) / BPS;
        uint256 arbitratorCarry = categoryRollover[ARBITRATOR];
        categoryRollover[ARBITRATOR] = 0;
        arbitratorAmount += arbitratorCarry;
        if (successfulArbitratorCount[finalizedEpoch] > 0) {
            pool[finalizedEpoch][ARBITRATOR] = arbitratorAmount;
        } else if (arbitratorAmount > 0) {
            _applyArbitratorFallback(finalizedEpoch, arbitratorAmount);
        }

        activity = 0;
        epoch = finalizedEpoch + 1;
        epochStart = uint64(block.timestamp);
        emit EpochFinalized(finalizedEpoch, scaledPool, dynamicBps, twapMul);
    }

    function _allocateWeighted(uint64 finalizedEpoch, uint8 kind, uint256 freshAmount) internal {
        uint256 amount = freshAmount + categoryRollover[kind];
        categoryRollover[kind] = 0;
        if (amount == 0) return;
        if (totalContributionWeight[finalizedEpoch][kind] == 0) {
            categoryRollover[kind] = amount;
            emit CategoryRolledOver(finalizedEpoch, kind, amount);
        } else {
            pool[finalizedEpoch][kind] = amount;
        }
    }

    function _applyArbitratorFallback(uint64 finalizedEpoch, uint256 amount) internal {
        require(chainMaintainerRecipient != address(0) && address(appRewardSink) != address(0) && address(noteRewardSink) != address(0), "WorkerSplit: fallback sinks unset");
        uint256 chainShare = (amount * 4_000) / BPS;
        uint256 appShare = (amount * 3_000) / BPS;
        uint256 noteShare = amount - chainShare - appShare;
        if (chainShare > 0) issuance.mintWorkerReward(chainMaintainerRecipient, chainShare);
        if (appShare > 0) {
            issuance.mintWorkerReward(address(appRewardSink), appShare);
            appRewardSink.notifyWorkerPool(finalizedEpoch, appShare);
        }
        if (noteShare > 0) {
            issuance.mintWorkerReward(address(noteRewardSink), noteShare);
            noteRewardSink.notifyWorkerPool(finalizedEpoch, noteShare);
        }
        arbitratorFallbackAmount[finalizedEpoch] = amount;
        emit ArbitrationFallback(finalizedEpoch, amount);
    }

    /// @notice Claims remain open indefinitely. Allocated amounts are never recycled.
    function claim(uint64 claimEpoch, uint8 kind) external {
        require(claimEpoch < epoch && kind <= ARBITRATOR, "WorkerSplit: invalid epoch or kind");
        require(kind != APP && kind != NOTE, "WorkerSplit: use dedicated distributor");
        require(memberKind[msg.sender] == kind + 1, "WorkerSplit: wrong worker category");
        require(!claimed[claimEpoch][kind][msg.sender], "WorkerSplit: already claimed");
        uint256 amount;
        if (kind == ARBITRATOR) {
            uint256 count = successfulArbitratorCount[claimEpoch];
            require(successfulArbitrator[claimEpoch][msg.sender] && count > 0, "WorkerSplit: not successful arbitrator");
            amount = pool[claimEpoch][kind] / count;
        } else {
            uint256 total = totalContributionWeight[claimEpoch][kind];
            uint256 weight = contributionWeight[claimEpoch][kind][msg.sender];
            require(total > 0 && weight > 0 && pool[claimEpoch][kind] > 0, "WorkerSplit: no allocated contribution reward");
            amount = (pool[claimEpoch][kind] * weight) / total;
        }
        require(amount > 0, "WorkerSplit: zero amount");
        claimed[claimEpoch][kind][msg.sender] = true;
        claimedAmount[claimEpoch][kind] += amount;
        issuance.mintWorkerReward(msg.sender, amount);
        emit RewardClaimed(claimEpoch, kind, msg.sender, amount);
    }

    function participantCount(uint8 kind) external view returns (uint256) { return members[kind].length; }
    function getMembers(uint8 kind) external view returns (address[] memory) { return members[kind]; }
}
