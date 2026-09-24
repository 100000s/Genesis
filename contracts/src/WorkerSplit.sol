// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGenesisWorkerIssuance { function mintWorkerReward(address recipient, uint256 amount) external; }
interface IGenesisWorkerOracle { function getDynamicIssuanceRateBps() external view returns (uint256); }
interface IAppPoolReceiver { function notifyWorkerPool(uint256 amount) external; }

/// @notice Monthly worker pool. The App Team allocation is claimed by AppTeamDAO.
contract WorkerSplit {
    uint256 public constant BPS = 10_000;
    uint256 public constant WORKER_RATE_BPS = 50;
    uint256 public constant BOOTSTRAP_POOL = 10_000 ether;
    uint64 public constant EPOCH_DURATION = 30 days;
    uint8 public constant VALIDATOR = 0;
    uint8 public constant VERIFIER = 1;
    uint8 public constant APP = 2;
    uint8 public constant NOTE = 3;
    uint8 public constant ARBITRATOR = 4;

    // These values are governance-controlled only by changing this canonical contract.
    uint256 public constant APP_NOTE_BPS = 3_333;
    uint256 public constant APP_DIGITAL_BPS = 3_333;
    uint256 public constant APP_VIRTUAL_BPS = 3_334;

    address public owner;
    IGenesisWorkerIssuance public immutable issuance;
    IGenesisWorkerOracle public immutable oracle;
    address public appTeamDAO;
    uint64 public epoch = 1;
    uint64 public epochStart;
    uint256 public rollover;
    uint256 public activity;
    bool public bootstrapActive = true;

    mapping(address => bool) public reporters;
    mapping(uint8 => address[]) private members;
    mapping(address => uint8) public memberKind; // kind + 1; zero means unregistered
    mapping(uint64 => mapping(uint8 => uint256)) public pool;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public claimed;
    mapping(uint64 => mapping(address => bool)) public successfulArbitrator;

    event ActivityReported(address indexed reporter, uint256 amount);
    event EpochFinalized(uint64 indexed epoch, uint256 workerPool);
    event RewardClaimed(uint64 indexed epoch, uint8 indexed kind, address indexed recipient, uint256 amount);
    event AppTeamDAOSet(address indexed dao);

    modifier onlyOwner() { require(msg.sender == owner, "WorkerSplit: owner"); _; }
    modifier onlyReporter() { require(reporters[msg.sender] || msg.sender == owner, "WorkerSplit: reporter"); _; }

    constructor(address issuanceAddress, address oracleAddress) {
        require(issuanceAddress != address(0) && oracleAddress != address(0), "WorkerSplit: zero");
        owner = msg.sender;
        issuance = IGenesisWorkerIssuance(issuanceAddress);
        oracle = IGenesisWorkerOracle(oracleAddress);
        epochStart = uint64(block.timestamp);
    }

    function setReporter(address who, bool enabled) external onlyOwner { reporters[who] = enabled; }
    function setAppTeamDAO(address dao) external onlyOwner {
        require(dao != address(0), "WorkerSplit: zero");
        appTeamDAO = dao;
        emit AppTeamDAOSet(dao);
    }
    function register(uint8 kind) external {
        require(kind <= ARBITRATOR, "WorkerSplit: kind");
        require(memberKind[msg.sender] == 0, "WorkerSplit: member");
        memberKind[msg.sender] = kind + 1;
        members[kind].push(msg.sender);
    }
    function recordActivity(uint256 amount) external onlyReporter { activity += amount; emit ActivityReported(msg.sender, amount); }
    function recordNativeVolume(uint256 amount) external onlyReporter { activity += amount; emit ActivityReported(msg.sender, amount); }
    function markSuccessfulArbitrator(uint64 claimEpoch, address arbitrator) external onlyReporter { successfulArbitrator[claimEpoch][arbitrator] = true; }

    function finalizeEpoch() external {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "WorkerSplit: active");
        uint256 base = activity * WORKER_RATE_BPS / BPS;
        uint256 dynamic = base * oracle.getDynamicIssuanceRateBps() / BPS;
        uint256 total = rollover + (bootstrapActive ? BOOTSTRAP_POOL : dynamic);
        pool[epoch][VALIDATOR] = total * 20 / 100;
        pool[epoch][VERIFIER] = total * 20 / 100;
        pool[epoch][APP] = total * 30 / 100;
        pool[epoch][NOTE] = total * 20 / 100;
        pool[epoch][ARBITRATOR] = total - pool[epoch][VALIDATOR] - pool[epoch][VERIFIER] - pool[epoch][APP] - pool[epoch][NOTE];
        rollover = 0;
        activity = 0;
        bootstrapActive = false;
        emit EpochFinalized(epoch, total);
        epoch++;
        epochStart = uint64(block.timestamp);
    }

    function claim(uint64 claimEpoch, uint8 kind) external {
        require(claimEpoch < epoch && kind <= ARBITRATOR, "WorkerSplit: epoch");
        require(!claimed[claimEpoch][kind][msg.sender], "WorkerSplit: claimed");
        uint256 amount;
        if (kind == APP) {
            require(msg.sender == appTeamDAO, "WorkerSplit: app DAO");
            amount = pool[claimEpoch][APP];
            require(amount > 0, "WorkerSplit: zero reward");
            IAppPoolReceiver(appTeamDAO).notifyWorkerPool(amount);
        } else if (kind == ARBITRATOR) {
            require(successfulArbitrator[claimEpoch][msg.sender], "WorkerSplit: arbitrator");
            amount = pool[claimEpoch][kind];
        } else {
            require(memberKind[msg.sender] == kind + 1, "WorkerSplit: member");
            uint256 count = members[kind].length;
            require(count > 0, "WorkerSplit: empty");
            amount = pool[claimEpoch][kind] / count;
        }
        claimed[claimEpoch][kind][msg.sender] = true;
        issuance.mintWorkerReward(msg.sender, amount);
        emit RewardClaimed(claimEpoch, kind, msg.sender, amount);
    }
    function participantCount(uint8 kind) external view returns (uint256) { return members[kind].length; }
}
