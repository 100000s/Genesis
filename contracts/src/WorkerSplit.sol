// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWorkerIssuance { function mintWorkerReward(address recipient, uint256 amount) external; }
interface IWorkerOracle { function latest(bytes32 key) external view returns (uint256 value, uint64 observedAt, uint64 round, bytes32 sourceHash); }

contract WorkerSplit {
    uint256 public constant ACTIVITY_BPS = 50;
    uint256 public constant BPS = 10_000;
    bytes32 public constant ACTIVITY_KEY = keccak256("GENESIS.ACTIVE_TRANSACTION_VOLUME");
    uint8 public constant VERIFIER = 0;
    uint8 public constant VALIDATOR = 1;
    uint8 public constant ATM = 2;
    uint8 public constant ARBITRATOR = 3;
    address public owner;
    IWorkerIssuance public immutable issuance;
    IWorkerOracle public immutable oracle;
    uint64 public epoch;
    uint64 public lastFinalizedEpoch;
    uint64 public epochStart;
    uint64 public constant EPOCH_DURATION = 30 days;
    uint256 public rollover;
    mapping(address => bool) public reporters;
    mapping(uint8 => address[]) private participants;
    mapping(address => uint8) public participantKind;
    mapping(address => uint256) public score;
    mapping(uint64 => mapping(uint8 => uint256)) public pool;
    mapping(uint64 => mapping(uint8 => uint256)) public claimed;
    mapping(bytes32 => bool) public nullifierUsed;
    event ActivityReported(address indexed reporter, uint256 amount);
    event EpochFinalized(uint64 indexed epoch, uint256 activity, uint256 workerPool);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed kind, bytes32 indexed nullifier, uint256 amount);
    modifier onlyOwner() { require(msg.sender == owner, "WorkerSplit: owner only"); _; }
    modifier onlyReporter() { require(reporters[msg.sender], "WorkerSplit: reporter only"); _; }
    constructor(address issuanceAddress, address oracleAddress) {
        require(issuanceAddress != address(0) && oracleAddress != address(0), "WorkerSplit: zero address");
        owner = msg.sender; issuance = IWorkerIssuance(issuanceAddress); oracle = IWorkerOracle(oracleAddress); epoch = 1; epochStart = uint64(block.timestamp);
    }
    function setReporter(address reporter, bool enabled) external onlyOwner { reporters[reporter] = enabled; }
    function register(uint8 kind) external { require(kind <= ARBITRATOR, "WorkerSplit: invalid kind"); participantKind[msg.sender] = kind; participants[kind].push(msg.sender); }
    function recordActivity(uint256 amount) external onlyReporter { emit ActivityReported(msg.sender, amount); }
    function recordScore(address participant, uint256 value) external onlyReporter { score[participant] = value; }
    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "WorkerSplit: epoch active");
        (uint256 activity,,,) = oracle.latest(ACTIVITY_KEY);
        uint256 workerPool = rollover + activity * ACTIVITY_BPS / BPS;
        pool[epoch][VERIFIER] = workerPool * 1500 / BPS;
        pool[epoch][VALIDATOR] = workerPool * 1500 / BPS;
        pool[epoch][ATM] = workerPool * 2500 / BPS;
        pool[epoch][ARBITRATOR] = workerPool * 1500 / BPS;
        rollover = workerPool - pool[epoch][VERIFIER] - pool[epoch][VALIDATOR] - pool[epoch][ATM] - pool[epoch][ARBITRATOR];
        lastFinalizedEpoch = epoch++;
        epochStart = uint64(block.timestamp);
        emit EpochFinalized(lastFinalizedEpoch, activity, workerPool);
    }
    function claim(uint64 claimEpoch, uint8 kind, bytes32 nullifier) external {
        require(claimEpoch > 0 && claimEpoch <= lastFinalizedEpoch && !nullifierUsed[nullifier], "WorkerSplit: invalid claim");
        uint256 count = participants[kind].length;
        require(count > 0 && kind <= ARBITRATOR, "WorkerSplit: no participants");
        uint256 amount = pool[claimEpoch][kind] / count;
        require(amount > claimed[claimEpoch][kind], "WorkerSplit: pool claimed");
        nullifierUsed[nullifier] = true;
        claimed[claimEpoch][kind] += amount;
        issuance.mintWorkerReward(msg.sender, amount);
        emit RewardClaimed(claimEpoch, kind, nullifier, amount);
    }
    function participantCount(uint8 kind) external view returns (uint256) { return participants[kind].length; }
}