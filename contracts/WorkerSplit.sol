// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IChainlinkOracle {
    function latestAnswer() external view returns (int256);
}

interface IGenesisIssuance {
    function mintWorkerReward(address recipient, uint256 amount) external;
}

interface IZKVerifier {
    function verifyProof(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool);
}

contract WorkerSplit is Ownable, ReentrancyGuard {
    IGenesisIssuance public immutable genesisIssuance;
    IZKVerifier public immutable zkVerifier;
    IChainlinkOracle public goldOracle; // XAU/USD Price Feed (8 decimals)

    address public noteMaintenanceReserve;

    // --- MONETARY POLICY COEFFICIENTS ---
    uint256 public constant WORKER_SPLIT_BPS = 50; // 0.5% of total economic base
    uint256 public constant INITIAL_BOOTSTRAP_CAP = 1000 * 1e18; // Default max claim per citizen when <= 100 claimants

    // --- EPOCH TRACKING ---
    uint256 public currentEpoch = 1;
    uint256 public epochStartTime;
    uint256 public constant EPOCH_DURATION = 30 days;

    // --- MONTHLY ECONOMIC BASE METRICS ---
    uint256 public currentEpochDigitalVolume;    // 1. Digital GenToken Volume
    uint256 public currentEpochCirculatingNotes; // 2. Circulating Gen Notes
    uint256 public currentEpochFiatEscrow;       // 3a. Locked Fiat Escrow (to be valued in Gold)
    uint256 public currentEpochTokenEscrow;      // 3b. Locked Genesis Tokens in Escrow

    // --- CIVIC DISTRIBUTION TRACKING ---
    uint256 public prevEpochTotalCitizenClaims;
    uint256 public prevEpochUniqueCitizenClaimants;
    uint256 public currentEpochCitizenClaims;
    uint256 public currentEpochUniqueClaimantCount;

    mapping(address => bool) public metricReporters;
    mapping(bytes32 => bool) public nullifierSpent;
    mapping(uint256 => mapping(address => bool)) public epochClaimedByAccount;

    struct EpochPool {
        bool finalized;
        uint256 totalWorkerRewardPool;
        uint256 validatorShare;       // 40%
        uint256 verifierShare;        // 30%
        uint256 noteHwBountyShare;    // 10%
        uint256 notePresenceShare;    // 8%
        uint256 noteReserveShare;     // 2%
        uint256 arbitratorShare;      // 10%
        uint256 maxPerCapitaCitizenClaim; // Enforced limit per account for the epoch
    }

    mapping(uint256 => EpochPool) public epochPools;

    event ActivityReported(
        address indexed reporter, 
        uint256 digitalVol, 
        uint256 notes, 
        uint256 fiatEscrow, 
        uint256 tokenEscrow
    );
    event EpochFinalized(uint256 indexed epochId, uint256 workerPool, uint256 citizenPerCapitaCap);
    event AnonymousWorkerRewardClaimed(bytes32 indexed nullifier, address indexed recipient, uint256 amount);
    event CitizenRewardClaimed(address indexed recipient, uint256 amount, uint256 epochId);

    error UnauthorizedReporter();
    error EpochNotEnded();
    error EpochAlreadyFinalized();
    error InvalidZKProof();
    error NullifierAlreadyUsed();
    error ExceedsPerCapitaLimit();
    error AccountAlreadyClaimed();
    error ZeroAddressProvided();

    constructor(
        address _issuance,
        address _verifier,
        address _goldOracle,
        address _reserve
    ) Ownable(msg.sender) {
        if (_issuance == address(0) || _verifier == address(0) || _goldOracle == address(0) || _reserve == address(0)) {
            revert ZeroAddressProvided();
        }

        genesisIssuance = IGenesisIssuance(_issuance);
        zkVerifier = IZKVerifier(_verifier);
        goldOracle = IChainlinkOracle(_goldOracle);
        noteMaintenanceReserve = _reserve;
        epochStartTime = block.timestamp;
    }

    modifier onlyReporter() {
        if (!metricReporters[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedReporter();
        }
        _;
    }

    function setReporter(address reporter, bool status) external onlyOwner {
        if (reporter == address(0)) revert ZeroAddressProvided();
        metricReporters[reporter] = status;
    }

    /**
     * @notice Records monthly active economic state metrics from verified nodes
     */
    function recordEpochMetrics(
        uint256 digitalVolume,
        uint256 circulatingNotes,
        uint256 fiatEscrowAmount,
        uint256 tokenEscrowAmount
    ) external onlyReporter {
        currentEpochDigitalVolume += digitalVolume;
        currentEpochCirculatingNotes += circulatingNotes;
        currentEpochFiatEscrow += fiatEscrowAmount;
        currentEpochTokenEscrow += tokenEscrowAmount;

        emit ActivityReported(msg.sender, digitalVolume, circulatingNotes, fiatEscrowAmount, tokenEscrowAmount);
    }

    /**
     * @notice Finalizes epoch: Calculates the 0.5% Worker Pool and sets the Citizen Per-Capita Cap
     */
    function finalizeEpoch() external nonReentrant {
        if (block.timestamp < epochStartTime + EPOCH_DURATION) revert EpochNotEnded();

        // 1. Fetch live Gold Price (XAU/USD, 8 decimals) and calculate Gold Value of Fiat Escrow
        int256 goldPrice = goldOracle.latestAnswer();
        require(goldPrice > 0, "Invalid Gold Oracle Price");
        uint256 fiatEscrowInGoldValue = (currentEpochFiatEscrow * 1e8) / uint256(goldPrice);

        // 2. Sum Total Economic Base: Digital Vol + Circulating Notes + Active Escrow (Gold Value + Tokens)
        uint256 totalEconomicBase = currentEpochDigitalVolume + 
                                    currentEpochCirculatingNotes + 
                                    fiatEscrowInGoldValue + 
                                    currentEpochTokenEscrow;

        // 3. Worker Split = Exactly 0.5% (50 BPS) of Total Economic Base
        uint256 workerPool = (totalEconomicBase * WORKER_SPLIT_BPS) / 10000;

        // 4. Calculate Citizen Per-Capita Claim Ceiling
        uint256 maxCitizenCap;
        if (prevEpochUniqueCitizenClaimants > 100) {
            // Standard 0.5% growth ceiling divided per-capita once network exceeds 100 active citizens
            uint256 maxCitizenPool = (prevEpochTotalCitizenClaims * 1005) / 1000; 
            maxCitizenCap = maxCitizenPool / prevEpochUniqueCitizenClaimants;
        } else {
            // Bootstrapping Phase: Assign a fixed safe maximum ceiling per account
            maxCitizenCap = INITIAL_BOOTSTRAP_CAP;
        }

        // 5. Calculate Worker Sub-Pool Shares
        uint256 reserveShare = (workerPool * 2) / 100;

        epochPools[currentEpoch] = EpochPool({
            finalized: true,
            totalWorkerRewardPool: workerPool,
            validatorShare: (workerPool * 40) / 100,
            verifierShare: (workerPool * 30) / 100,
            noteHwBountyShare: (workerPool * 10) / 100,
            notePresenceShare: (workerPool * 8) / 100,
            noteReserveShare: reserveShare,
            arbitratorShare: (workerPool * 10) / 100,
            maxPerCapitaCitizenClaim: maxCitizenCap
        });

        // Auto-mint 2% reserve share to reserve multi-sig
        if (reserveShare > 0) {
            genesisIssuance.mintWorkerReward(noteMaintenanceReserve, reserveShare);
        }

        emit EpochFinalized(currentEpoch, workerPool, maxCitizenCap);

        // 6. Roll Over Epoch Counters
        prevEpochTotalCitizenClaims = currentEpochCitizenClaims;
        prevEpochUniqueCitizenClaimants = currentEpochUniqueClaimantCount;

        currentEpoch++;
        epochStartTime = block.timestamp;
        currentEpochDigitalVolume = 0;
        currentEpochCirculatingNotes = 0;
        currentEpochFiatEscrow = 0;
        currentEpochTokenEscrow = 0;
        currentEpochCitizenClaims = 0;
        currentEpochUniqueClaimantCount = 0;
    }

    /**
     * @notice Citizen/Resident Claim Function with strict Per-Capita Cap enforcement
     */
    function claimCitizenReward(uint256 epochId, uint256 requestedAmount) external nonReentrant {
        EpochPool memory epoch = epochPools[epochId];
        if (!epoch.finalized) revert EpochAlreadyFinalized();
        if (epochClaimedByAccount[epochId][msg.sender]) revert AccountAlreadyClaimed();
        
        // Strictly enforce cap (whether bootstrap cap or per-capita cap)
        if (requestedAmount > epoch.maxPerCapitaCitizenClaim) {
            revert ExceedsPerCapitaLimit();
        }

        // Checks-Effects State Updates
        epochClaimedByAccount[epochId][msg.sender] = true;
        currentEpochCitizenClaims += requestedAmount;
        currentEpochUniqueClaimantCount++;

        // External Interaction
        genesisIssuance.mintWorkerReward(msg.sender, requestedAmount);
        emit CitizenRewardClaimed(msg.sender, requestedAmount, epochId);
    }

    /**
     * @notice Worker Anonymous ZK Claim Function
     */
    function claimWorkerRewardAnonymous(
        bytes calldata proof,
        bytes32 nullifierHash,
        address recipient,
        uint256 amount,
        uint256 epochId
    ) external nonReentrant {
        if (!epochPools[epochId].finalized) revert EpochAlreadyFinalized();
        if (nullifierSpent[nullifierHash]) revert NullifierAlreadyUsed();
        if (recipient == address(0)) revert ZeroAddressProvided();

        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = uint256(nullifierHash);
        publicInputs[1] = amount;

        if (!zkVerifier.verifyProof(proof, publicInputs)) revert InvalidZKProof();

        // Checks-Effects State Update
        nullifierSpent[nullifierHash] = true;

        // External Interaction
        genesisIssuance.mintWorkerReward(recipient, amount);

        emit AnonymousWorkerRewardClaimed(nullifierHash, recipient, amount);
    }
}
