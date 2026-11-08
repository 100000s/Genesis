// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface INoteRewardToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface INoteSharedEpoch { function epoch() external view returns (uint64); }
interface INoteMaintenanceDAO { function notifyFunding(uint64 fundingEpoch, uint256 amount) external; }

/// @notice Automated 10% ATM qualification bounty and 8% activity rewards;
/// 2% is reserved for a separately governed NoteTeam maintenance treasury.
/// Accounting uses pseudonymous operator commitments; privacy of real-world identity
/// still depends on the external attestation and operator key-management system.
contract NoteTeamRewardDistributor {
    uint256 public constant BPS = 10_000;
    address public owner;
    INoteRewardToken public immutable token;
    INoteSharedEpoch public immutable workerSplit;
    INoteMaintenanceDAO public maintenanceDAO;
    mapping(address => bool) public qualificationVerifiers;
    mapping(address => bool) public activityVerifiers;
    mapping(bytes32 => bool) public atmQualified;
    mapping(bytes32 => bytes32) public atmOperator;
    mapping(bytes32 => bool) public operationUsed;
    mapping(bytes32 => address) private payoutAddress;
    mapping(uint64 => uint256) public fundingByEpoch;
    mapping(uint64 => uint256) public hardwarePool;
    mapping(uint64 => uint256) public presencePool;
    mapping(uint64 => uint256) public newOperatorCount;
    mapping(uint64 => uint256) public totalActivityWeight;
    mapping(uint64 => mapping(bytes32 => bool)) public newlyQualified;
    mapping(uint64 => mapping(bytes32 => uint256)) public activityWeight;
    mapping(uint64 => mapping(bytes32 => bool)) public hardwareClaimed;
    mapping(uint64 => mapping(bytes32 => bool)) public presenceClaimed;
    mapping(uint64 => mapping(bytes32 => bytes32)) public qualificationForATM;
    mapping(uint64 => bool) public finalized;
    mapping(uint64 => uint256) public claimedHardware;
    mapping(uint64 => uint256) public claimedPresence;
    mapping(uint64 => uint256) public hardwareRollover;
    mapping(uint64 => uint256) public presenceRollover;

    event VerifierUpdated(address indexed verifier, bool enabled, bool forQualification);
    event MaintenanceDAOUpdated(address indexed dao);
    event FundingRecorded(uint64 indexed epoch, uint256 amount);
    event ATMQualified(uint64 indexed epoch, bytes32 indexed atmId, bytes32 indexed operatorCommitment);
    event PresenceRecorded(uint64 indexed epoch, bytes32 indexed operatorCommitment, bytes32 indexed operationId, uint256 weight, bytes32 evidenceHash);
    event EpochFinalized(uint64 indexed epoch, uint256 hardwarePool, uint256 presencePool, uint256 maintenanceAmount);
    event HardwareBountyClaimed(uint64 indexed epoch, bytes32 indexed operatorCommitment, address recipient, uint256 amount);
    event PresenceRewardClaimed(uint64 indexed epoch, bytes32 indexed operatorCommitment, address recipient, uint256 amount);

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

    function setVerifier(address verifier, bool enabled, bool forQualification) external onlyOwner {
        require(verifier != address(0), "NoteRewards: zero verifier");
        if (forQualification) qualificationVerifiers[verifier] = enabled;
        else activityVerifiers[verifier] = enabled;
        emit VerifierUpdated(verifier, enabled, forQualification);
    }

    function notifyWorkerPool(uint64 fundingEpoch, uint256 amount) external {
        require(msg.sender == address(workerSplit), "NoteRewards: worker split only");
        require(fundingEpoch > 0 && amount > 0 && !finalized[fundingEpoch], "NoteRewards: invalid funding");
        require(token.balanceOf(address(this)) >= _accountedBalance() + amount, "NoteRewards: pool not backed");
        fundingByEpoch[fundingEpoch] += amount;
        emit FundingRecorded(fundingEpoch, amount);
    }

    /// @notice An ATM identity can qualify once ever; bounty is attached to the
    /// operator commitment and one newly-qualified event per operator per epoch.
    function qualifyATM(uint64 qualifyingEpoch, bytes32 atmId, bytes32 operatorCommitment, address recipient, bytes32 evidenceHash) external {
        require(qualificationVerifiers[msg.sender], "NoteRewards: qualification verifier only");
        require(qualifyingEpoch == workerSplit.epoch() && atmId != bytes32(0) && operatorCommitment != bytes32(0), "NoteRewards: invalid qualification");
        require(recipient != address(0) && evidenceHash != bytes32(0), "NoteRewards: invalid evidence");
        require(!atmQualified[atmId], "NoteRewards: ATM already qualified");
        atmQualified[atmId] = true;
        atmOperator[atmId] = operatorCommitment;
        payoutAddress[operatorCommitment] = recipient;
        if (!newlyQualified[qualifyingEpoch][operatorCommitment]) {
            newlyQualified[qualifyingEpoch][operatorCommitment] = true;
            newOperatorCount[qualifyingEpoch]++;
        }
        qualificationForATM[qualifyingEpoch][atmId] = operatorCommitment;
        emit ATMQualified(qualifyingEpoch, atmId, operatorCommitment);
    }

    function recordPresence(uint64 activityEpoch, bytes32 operatorCommitment, bytes32 operationId, uint256 weight, bytes32 evidenceHash, address recipient) external {
        require(activityVerifiers[msg.sender], "NoteRewards: activity verifier only");
        require(activityEpoch == workerSplit.epoch() && operatorCommitment != bytes32(0), "NoteRewards: invalid epoch or operator");
        require(operationId != bytes32(0) && !operationUsed[operationId] && weight > 0 && evidenceHash != bytes32(0), "NoteRewards: invalid or duplicate operation");
        require(recipient != address(0), "NoteRewards: zero recipient");
        operationUsed[operationId] = true;
        payoutAddress[operatorCommitment] = recipient;
        activityWeight[activityEpoch][operatorCommitment] += weight;
        totalActivityWeight[activityEpoch] += weight;
        emit PresenceRecorded(activityEpoch, operatorCommitment, operationId, weight, evidenceHash);
    }

    function finalizeEpoch(uint64 closedEpoch) external {
        require(closedEpoch > 0 && closedEpoch < workerSplit.epoch(), "NoteRewards: epoch active");
        require(!finalized[closedEpoch], "NoteRewards: already finalized");
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
        require(address(maintenanceDAO) != address(0), "NoteRewards: maintenance DAO unset");
        if (maintenance > 0) {
            require(token.transfer(address(maintenanceDAO), maintenance), "NoteRewards: maintenance transfer failed");
            maintenanceDAO.notifyFunding(closedEpoch, maintenance);
        }
        emit EpochFinalized(closedEpoch, hardware, presence, maintenance);
    }

    function claimHardware(uint64 claimEpoch, bytes32 operatorCommitment) external {
        require(finalized[claimEpoch] && newlyQualified[claimEpoch][operatorCommitment], "NoteRewards: no bounty eligibility");
        require(!hardwareClaimed[claimEpoch][operatorCommitment], "NoteRewards: bounty claimed");
        address recipient = payoutAddress[operatorCommitment];
        require(recipient != address(0) && msg.sender == recipient, "NoteRewards: payout identity mismatch");
        uint256 amount = hardwarePool[claimEpoch] / newOperatorCount[claimEpoch];
        require(amount > 0, "NoteRewards: zero bounty");
        hardwareClaimed[claimEpoch][operatorCommitment] = true;
        claimedHardware[claimEpoch] += amount;
        require(token.transfer(recipient, amount), "NoteRewards: transfer failed");
        emit HardwareBountyClaimed(claimEpoch, operatorCommitment, recipient, amount);
    }

    function claimPresence(uint64 claimEpoch, bytes32 operatorCommitment) external {
        require(finalized[claimEpoch] && activityWeight[claimEpoch][operatorCommitment] > 0, "NoteRewards: no presence eligibility");
        require(!presenceClaimed[claimEpoch][operatorCommitment], "NoteRewards: presence claimed");
        address recipient = payoutAddress[operatorCommitment];
        require(recipient != address(0) && msg.sender == recipient, "NoteRewards: payout identity mismatch");
        uint256 amount = (presencePool[claimEpoch] * activityWeight[claimEpoch][operatorCommitment]) / totalActivityWeight[claimEpoch];
        require(amount > 0, "NoteRewards: zero reward");
        presenceClaimed[claimEpoch][operatorCommitment] = true;
        claimedPresence[claimEpoch] += amount;
        require(token.transfer(recipient, amount), "NoteRewards: transfer failed");
        emit PresenceRewardClaimed(claimEpoch, operatorCommitment, recipient, amount);
    }

    function _accountedBalance() internal view returns (uint256 total) {
        for (uint64 e = 1; e <= workerSplit.epoch(); e++) {
            total += fundingByEpoch[e] - (finalized[e] ? (fundingByEpoch[e] * 1_000) / BPS : 0);
            total += hardwarePool[e] - claimedHardware[e];
            total += presencePool[e] - claimedPresence[e];
        }
        for (uint64 e = 1; e <= workerSplit.epoch() + 1; e++) {
            total += hardwareRollover[e] + presenceRollover[e];
        }
    }
}
