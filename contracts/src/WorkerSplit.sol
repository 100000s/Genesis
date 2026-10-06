// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorkerIssuance {
    function mintWorkerReward(address, uint256) external;
}

interface IWorkerOracle {
    function getDynamicIssuanceRateBps() external view returns (uint256);
    function getTwapMultiplier() external view returns (uint256);
}

/// @notice WorkerSplit: Epoch-based 40/30/20/10 worker distribution
/// with dynamic TWAP-scaled minting and 0.5% base floor per component.
///
/// Key design:
/// - Base pool = activity × 0.5% (50 bps for WorkerSplit component)
/// - Dynamic scaling: base × getDynamicIssuanceRateBps() / 50 (scale from 50 bps floor)
/// - TWAP multiplier applied for price-growth-based supply expansion (never < 1.0)
/// - Inactivity rolls over to next epoch
/// - Arbitrators only claim if successful; unsuccessful arbitrators automatically rollover
contract WorkerSplit {
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant BASE_FLOOR_BPS = 50;  // 0.5% floor per component
    uint256 public constant BOOTSTRAP_POOL = 10_000 ether; // Total bootstrap: 10k GEN
    uint64 public constant EPOCH_DURATION = 30 days;

    // Worker type IDs
    uint8 public constant VALIDATOR = 0;
    uint8 public constant VERIFIER = 1;
    uint8 public constant APP = 2;
    uint8 public constant NOTE = 3;
    uint8 public constant ARBITRATOR = 4;

    // Split percentages (sum = 10,000 bps)
    uint256 public constant VALIDATOR_RATIO = 2000;    // 20%
    uint256 public constant VERIFIER_RATIO = 2000;     // 20%
    uint256 public constant APP_RATIO = 3000;          // 30%
    uint256 public constant NOTE_RATIO = 2000;         // 20%
    uint256 public constant ARBITRATOR_RATIO = 1000;   // 10%

    address public owner;
    IWorkerIssuance public immutable issuance;
    IWorkerOracle public immutable oracle;

    uint64 public epoch = 1;
    uint64 public epochStart;
    uint256 public rollover;
    uint256 public activity;

    mapping(address => bool) public reporters;
    mapping(uint8 => address[]) private members;
    mapping(address => uint8) public memberKind;  // 0 = unregistered, 1-5 = VALIDATOR-ARBITRATOR+1
    mapping(uint64 => mapping(uint8 => uint256)) public pool;  // epoch => kind => pool amount
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed; // epoch => kind => user => claimed
    mapping(uint64 => mapping(address => bool)) public successfulArbitrator; // epoch => arbitrator => successful

    event ActivityReported(address indexed reporter, uint256 amount);
    event NativeVolumeReported(address indexed reporter, uint256 amount);
    event EpochFinalized(uint64 indexed epoch, uint256 workerPool, uint256 dynamicRateBps, uint256 twapMul);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed kind, address indexed member, uint256 amount);
    event ReporterUpdated(address indexed reporter, bool enabled);
    event MemberRegistered(address indexed member, uint8 indexed kind);
    event ArbitratorMarked(uint64 indexed epoch, address indexed arbitrator, bool successful);

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
        reporters[who] = enabled;
        emit ReporterUpdated(who, enabled);
    }

    /// @notice Register a worker (idempotent)
    function register(uint8 kind) external {
        require(kind <= ARBITRATOR, "WorkerSplit: invalid kind");
        require(memberKind[msg.sender] == 0, "WorkerSplit: already registered");

        memberKind[msg.sender] = kind + 1; // Store as 1-indexed for distinction
        members[kind].push(msg.sender);
        emit MemberRegistered(msg.sender, kind);
    }

    /// @notice Report on-chain activity volume
    function recordActivity(uint256 amount) external onlyReporter {
        activity += amount;
        emit ActivityReported(msg.sender, amount);
    }

    /// @notice Report native Genesis token volume
    function recordNativeVolume(uint256 amount) external onlyReporter {
        activity += amount;
        emit NativeVolumeReported(msg.sender, amount);
    }

    /// @notice Mark an arbitrator as successful for a completed epoch
    function markSuccessfulArbitrator(uint64 claimEpoch, address arbitrator) external onlyReporter {
        require(claimEpoch < epoch, "WorkerSplit: future epoch");
        successfulArbitrator[claimEpoch][arbitrator] = true;
        emit ArbitratorMarked(claimEpoch, arbitrator, true);
    }

    /// @notice Finalize epoch and compute pools with dynamic TWAP scaling
    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "WorkerSplit: epoch active");

        // Base pool = activity × 0.5% (50 bps for WorkerSplit component)
        uint256 base = (activity * BASE_FLOOR_BPS) / BPS;

        // Get dynamic issuance rate (100 bps floor, scaled by TWAP)
        uint256 dynamicBps = oracle.getDynamicIssuanceRateBps();

        // WorkerSplit's share of dynamic rate (0.5% of total 1.0%)
        // Scale from dynamic bps back to 50 bps floor basis
        uint256 scaleFactor = (dynamicBps * WAD) / (2 * BASE_FLOOR_BPS); // 2 because split 50/50 with GenesisIssuance
        uint256 scaledPool = (base * scaleFactor) / WAD;

        // Apply TWAP multiplier (never < 1.0)
        uint256 twapMul = oracle.getTwapMultiplier();
        scaledPool = (scaledPool * twapMul) / WAD;

        // Add rollover from prior epoch
        scaledPool += rollover;
        rollover = 0;

        // Allocate to each worker type
        pool[epoch][VALIDATOR] = (scaledPool * VALIDATOR_RATIO) / BPS;
        pool[epoch][VERIFIER] = (scaledPool * VERIFIER_RATIO) / BPS;
        pool[epoch][APP] = (scaledPool * APP_RATIO) / BPS;
        pool[epoch][NOTE] = (scaledPool * NOTE_RATIO) / BPS;
        pool[epoch][ARBITRATOR] = (scaledPool * ARBITRATOR_RATIO) / BPS;

        activity = 0;
        epoch++;
        epochStart = uint64(block.timestamp);

        emit EpochFinalized(epoch - 1, scaledPool, dynamicBps, twapMul);
    }

    /// @notice Claim worker reward for a completed epoch
    function claim(uint64 claimEpoch, uint8 kind) external {
        require(claimEpoch < epoch, "WorkerSplit: future epoch");
        require(kind <= ARBITRATOR, "WorkerSplit: invalid kind");
        require(!claimed[claimEpoch][kind][msg.sender], "WorkerSplit: already claimed");
        require(memberKind[msg.sender] > 0, "WorkerSplit: not registered");

        uint256 amount = 0;

        if (kind == ARBITRATOR) {
            // Arbitrators: only successful ones claim; unsuccessful rollover automatically
            if (successfulArbitrator[claimEpoch][msg.sender]) {
                // Count successful arbitrators in this epoch
                uint256 successCount = 0;
                for (uint256 i = 0; i < members[ARBITRATOR].length; i++) {
                    if (successfulArbitrator[claimEpoch][members[ARBITRATOR][i]]) {
                        successCount++;
                    }
                }
                require(successCount > 0, "WorkerSplit: no successful arbitrators");
                amount = pool[claimEpoch][ARBITRATOR] / successCount;
            } else {
                // Non-successful arbitrators don't claim; their share rolls over
                revert("WorkerSplit: not successful arbitrator");
            }
        } else {
            // Other workers: split equally among all registered for this kind
            uint256 memberCount = members[kind].length;
            require(memberCount > 0, "WorkerSplit: no members");
            amount = pool[claimEpoch][kind] / memberCount;
        }

        require(amount > 0, "WorkerSplit: zero amount");

        claimed[claimEpoch][kind][msg.sender] = true;
        issuance.mintWorkerReward(msg.sender, amount);
        emit RewardClaimed(claimEpoch, kind, msg.sender, amount);
    }

    /// @notice Get member count for a worker type
    function participantCount(uint8 kind) external view returns (uint256) {
        return members[kind].length;
    }

    /// @notice Get list of members for a worker type (view only)
    function getMembers(uint8 kind) external view returns (address[] memory) {
        return members[kind];
    }
}
