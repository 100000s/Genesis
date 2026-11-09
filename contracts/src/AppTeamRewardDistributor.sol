// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRewardToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ISharedRewardEpoch {
    function epoch() external view returns (uint64);
}

/// @notice App technology rewards funded by explicit WorkerSplit epoch. A verified
/// user operation gates release; distinct verified contribution weights allocate it.
contract AppTeamRewardDistributor {
    uint256 public constant BPS = 10_000;
    uint8 public constant PHYSICAL_TOKEN = 0;
    uint8 public constant CELLULAR = 1;
    uint8 public constant LEGACY_HARDWARE = 2;
    uint8 public constant SATELLITE = 3;
    uint8 public constant SHORTWAVE_HF = 4;
    uint8 public constant GENESIS_MALL = 5;
    uint8 public constant SECOND_LIFE = 6;
    uint8 public constant DECENTRALAND = 7;
    uint8 public constant TECHNOLOGY_COUNT = 8;

    // Shares of the 30% App allocation: physical 1/3, digital 1/3, immersive 1/3.
    // Digital subcategories are 4/3/2/1 percent of the overall WorkerSplit pool.
    uint16[8] private technologyBps = [uint16(3333), 1333, 1000, 667, 333, 1112, 1111, 1111];

    address public owner;
    IRewardToken public immutable token;
    ISharedRewardEpoch public workerSplit;
    mapping(address => bool) public useVerifiers;
    mapping(address => bool) public contributionVerifiers;
    mapping(uint64 => uint256) public fundingByEpoch;
    mapping(uint64 => bool) public epochFinalized;
    mapping(uint64 => mapping(uint8 => uint256)) public verifiedUseCount;
    mapping(bytes32 => bool) public operationUsed;
    mapping(uint64 => mapping(uint8 => uint256)) public contributionTotal;
    mapping(uint64 => mapping(uint8 => mapping(address => uint256))) public contributionWeight;
    mapping(uint64 => mapping(uint8 => uint256)) public technologyPool;
    mapping(uint8 => uint256) public categoryRollover;
    mapping(uint64 => mapping(uint8 => uint256)) public claimedAmount;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;

    event VerifierUpdated(address indexed verifier, bool enabled, bool forUse);
    event FundingRecorded(uint64 indexed epoch, uint256 amount);
    event UseRecorded(uint64 indexed epoch, uint8 indexed technology, bytes32 indexed operationId, bytes32 evidenceHash);
    event ContributionRecorded(uint64 indexed epoch, uint8 indexed technology, address indexed contributor, uint256 weight, bytes32 evidenceHash);
    event TechnologyEpochFunded(uint64 indexed epoch, uint8 indexed technology, uint256 amount);
    event TechnologyRollover(uint64 indexed epoch, uint8 indexed technology, uint256 amount);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed technology, address indexed contributor, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "AppRewards: owner only"); _; }

    constructor(address tokenAddress, address workerSplitAddress) {
        require(tokenAddress != address(0) && workerSplitAddress != address(0), "AppRewards: zero address");
        owner = msg.sender;
        token = IRewardToken(tokenAddress);
        workerSplit = ISharedRewardEpoch(workerSplitAddress);
    }

    function setVerifier(address verifier, bool enabled, bool forUse) external onlyOwner {
        require(verifier != address(0), "AppRewards: zero verifier");
        if (forUse) useVerifiers[verifier] = enabled;
        else contributionVerifiers[verifier] = enabled;
        emit VerifierUpdated(verifier, enabled, forUse);
    }

    /// @dev WorkerSplit mints GEN here before calling this function.
    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external {
        require(msg.sender == address(workerSplit), "AppRewards: worker split only");
        require(fundingEpoch > 0 && amount > 0 && !epochFinalized[fundingEpoch], "AppRewards: invalid funding");
        require(token.balanceOf(address(this)) >= _accountedBalance() + amount, "AppRewards: pool not backed");
        fundingByEpoch[fundingEpoch] += amount;
        emit FundingRecorded(fundingEpoch, amount);
    }

    /// @notice Verifiers must validate a user-originated operation against the
    /// integration's documented evidence policy before submitting its hash.
    function recordProofOfUse(uint64 useEpoch, uint8 technology, bytes32 operationId, bytes32 evidenceHash) external {
        require(useVerifiers[msg.sender], "AppRewards: use verifier only");
        require(useEpoch == workerSplit.epoch() && technology < TECHNOLOGY_COUNT, "AppRewards: invalid epoch or technology");
        require(operationId != bytes32(0) && evidenceHash != bytes32(0) && !operationUsed[operationId], "AppRewards: invalid or duplicate operation");
        operationUsed[operationId] = true;
        verifiedUseCount[useEpoch][technology]++;
        emit UseRecorded(useEpoch, technology, operationId, evidenceHash);
    }

    /// @notice Contribution weights are independently reported and evidence-hashed;
    /// governance voting credits are not consulted.
    function recordContribution(uint64 contributionEpoch, uint8 technology, address contributor, uint256 weight, bytes32 evidenceHash) external {
        require(contributionVerifiers[msg.sender], "AppRewards: contribution verifier only");
        require(contributionEpoch == workerSplit.epoch() && technology < TECHNOLOGY_COUNT, "AppRewards: invalid epoch or technology");
        require(contributor != address(0) && weight > 0 && evidenceHash != bytes32(0), "AppRewards: invalid contribution");
        contributionWeight[contributionEpoch][technology][contributor] += weight;
        contributionTotal[contributionEpoch][technology] += weight;
        emit ContributionRecorded(contributionEpoch, technology, contributor, weight, evidenceHash);
    }

    /// @notice Finalize only after WorkerSplit has closed and funded this exact epoch.
    function finalizeEpoch(uint64 finalizedEpoch) external {
        require(finalizedEpoch > 0 && finalizedEpoch < workerSplit.epoch(), "AppRewards: epoch still active");
        require(!epochFinalized[finalizedEpoch], "AppRewards: already finalized");
        epochFinalized[finalizedEpoch] = true;
        uint256 distributable = fundingByEpoch[finalizedEpoch];
        uint256 assigned;
        for (uint8 technology; technology < TECHNOLOGY_COUNT; technology++) {
            uint256 allocation = technology == TECHNOLOGY_COUNT - 1
                ? distributable - assigned
                : (distributable * technologyBps[technology]) / BPS;
            if (technology != TECHNOLOGY_COUNT - 1) assigned += allocation;
            uint256 amount = allocation + categoryRollover[technology];
            if (verifiedUseCount[finalizedEpoch][technology] > 0 && contributionTotal[finalizedEpoch][technology] > 0) {
                technologyPool[finalizedEpoch][technology] = amount;
                categoryRollover[technology] = 0;
                emit TechnologyEpochFunded(finalizedEpoch, technology, amount);
            } else {
                categoryRollover[technology] = amount;
                emit TechnologyRollover(finalizedEpoch, technology, amount);
            }
        }
    }

    /// @notice Allocated rewards remain claimable indefinitely; no settlement can
    /// move an already-earned liability into another epoch.
    function claim(uint64 claimEpoch, uint8 technology) external {
        require(epochFinalized[claimEpoch] && technology < TECHNOLOGY_COUNT, "AppRewards: unfinalized epoch or invalid technology");
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

    function _accountedBalance() internal view returns (uint256 total) {
        for (uint64 e = 1; e <= workerSplit.epoch(); e++) {
            if (!epochFinalized[e]) {
                total += fundingByEpoch[e];
                continue;
            }
            for (uint8 t; t < TECHNOLOGY_COUNT; t++) {
                total += technologyPool[e][t] - claimedAmount[e][t];
            }
        }
        for (uint8 t; t < TECHNOLOGY_COUNT; t++) total += categoryRollover[t];
    }

    function technologyAllocationBps(uint8 technology) external view returns (uint16) {
        require(technology < TECHNOLOGY_COUNT, "AppRewards: invalid technology");
        return technologyBps[technology];
    }
}
