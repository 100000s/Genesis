// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRewardToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Proof-of-use-gated AppTeam reward accounting. Deploy as the AppTeam
/// reward distributor and configure its address in WorkerSplit. Use attestations
/// and contribution reports must be supplied by separately authorized services.
contract AppTeamRewardDistributor {
    uint256 public constant BPS = 10_000;
    uint64 public constant EPOCH_DURATION = 30 days;

    uint8 public constant PHYSICAL_TOKEN = 0;
    uint8 public constant CELLULAR = 1;
    uint8 public constant LEGACY_HARDWARE = 2;
    uint8 public constant SATELLITE = 3;
    uint8 public constant SHORTWAVE_HF = 4;
    uint8 public constant GENESIS_MALL = 5;
    uint8 public constant SECOND_LIFE = 6;
    uint8 public constant DECENTRALAND = 7;
    uint8 public constant TECHNOLOGY_COUNT = 8;

    // Shares of the AppTeam pool: one third physical, one third digital, one third immersive.
    // Digital's 40/30/20/10 split corresponds to 4/3/2/1 percent of the overall WorkerSplit pool.
    uint16[8] private technologyBps = [uint16(3333), 1333, 1000, 667, 333, 1112, 1111, 1111];

    address public owner;
    IRewardToken public immutable token;
    address public workerSplit;
    uint64 public epoch = 1;
    uint64 public epochStart;
    uint256 public appPool;

    mapping(address => bool) public useVerifiers;
    mapping(address => bool) public contributionVerifiers;
    mapping(uint64 => mapping(uint8 => uint256)) public verifiedUseCount;
    mapping(bytes32 => bool) public operationUsed;
    mapping(uint64 => mapping(uint8 => uint256)) public contributionTotal;
    mapping(uint64 => mapping(uint8 => mapping(address => uint256))) public contributionWeight;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public contributorSeen;
    mapping(uint64 => mapping(uint8 => uint256)) public technologyPool;
    mapping(uint8 => uint256) public categoryRollover;
    mapping(uint64 => mapping(uint8 => uint256)) public claimedAmount;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(uint8 => bool)) public epochSettled;

    event UseVerifierUpdated(address indexed verifier, bool enabled);
    event ContributionVerifierUpdated(address indexed verifier, bool enabled);
    event WorkerSplitUpdated(address indexed workerSplit);
    event WorkerPoolReceived(uint256 amount);
    event UseRecorded(uint64 indexed epoch, uint8 indexed technology, bytes32 indexed operationId, bytes32 evidenceHash);
    event ContributionRecorded(uint64 indexed epoch, uint8 indexed technology, address indexed contributor, uint256 weight);
    event TechnologyEpochFunded(uint64 indexed epoch, uint8 indexed technology, uint256 amount);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed technology, address indexed contributor, uint256 amount);
    event TechnologyRollover(uint64 indexed epoch, uint8 indexed technology, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "AppRewards: owner only");
        _;
    }

    constructor(address tokenAddress, address workerSplitAddress) {
        require(tokenAddress != address(0) && workerSplitAddress != address(0), "AppRewards: zero address");
        owner = msg.sender;
        token = IRewardToken(tokenAddress);
        workerSplit = workerSplitAddress;
        epochStart = uint64(block.timestamp);
    }

    function setVerifier(address verifier, bool enabled, bool forUse) external onlyOwner {
        require(verifier != address(0), "AppRewards: zero verifier");
        if (forUse) useVerifiers[verifier] = enabled;
        else contributionVerifiers[verifier] = enabled;
        if (forUse) emit UseVerifierUpdated(verifier, enabled);
        else emit ContributionVerifierUpdated(verifier, enabled);
    }

    function setWorkerSplit(address workerSplitAddress) external onlyOwner {
        require(workerSplitAddress != address(0), "AppRewards: zero address");
        workerSplit = workerSplitAddress;
        emit WorkerSplitUpdated(workerSplitAddress);
    }

    /// @dev WorkerSplit mints actual GEN to this contract before notification.
    function notifyWorkerPool(uint256 amount) external {
        require(msg.sender == workerSplit, "AppRewards: worker split only");
        require(token.balanceOf(address(this)) >= appPool + amount, "AppRewards: pool not funded");
        appPool += amount;
        emit WorkerPoolReceived(amount);
    }

    /// @notice Receives the AppTeam share of the arbitrator fallback. Tokens are
    /// minted to this contract by WorkerSplit before this callback.
    function notifyArbitrationFallback(uint256 amount) external {
        require(msg.sender == workerSplit, "AppRewards: worker split only");
        require(token.balanceOf(address(this)) >= appPool + amount, "AppRewards: fallback not funded");
        appPool += amount;
        emit WorkerPoolReceived(amount);
    }

    /// @notice Record a user operation only after independent evidence verification.
    /// operationId must be globally unique; evidenceHash commits to the verifier's evidence.
    function recordProofOfUse(uint64 useEpoch, uint8 technology, bytes32 operationId, bytes32 evidenceHash) external {
        require(useVerifiers[msg.sender], "AppRewards: use verifier only");
        require(useEpoch == epoch && technology < TECHNOLOGY_COUNT, "AppRewards: invalid epoch or technology");
        require(operationId != bytes32(0) && evidenceHash != bytes32(0), "AppRewards: empty proof");
        require(!operationUsed[operationId], "AppRewards: duplicate operation");
        operationUsed[operationId] = true;
        verifiedUseCount[useEpoch][technology]++;
        emit UseRecorded(useEpoch, technology, operationId, evidenceHash);
    }

    /// @notice Contribution verification is a separate role and measurement from proof of use.
    function recordContribution(uint64 contributionEpoch, uint8 technology, address contributor, uint256 weight) external {
        require(contributionVerifiers[msg.sender], "AppRewards: contribution verifier only");
        require(contributionEpoch == epoch && technology < TECHNOLOGY_COUNT, "AppRewards: invalid epoch or technology");
        require(contributor != address(0) && weight > 0, "AppRewards: invalid contribution");
        if (!contributorSeen[contributionEpoch][technology][contributor]) {
            contributorSeen[contributionEpoch][technology][contributor] = true;
        }
        contributionWeight[contributionEpoch][technology][contributor] += weight;
        contributionTotal[contributionEpoch][technology] += weight;
        emit ContributionRecorded(contributionEpoch, technology, contributor, weight);
    }

    /// @notice Allocate this epoch's AppTeam funding only to technologies with
    /// verified use. Idle amounts remain attributed to their original technology.
    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "AppRewards: epoch active");
        uint64 finalizedEpoch = epoch;
        uint256 distributable = appPool;
        appPool = 0;
        uint256 assigned;
        for (uint8 technology; technology < TECHNOLOGY_COUNT; technology++) {
            uint256 allocation = (distributable * technologyBps[technology]) / BPS;
            if (technology == TECHNOLOGY_COUNT - 1) allocation = distributable - assigned;
            else assigned += allocation;
            uint256 available = allocation + categoryRollover[technology];
            if (verifiedUseCount[finalizedEpoch][technology] > 0) {
                technologyPool[finalizedEpoch][technology] = available;
                categoryRollover[technology] = 0;
                emit TechnologyEpochFunded(finalizedEpoch, technology, available);
            } else {
                categoryRollover[technology] = available;
                emit TechnologyRollover(finalizedEpoch, technology, available);
            }
        }
        epoch = finalizedEpoch + 1;
        epochStart = uint64(block.timestamp);
    }

    function claim(uint64 claimEpoch, uint8 technology) external {
        require(claimEpoch < epoch && technology < TECHNOLOGY_COUNT, "AppRewards: invalid epoch or technology");
        require(!claimed[claimEpoch][technology][msg.sender], "AppRewards: already claimed");
        uint256 totalWeight = contributionTotal[claimEpoch][technology];
        uint256 weight = contributionWeight[claimEpoch][technology][msg.sender];
        require(totalWeight > 0 && weight > 0, "AppRewards: no verified contribution");
        uint256 reward = (technologyPool[claimEpoch][technology] * weight) / totalWeight;
        require(reward > 0, "AppRewards: zero reward");
        require(token.balanceOf(address(this)) >= reward, "AppRewards: insolvent reward pool");
        claimed[claimEpoch][technology][msg.sender] = true;
        claimedAmount[claimEpoch][technology] += reward;
        require(token.transfer(msg.sender, reward), "AppRewards: transfer failed");
        emit RewardClaimed(claimEpoch, technology, msg.sender, reward);
    }

    /// @notice Roll unclaimed/rounding remainder into the same technology after
    /// the following epoch closes; it cannot leak across technology categories.
    function settleUnclaimed(uint64 settledEpoch, uint8 technology) external {
        require(settledEpoch + 1 < epoch && technology < TECHNOLOGY_COUNT, "AppRewards: not settleable");
        require(!epochSettled[settledEpoch][technology], "AppRewards: already settled");
        epochSettled[settledEpoch][technology] = true;
        uint256 remainder = technologyPool[settledEpoch][technology] - claimedAmount[settledEpoch][technology];
        categoryRollover[technology] += remainder;
        if (remainder > 0) emit TechnologyRollover(settledEpoch, technology, remainder);
    }

    function technologyAllocationBps(uint8 technology) external view returns (uint16) {
        require(technology < TECHNOLOGY_COUNT, "AppRewards: invalid technology");
        return technologyBps[technology];
    }
}
