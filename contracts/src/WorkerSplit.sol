// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorkerIssuance {
    function mintWorkerReward(address recipient, uint256 amount) external;
}

interface IWorkerOracle {
    function getDynamicIssuanceRateBps() external view returns (uint256);
    function getTwapMultiplier() external view returns (uint256);
}

interface IWorkerEvidenceVerifier {
    function verifyContribution(address worker, uint8 kind, uint64 epoch, uint256 weight, bytes32 evidenceHash)
        external view returns (bool);
}

interface IAppRewardSink {
    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external;
}

interface INoteRewardSink {
    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external;
}

/// @notice README-aligned monthly reward authority. It freezes field-work weights
/// and top-level allocation at epoch close. Specialist sinks exclusively handle
/// App/Note suballocations; claims never expire and are never recycled.
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
    IWorkerEvidenceVerifier public evidenceVerifier;
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
    mapping(address => uint8) public memberKind;
    mapping(uint64 => mapping(uint8 => uint256)) public pool;
    mapping(uint8 => uint256) public categoryRollover;
    mapping(uint64 => mapping(uint8 => mapping(address => uint256))) public contributionWeight;
    mapping(uint64 => mapping(uint8 => uint256)) public totalContributionWeight;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(uint8 => uint256)) public claimedAmount;
    mapping(uint64 => mapping(address => bool)) public successfulArbitrator;
    mapping(uint64 => mapping(bytes32 => mapping(address => bool))) public arbitrationOutcomeRecorded;
    mapping(uint64 => uint256) public successfulArbitratorCount;
    mapping(uint64 => bool) public epochFinalized;
    mapping(uint64 => uint256) public arbitratorFallbackAmount;

    event ReporterUpdated(address indexed reporter, bool enabled);
    event RegistrationAgentUpdated(address indexed agent, bool enabled);
    event ArbitrationSourceUpdated(address indexed source, bool enabled);
    event EvidenceVerifierUpdated(address indexed verifier);
    event RewardSinksUpdated(address indexed appSink, address indexed noteSink, address chainMaintainer);
    event MemberRegistered(address indexed member, uint8 indexed kind);
    event ActivityReported(address indexed reporter, uint256 amount);
    event ContributionRecorded(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 weight, bytes32 evidenceHash);
    event ArbitratorMarked(uint64 indexed epoch, bytes32 indexed outcomeId, address indexed arbitrator);
    event ArbitrationFallback(uint64 indexed epoch, uint256 amount);
    event EpochFinalized(uint64 indexed epoch, uint256 workerPool, uint256 dynamicRateBps, uint256 twapMul);
    event CategoryRolledOver(uint64 indexed epoch, uint8 indexed kind, uint256 amount);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "WorkerSplit: owner only"); _; }
    modifier onlyReporter() { require(reporters[msg.sender] || msg.sender == owner, "WorkerSplit: reporter only"); _; }

    constructor(address issuanceAddress, address oracleAddress) {
        require(issuanceAddress != address(0) && oracleAddress != address(0), "WorkerSplit: zero address");
        owner = msg.sender;
        issuance = IWorkerIssuance(issuanceAddress);
        oracle = IWorkerOracle(oracleAddress);
        epochStart = uint64(block.timestamp);
    }

    function setReporter(address who, bool enabled) external onlyOwner {
        require(who != address(0), "WorkerSplit: zero reporter");
        reporters[who] = enabled;
        emit ReporterUpdated(who, enabled);
    }
    function setRegistrationAgent(address who, bool enabled) external onlyOwner {
        require(who != address(0), "WorkerSplit: zero agent");
        registrationAgents[who] = enabled;
        emit RegistrationAgentUpdated(who, enabled);
    }
    function setArbitrationSource(address who, bool enabled) external onlyOwner {
        require(who != address(0), "WorkerSplit: zero source");
        arbitrationSources[who] = enabled;
        emit ArbitrationSourceUpdated(who, enabled);
    }
    function setEvidenceVerifier(address verifier) external onlyOwner {
        require(verifier != address(0), "WorkerSplit: zero verifier");
        evidenceVerifier = IWorkerEvidenceVerifier(verifier);
        emit EvidenceVerifierUpdated(verifier);
    }
    function setRewardSinks(address appSink, address noteSink, address chainMaintainer) external onlyOwner {
        require(appSink != address(0) && noteSink != address(0) && chainMaintainer != address(0), "WorkerSplit: zero address");
        appRewardSink = IAppRewardSink(appSink);
        noteRewardSink = INoteRewardSink(noteSink);
        chainMaintainerRecipient = chainMaintainer;
        emit RewardSinksUpdated(appSink, noteSink, chainMaintainer);
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

    /// @notice An authorized measurement integration validates utilization evidence
    /// (service telemetry, successful verification, or audited field records) and
    /// returns true. The same integration can be automated against registries/oracles.
    function recordContribution(uint64 contributionEpoch, uint8 kind, address member, uint256 weight, bytes32 evidenceHash) external onlyReporter {
        require(contributionEpoch == epoch && kind <= VERIFIER, "WorkerSplit: inactive epoch or kind");
        require(memberKind[member] == kind + 1 && weight > 0 && evidenceHash != bytes32(0), "WorkerSplit: invalid contribution");
        require(address(evidenceVerifier) != address(0), "WorkerSplit: evidence verifier unset");
        require(evidenceVerifier.verifyContribution(member, kind, contributionEpoch, weight, evidenceHash), "WorkerSplit: evidence rejected");
        contributionWeight[contributionEpoch][kind][member] += weight;
        totalContributionWeight[contributionEpoch][kind] += weight;
        emit ContributionRecorded(contributionEpoch, kind, member, weight, evidenceHash);
    }

    /// @notice Outcomes are assigned to the active epoch at settlement time. Escrow
    /// calls this after resolution, so a late case naturally enters the succeeding month.
    function markSuccessfulArbitrator(uint64 completionEpoch, bytes32 outcomeId, address arbitrator) external {
        require(arbitrationSources[msg.sender], "WorkerSplit: arbitration source only");
        require(completionEpoch == epoch && outcomeId != bytes32(0), "WorkerSplit: epoch closed or empty outcome");
        require(arbitrator != address(0) && memberKind[arbitrator] == ARBITRATOR + 1, "WorkerSplit: arbitrator not registered");
        require(!epochFinalized[completionEpoch] && !arbitrationOutcomeRecorded[completionEpoch][outcomeId][arbitrator], "WorkerSplit: duplicate or finalized");
        arbitrationOutcomeRecorded[completionEpoch][outcomeId][arbitrator] = true;
        if (!successfulArbitrator[completionEpoch][arbitrator]) {
            successfulArbitrator[completionEpoch][arbitrator] = true;
            successfulArbitratorCount[completionEpoch]++;
        }
        emit ArbitratorMarked(completionEpoch, outcomeId, arbitrator);
    }

    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "WorkerSplit: epoch active");
        uint64 closed = epoch;
        epochFinalized[closed] = true;
        uint256 base = (activity * BASE_FLOOR_BPS) / BPS;
        uint256 dynamicBps = oracle.getDynamicIssuanceRateBps();
        uint256 scaleFactor = (dynamicBps * WAD) / (2 * BASE_FLOOR_BPS);
        uint256 twapMul = oracle.getTwapMultiplier();
        uint256 scaledPool = (((base * scaleFactor) / WAD) * twapMul) / WAD;
        _allocateWeighted(closed, VALIDATOR, (scaledPool * VALIDATOR_RATIO) / BPS);
        _allocateWeighted(closed, VERIFIER, (scaledPool * VERIFIER_RATIO) / BPS);
        require(address(appRewardSink) != address(0) && address(noteRewardSink) != address(0), "WorkerSplit: reward sinks unset");
        uint256 appAmount = (scaledPool * APP_RATIO) / BPS;
        uint256 noteAmount = (scaledPool * NOTE_RATIO) / BPS;
        if (appAmount > 0) {
            issuance.mintWorkerReward(address(appRewardSink), appAmount);
            appRewardSink.notifyWorkerPool(closed, appAmount);
        }
        if (noteAmount > 0) {
            issuance.mintWorkerReward(address(noteRewardSink), noteAmount);
            noteRewardSink.notifyWorkerPool(closed, noteAmount);
        }
        uint256 arbitratorAmount = (scaledPool * ARBITRATOR_RATIO) / BPS;
        if (successfulArbitratorCount[closed] > 0) pool[closed][ARBITRATOR] = arbitratorAmount;
        else if (arbitratorAmount > 0) _applyArbitratorFallback(closed, arbitratorAmount);
        activity = 0;
        epoch = closed + 1;
        epochStart = uint64(block.timestamp);
        emit EpochFinalized(closed, scaledPool, dynamicBps, twapMul);
    }

    function _allocateWeighted(uint64 closed, uint8 kind, uint256 freshAmount) internal {
        uint256 amount = freshAmount + categoryRollover[kind];
        categoryRollover[kind] = 0;
        if (amount == 0) return;
        if (totalContributionWeight[closed][kind] == 0) {
            categoryRollover[kind] = amount;
            emit CategoryRolledOver(closed, kind, amount);
        } else pool[closed][kind] = amount;
    }

    function _applyArbitratorFallback(uint64 closed, uint256 amount) internal {
        require(chainMaintainerRecipient != address(0), "WorkerSplit: fallback recipient unset");
        uint256 chainShare = (amount * 4_000) / BPS;
        uint256 appShare = (amount * 3_000) / BPS;
        uint256 noteShare = amount - chainShare - appShare;
        if (chainShare > 0) issuance.mintWorkerReward(chainMaintainerRecipient, chainShare);
        if (appShare > 0) {
            issuance.mintWorkerReward(address(appRewardSink), appShare);
            appRewardSink.notifyWorkerPool(closed, appShare);
        }
        if (noteShare > 0) {
            issuance.mintWorkerReward(address(noteRewardSink), noteShare);
            noteRewardSink.notifyWorkerPool(closed, noteShare);
        }
        arbitratorFallbackAmount[closed] = amount;
        emit ArbitrationFallback(closed, amount);
    }

    function claim(uint64 claimEpoch, uint8 kind) external {
        require(epochFinalized[claimEpoch] && kind <= ARBITRATOR, "WorkerSplit: invalid or open epoch");
        require(kind != APP && kind != NOTE, "WorkerSplit: use dedicated distributor");
        require(memberKind[msg.sender] == kind + 1, "WorkerSplit: wrong worker category");
        require(!claimed[claimEpoch][kind][msg.sender], "WorkerSplit: already claimed");
        uint256 amount;
        if (kind == ARBITRATOR) {
            uint256 count = successfulArbitratorCount[claimEpoch];
            require(successfulArbitrator[claimEpoch][msg.sender] && count > 0, "WorkerSplit: not eligible arbitrator");
            amount = pool[claimEpoch][kind] / count;
        } else {
            uint256 total = totalContributionWeight[claimEpoch][kind];
            uint256 weight = contributionWeight[claimEpoch][kind][msg.sender];
            require(total > 0 && weight > 0 && pool[claimEpoch][kind] > 0, "WorkerSplit: no allocated contribution reward");
            amount = (pool[claimEpoch][kind] * weight) / total;
        }
        require(amount > 0, "WorkerSplit: zero reward");
        claimed[claimEpoch][kind][msg.sender] = true;
        claimedAmount[claimEpoch][kind] += amount;
        issuance.mintWorkerReward(msg.sender, amount);
        emit RewardClaimed(claimEpoch, kind, msg.sender, amount);
    }

    function participantCount(uint8 kind) external view returns (uint256) { return members[kind].length; }
    function getMembers(uint8 kind) external view returns (address[] memory) { return members[kind]; }
}
