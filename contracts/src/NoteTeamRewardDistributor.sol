// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INoteRewardToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
interface INoteSharedEpoch { function epoch() external view returns (uint64); }
interface INoteMaintenanceDAO { function notifyFunding(uint64 fundingEpoch, uint256 amount) external; }

/// @notice README's 20% Note Team allocation: 10% hardware bounty, 8% active
/// presence, 2% maintenance. Unclaimed rewards remain permanent liabilities.
contract NoteTeamRewardDistributor {
    uint256 public constant BPS = 10_000;
    address public owner;
    INoteRewardToken public immutable token;
    INoteSharedEpoch public immutable workerSplit;
    INoteMaintenanceDAO public maintenanceDAO;
    mapping(address => bool) public qualificationVerifiers;
    mapping(address => bool) public activityVerifiers;
    mapping(bytes32 => bool) public registeredOperators;
    mapping(bytes32 => bool) public atmQualified;
    mapping(bytes32 => bytes32) public atmOperator;
    mapping(bytes32 => bool) public operationUsed;
    mapping(bytes32 => address) public payoutAddress;
    mapping(uint64 => uint256) public fundingByEpoch;
    mapping(uint64 => bool) public finalized;
    mapping(uint64 => uint256) public hardwarePool;
    mapping(uint64 => uint256) public presencePool;
    mapping(uint64 => uint256) public newOperatorCount;
    mapping(uint64 => uint256) public totalActivityWeight;
    mapping(uint64 => mapping(bytes32 => bool)) public newlyQualified;
    mapping(uint64 => mapping(bytes32 => uint256)) public activityWeight;
    mapping(uint64 => mapping(bytes32 => bool)) public hardwareClaimed;
    mapping(uint64 => mapping(bytes32 => bool)) public presenceClaimed;
    mapping(uint64 => uint256) public claimedHardware;
    mapping(uint64 => uint256) public claimedPresence;
    mapping(uint64 => uint256) public hardwareRollover;
    mapping(uint64 => uint256) public presenceRollover;
    mapping(uint64 => uint256) public maintenanceAmount;

    event VerifierUpdated(address indexed verifier, bool enabled, bool forQualification);
    event OperatorRegistered(bytes32 indexed operatorCommitment, bool enabled);
    event MaintenanceDAOUpdated(address indexed dao);
    event FundingRecorded(uint64 indexed epoch, uint256 amount);
    event ATMQualified(uint64 indexed epoch, bytes32 indexed atmId, bytes32 indexed operatorCommitment);
    event PresenceRecorded(uint64 indexed epoch, bytes32 indexed operatorCommitment, bytes32 indexed operationId, uint256 weight, bytes32 evidenceHash);
    event EpochFinalized(uint64 indexed epoch, uint256 hardware, uint256 presence, uint256 maintenance);
    event HardwareClaimed(uint64 indexed epoch, bytes32 indexed operator, address recipient, uint256 amount);
    event PresenceClaimed(uint64 indexed epoch, bytes32 indexed operator, address recipient, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "NoteRewards: owner only"); _; }
    constructor(address tokenAddress, address workerSplitAddress) {
        require(tokenAddress != address(0) && workerSplitAddress != address(0), "NoteRewards: zero address");
        owner = msg.sender;
        token = INoteRewardToken(tokenAddress);
        workerSplit = INoteSharedEpoch(workerSplitAddress);
    }
    function setMaintenanceDAO(address dao) external onlyOwner {
        require(dao != address(0), "NoteRewards: zero DAO");
        maintenanceDAO = INoteMaintenanceDAO(dao);
        emit MaintenanceDAOUpdated(dao);
    }
    function setOperatorRegistration(bytes32 commitment, bool enabled) external onlyOwner {
        require(commitment != bytes32(0), "NoteRewards: invalid operator");
        registeredOperators[commitment] = enabled;
        emit OperatorRegistered(commitment, enabled);
    }
    function setVerifier(address verifier, bool enabled, bool qualification) external onlyOwner {
        require(verifier != address(0), "NoteRewards: zero verifier");
        if (qualification) qualificationVerifiers[verifier] = enabled;
        else activityVerifiers[verifier] = enabled;
        emit VerifierUpdated(verifier, enabled, qualification);
    }
    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external {
        require(msg.sender == address(workerSplit), "NoteRewards: WorkerSplit only");
        require(fundingEpoch > 0 && amount > 0 && !finalized[fundingEpoch], "NoteRewards: invalid funding");
        require(token.balanceOf(address(this)) >= _accountedBalance() + amount, "NoteRewards: pool not backed");
        fundingByEpoch[fundingEpoch] += amount;
        emit FundingRecorded(fundingEpoch, amount);
    }
    function qualifyATM(uint64 qualifyingEpoch, bytes32 atmId, bytes32 operator, address recipient, bytes32 evidenceHash) external {
        require(qualificationVerifiers[msg.sender], "NoteRewards: qualification verifier only");
        require(qualifyingEpoch == workerSplit.epoch() && !finalized[qualifyingEpoch], "NoteRewards: inactive epoch");
        require(atmId != bytes32(0) && operator != bytes32(0) && recipient != address(0) && evidenceHash != bytes32(0), "NoteRewards: invalid qualification");
        require(registeredOperators[operator] && !atmQualified[atmId], "NoteRewards: unregistered operator or duplicate ATM");
        atmQualified[atmId] = true;
        atmOperator[atmId] = operator;
        address previous = payoutAddress[operator];
        require(previous == address(0) || previous == recipient, "NoteRewards: payout address fixed");
        payoutAddress[operator] = recipient;
        if (!newlyQualified[qualifyingEpoch][operator]) {
            newlyQualified[qualifyingEpoch][operator] = true;
            newOperatorCount[qualifyingEpoch]++;
        }
        emit ATMQualified(qualifyingEpoch, atmId, operator);
    }
    function recordPresence(uint64 activityEpoch, bytes32 operator, bytes32 operationId, uint256 weight, bytes32 evidenceHash) external {
        require(activityVerifiers[msg.sender], "NoteRewards: activity verifier only");
        require(activityEpoch == workerSplit.epoch() && !finalized[activityEpoch], "NoteRewards: inactive epoch");
        require(registeredOperators[operator] && operator != bytes32(0), "NoteRewards: operator not registered");
        require(atmOperatorFor(operator) && operationId != bytes32(0) && !operationUsed[operationId], "NoteRewards: operator not qualified or duplicate operation");
        require(weight > 0 && evidenceHash != bytes32(0), "NoteRewards: invalid evidence");
        operationUsed[operationId] = true;
        activityWeight[activityEpoch][operator] += weight;
        totalActivityWeight[activityEpoch] += weight;
        emit PresenceRecorded(activityEpoch, operator, operationId, weight, evidenceHash);
    }
    function atmOperatorFor(bytes32 operator) public view returns (bool) {
        return payoutAddress[operator] != address(0);
    }
    function finalizeEpoch(uint64 closedEpoch) external {
        require(closedEpoch > 0 && closedEpoch < workerSplit.epoch() && !finalized[closedEpoch], "NoteRewards: epoch active or finalized");
        finalized[closedEpoch] = true;
        uint256 funding = fundingByEpoch[closedEpoch];
        uint256 hardware = (funding * 5_000) / BPS + hardwareRollover[closedEpoch];
        uint256 presence = (funding * 4_000) / BPS + presenceRollover[closedEpoch];
        uint256 maintenance = funding - (funding * 5_000) / BPS - (funding * 4_000) / BPS;
        hardwareRollover[closedEpoch] = 0;
        presenceRollover[closedEpoch] = 0;
        if (newOperatorCount[closedEpoch] > 0) hardwarePool[closedEpoch] = hardware;
        else hardwareRollover[closedEpoch + 1] += hardware;
        if (totalActivityWeight[closedEpoch] > 0) presencePool[closedEpoch] = presence;
        else presenceRollover[closedEpoch + 1] += presence;
        maintenanceAmount[closedEpoch] = maintenance;
        require(address(maintenanceDAO) != address(0), "NoteRewards: maintenance DAO unset");
        if (maintenance > 0) {
            require(token.transfer(address(maintenanceDAO), maintenance), "NoteRewards: maintenance transfer failed");
            maintenanceDAO.notifyFunding(closedEpoch, maintenance);
        }
        emit EpochFinalized(closedEpoch, hardwarePool[closedEpoch], presencePool[closedEpoch], maintenance);
    }
    function claimHardware(uint64 claimEpoch, bytes32 operator) external {
        require(finalized[claimEpoch] && newlyQualified[claimEpoch][operator] && !hardwareClaimed[claimEpoch][operator], "NoteRewards: no bounty or already claimed");
        address recipient = payoutAddress[operator];
        require(recipient != address(0) && msg.sender == recipient, "NoteRewards: payout identity mismatch");
        uint256 amount = hardwarePool[claimEpoch] / newOperatorCount[claimEpoch];
        require(amount > 0, "NoteRewards: zero bounty");
        hardwareClaimed[claimEpoch][operator] = true;
        claimedHardware[claimEpoch] += amount;
        require(token.transfer(recipient, amount), "NoteRewards: transfer failed");
        emit HardwareClaimed(claimEpoch, operator, recipient, amount);
    }
    function claimPresence(uint64 claimEpoch, bytes32 operator) external {
        require(finalized[claimEpoch] && activityWeight[claimEpoch][operator] > 0 && !presenceClaimed[claimEpoch][operator], "NoteRewards: no presence or already claimed");
        address recipient = payoutAddress[operator];
        require(recipient != address(0) && msg.sender == recipient, "NoteRewards: payout identity mismatch");
        uint256 amount = (presencePool[claimEpoch] * activityWeight[claimEpoch][operator]) / totalActivityWeight[claimEpoch];
        require(amount > 0, "NoteRewards: zero reward");
        presenceClaimed[claimEpoch][operator] = true;
        claimedPresence[claimEpoch] += amount;
        require(token.transfer(recipient, amount), "NoteRewards: transfer failed");
        emit PresenceClaimed(claimEpoch, operator, recipient, amount);
    }
    function _accountedBalance() internal view returns (uint256 total) {
        uint64 current = workerSplit.epoch();
        for (uint64 e = 1; e <= current; e++) {
            if (!finalized[e]) total += fundingByEpoch[e];
            else total += hardwarePool[e] - claimedHardware[e] + presencePool[e] - claimedPresence[e];
        }
        for (uint64 e = 1; e <= current + 1; e++) total += hardwareRollover[e] + presenceRollover[e];
    }
}
