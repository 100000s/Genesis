// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorkerIssuance {
    function mintWorkerReward(address, uint256) external;
}

interface IWorkerOracle {
    function getDynamicIssuanceRateBps() external view returns (uint256);
    function getTwapMultiplier() external view returns (uint256);
}

interface IAppTeamDAO {
    function notifyWorkerPool(uint256 amount) external;
    function notifyArbitrationFallback(uint256 amount) external;
}

/// @notice Epoch-based worker allocation with contribution-weighted rewards and
/// category-specific rollover. Contribution and arbitration reports must come
/// from explicitly authorized, independent reporting integrations.
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
    IAppTeamDAO public appTeamDAO;
    address public chainMaintainerRecipient;
    address public noteTeamRecipient;

    uint64 public epoch = 1;
    uint64 public epochStart;
    uint256 public activity;

    mapping(address => bool) public reporters;
    mapping(address => bool) public registrationAgents;
    mapping(address => bool) public arbitrationSources;
    mapping(uint8 => address[]) private members;
    mapping(address => uint8) public memberKind; // 0=unregistered; category + 1 otherwise
    mapping(uint64 => mapping(uint8 => uint256)) public pool;
    mapping(uint64 => mapping(uint8 => uint256)) public categoryRollover;
    mapping(uint64 => mapping(uint8 => mapping(address => uint256))) public contributionWeight;
    mapping(uint64 => mapping(uint8 => uint256)) public totalContributionWeight;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(uint8 => uint256)) public claimedAmount;
    mapping(uint64 => mapping(address => bool)) public successfulArbitrator;
    mapping(uint64 => uint256) public successfulArbitratorCount;
    mapping(uint64 => bool) public epochSettled;

    event ActivityReported(address indexed reporter, uint256 amount);
    event EpochFinalized(uint64 indexed epoch, uint256 workerPool, uint256 dynamicRateBps, uint256 twapMul);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 amount);
    event ReporterUpdated(address indexed reporter, bool enabled);
    event RegistrationAgentUpdated(address indexed agent, bool enabled);
    event ArbitrationSourceUpdated(address indexed source, bool enabled);
    event MemberRegistered(address indexed member, uint8 indexed kind);
    event ContributionRecorded(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 weight);
    event ArbitratorMarked(uint64 indexed epoch, address indexed arbitrator);
    event ArbitrationFallback(uint64 indexed epoch, uint256 amount);
    event CategoryRolledOver(uint64 indexed epoch, uint8 indexed kind, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "WorkerSplit: owner only");
        _;
    }

    modifier onlyReporter() {
        require(reporters[msg.sender] || msg.sender == owner, "WorkerSplit: reporter");
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

    function setAppTeamDAO(address daoAddress) external onlyOwner {
        require(daoAddress != address(0), "WorkerSplit: zero address");
        appTeamDAO = IAppTeamDAO(daoAddress);
    }

    function setFallbackRecipients(address chainMaintainers, address noteTeam) external onlyOwner {
        require(chainMaintainers != address(0) && noteTeam != address(0), "WorkerSplit: zero address");
        chainMaintainerRecipient = chainMaintainers;
        noteTeamRecipient = noteTeam;
    }

    /// @dev Registration is gated by a trusted registry/agent, not self-selected by workers.
    function registerWorker(address member, uint8 kind) external {
        require(msg.sender == owner || registrationAgents[msg.sender], "WorkerSplit: registration agent only");
        require(member != address(0) && kind <= ARBITRATOR, "WorkerSplit: invalid registration");
        require(memberKind[member] == 0, "WorkerSplit: already registered");
        memberKind[member] = kind + 1;
        members[kind].push(member);
        emit MemberRegistered(member, kind);
    }

    function recordActivity(uint256 amount) external onlyReporter {
        activity += amount;
        emit ActivityReported(msg.sender, amount);
    }

    /// @notice Record independently verified contribution in the active epoch.
    function recordContribution(uint64 contributionEpoch, uint8 kind, address member, uint256 weight) external onlyReporter {
        require(contributionEpoch == epoch, "WorkerSplit: inactive epoch");
        require(kind <= ARBITRATOR && memberKind[member] == kind + 1, "WorkerSplit: wrong worker category");
        require(weight > 0, "WorkerSplit: zero contribution");
        contributionWeight[contributionEpoch][kind][member] += weight;
        totalContributionWeight[contributionEpoch][kind] += weight;
        emit ContributionRecorded(contributionEpoch, kind, member, weight);
    }

    /// @notice Called only by the configured escrow/arbitration integration.
    /// Completion is credited to the epoch in which the outcome becomes final.
    function markSuccessfulArbitrator(uint64 completionEpoch, address arbitrator) external {
        require(arbitrationSources[msg.sender], "WorkerSplit: arbitration source only");
        require(completionEpoch == epoch && arbitrator != address(0), "WorkerSplit: inactive epoch");
        require(!successfulArbitrator[completionEpoch][arbitrator], "WorkerSplit: already recorded");
        successfulArbitrator[completionEpoch][arbitrator] = true;
        if (memberKind[arbitrator] == ARBITRATOR + 1) successfulArbitratorCount[completionEpoch]++;
        emit ArbitratorMarked(completionEpoch, arbitrator);
    }

    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "WorkerSplit: epoch active");
        uint64 finalizedEpoch = epoch;

        uint256 base = (activity * BASE_FLOOR_BPS) / BPS;
        uint256 dynamicBps = oracle.getDynamicIssuanceRateBps();
        uint256 scaleFactor = (dynamicBps * WAD) / (2 * BASE_FLOOR_BPS);
        uint256 scaledPool = ((base * scaleFactor) / WAD * oracle.getTwapMultiplier()) / WAD;

        pool[finalizedEpoch][VALIDATOR] = (scaledPool * VALIDATOR_RATIO) / BPS + categoryRollover[finalizedEpoch][VALIDATOR];
        pool[finalizedEpoch][VERIFIER] = (scaledPool * VERIFIER_RATIO) / BPS + categoryRollover[finalizedEpoch][VERIFIER];
        pool[finalizedEpoch][APP] = (scaledPool * APP_RATIO) / BPS;
        pool[finalizedEpoch][NOTE] = (scaledPool * NOTE_RATIO) / BPS + categoryRollover[finalizedEpoch][NOTE];
        pool[finalizedEpoch][ARBITRATOR] = (scaledPool * ARBITRATOR_RATIO) / BPS + categoryRollover[finalizedEpoch][ARBITRATOR];

        categoryRollover[finalizedEpoch][VALIDATOR] = 0;
        categoryRollover[finalizedEpoch][VERIFIER] = 0;
        categoryRollover[finalizedEpoch][NOTE] = 0;
        categoryRollover[finalizedEpoch][ARBITRATOR] = 0;

        uint256 appAllocation = pool[finalizedEpoch][APP];
        if (appAllocation > 0) {
            require(address(appTeamDAO) != address(0), "WorkerSplit: app DAO unset");
            // Mint actual tokens before notifying the DAO, so its accounting is backed.
            issuance.mintWorkerReward(address(appTeamDAO), appAllocation);
            appTeamDAO.notifyWorkerPool(appAllocation);
        }

        activity = 0;
        epoch = finalizedEpoch + 1;
        epochStart = uint64(block.timestamp);
        emit EpochFinalized(finalizedEpoch, scaledPool, dynamicBps, oracle.getTwapMultiplier());
    }

    function claim(uint64 claimEpoch, uint8 kind) external {
        require(claimEpoch < epoch && kind <= ARBITRATOR, "WorkerSplit: invalid epoch or kind");
        require(memberKind[msg.sender] == kind + 1, "WorkerSplit: wrong worker category");
        require(!claimed[claimEpoch][kind][msg.sender], "WorkerSplit: already claimed");

        uint256 amount;
        if (kind == APP) revert("WorkerSplit: APP workers claim via app distributor");
        if (kind == ARBITRATOR) {
            uint256 count = successfulArbitratorCount[claimEpoch];
            require(successfulArbitrator[claimEpoch][msg.sender] && count > 0, "WorkerSplit: not successful arbitrator");
            amount = pool[claimEpoch][kind] / count;
        } else {
            uint256 totalWeight = totalContributionWeight[claimEpoch][kind];
            uint256 memberWeight = contributionWeight[claimEpoch][kind][msg.sender];
            require(totalWeight > 0 && memberWeight > 0, "WorkerSplit: no verified contribution");
            amount = (pool[claimEpoch][kind] * memberWeight) / totalWeight;
        }
        require(amount > 0, "WorkerSplit: zero amount");
        claimed[claimEpoch][kind][msg.sender] = true;
        claimedAmount[claimEpoch][kind] += amount;
        issuance.mintWorkerReward(msg.sender, amount);
        emit RewardClaimed(claimEpoch, kind, msg.sender, amount);
    }

    /// @notice Close a completed epoch after the following epoch has ended. Unclaimed
    /// funds roll into the same category, except an empty arbitrator pool follows 40/30/30.
    function settleUnclaimed(uint64 settledEpoch, uint8 kind) external {
        require(settledEpoch + 1 < epoch && kind <= ARBITRATOR && kind != APP, "WorkerSplit: not settleable");
        require(!epochSettled[settledEpoch], "WorkerSplit: already settled");
        epochSettled[settledEpoch] = true;
        uint256 unclaimed = pool[settledEpoch][kind] - claimedAmount[settledEpoch][kind];
        if (unclaimed == 0) return;

        if (kind == ARBITRATOR && successfulArbitratorCount[settledEpoch] == 0) {
            require(chainMaintainerRecipient != address(0) && noteTeamRecipient != address(0), "WorkerSplit: fallback unset");
            require(address(appTeamDAO) != address(0), "WorkerSplit: app DAO unset");
            uint256 chainShare = (unclaimed * 4_000) / BPS;
            uint256 appShare = (unclaimed * 3_000) / BPS;
            uint256 noteShare = unclaimed - chainShare - appShare;
            issuance.mintWorkerReward(chainMaintainerRecipient, chainShare);
            issuance.mintWorkerReward(address(appTeamDAO), appShare);
            appTeamDAO.notifyWorkerPool(appShare);
            issuance.mintWorkerReward(noteTeamRecipient, noteShare);
            emit ArbitrationFallback(settledEpoch, unclaimed);
        } else {
            categoryRollover[epoch][kind] += unclaimed;
            emit CategoryRolledOver(settledEpoch, kind, unclaimed);
        }
    }

    function participantCount(uint8 kind) external view returns (uint256) {
        return members[kind].length;
    }

    function getMembers(uint8 kind) external view returns (address[] memory) {
        return members[kind];
    }
}
