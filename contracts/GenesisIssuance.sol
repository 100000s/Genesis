// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IGenCredsVerifier {
    function verifyStateResidency(bytes calldata zkProof, address user) external view returns (uint8 stateId, bool isValid);
}

/**
 * @title GenesisIssuance
 * @notice Manages per-capita dynamic GenToken allocations adjusted annually by ALFIN total asset ratios.
 */
contract GenesisIssuance is Ownable, ReentrancyGuard {
    uint256 public constant WAD = 1e18;
    uint256 public constant BASE_ALLOCATION = 50 * WAD; // 50 tokens baseline (2026)
    uint256 public constant LAUNCH_YEAR = 2026;
    uint256 public constant SECONDS_PER_YEAR = 365 days; // Standard calendar year reference

    address public oracle;
    IGenCredsVerifier public genCredsVerifier;

    // Federal annual base per year (Year => Base in WAD)
    mapping(uint256 => uint256) public fedAnnualBase;

    // State annual base per year per state (StateID => Year => Base in WAD)
    mapping(uint8 => mapping(uint256 => uint256)) public stateAnnualBase;

    struct AccountInfo {
        uint8 stateId;            // State residency ID (1 to 50)
        bool isVerified;          // Verified via GenCreds ZK Proof
        uint256 netWithdrawals;   // Cumulative tokens withdrawn/spent
    }

    mapping(address => AccountInfo) public accounts;

    event FedRatioUpdated(uint256 indexed year, uint256 fedRatio, uint256 newFedBase);
    event StateRatioUpdated(uint8 indexed stateId, uint256 indexed year, uint256 stateRatio, uint256 newStateBase);
    event WithdrawalExecuted(address indexed user, uint256 amount, int256 remainingBalance);
    event OracleUpdated(address indexed newOracle);

    modifier onlyOracle() {
        require(msg.sender == oracle, "GenesisIssuance: Caller is not oracle");
        _;
    }

    constructor(address _oracle, address _genCredsVerifier) Ownable(msg.sender) {
        require(_oracle != address(0) && _genCredsVerifier != address(0), "Invalid zero address");
        oracle = _oracle;
        genCredsVerifier = IGenCredsVerifier(_genCredsVerifier);

        // Initialize 2026 baseline allocations (50 Fed + 50 State = 100 GEN Total)
        fedAnnualBase[LAUNCH_YEAR] = BASE_ALLOCATION;
    }

    function setOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "Invalid zero address");
        oracle = _newOracle;
        emit OracleUpdated(_newOracle);
    }

    /**
     * @notice Returns the current calendar year derived from block.timestamp
     */
    function getCurrentYear() public view returns (uint256) {
        // Unix epoch timestamp for Jan 1, 2026 00:00:00 UTC = 1767225600
        if (block.timestamp < 1767225600) return LAUNCH_YEAR;
        return LAUNCH_YEAR + ((block.timestamp - 1767225600) / SECONDS_PER_YEAR);
    }

    /**
     * @notice Registers user residency directly using GenCreds ZK Proof verification
     */
    function registerResidentWithZK(bytes calldata zkProof) external {
        (uint8 stateId, bool isValid) = genCredsVerifier.verifyStateResidency(zkProof, msg.sender);
        require(isValid, "GenesisIssuance: Invalid ZK Proof");
        require(stateId >= 1 && stateId <= 50, "GenesisIssuance: Invalid State ID");

        accounts[msg.sender].stateId = stateId;
        accounts[msg.sender].isVerified = true;

        uint256 currentYear = getCurrentYear();
        if (stateAnnualBase[stateId][LAUNCH_YEAR] == 0) {
            stateAnnualBase[stateId][LAUNCH_YEAR] = BASE_ALLOCATION;
        }
    }

    /**
     * @notice Sets Federal total asset inverse ratio multiplier on Jan 1st.
     * @param year Target year (>= 2027)
     * @param fedRatio Ratio in WAD: FY(t-2) Total Assets / FY(t-1) Total Assets
     */
    function updateFedRatio(uint256 year, uint256 fedRatio) external onlyOracle {
        require(year > LAUNCH_YEAR, "GenesisIssuance: Adjustments begin in 2027");
        require(fedRatio > 0, "GenesisIssuance: Ratio must be > 0");

        uint256 prevFedBase = getLatestFedBase(year - 1);
        fedAnnualBase[year] = (prevFedBase * fedRatio) / WAD;

        emit FedRatioUpdated(year, fedRatio, fedAnnualBase[year]);
    }

    /**
     * @notice Sets State total asset inverse ratio multiplier for a specific state on Jan 1st.
     * @param stateId State ID (1 to 50)
     * @param year Target year (>= 2027)
     * @param stateRatio Ratio in WAD for the given state
     */
    function updateStateRatio(uint8 stateId, uint256 year, uint256 stateRatio) external onlyOracle {
        require(stateId >= 1 && stateId <= 50, "GenesisIssuance: Invalid State ID");
        require(year > LAUNCH_YEAR, "GenesisIssuance: Adjustments begin in 2027");
        require(stateRatio > 0, "GenesisIssuance: Ratio must be > 0");

        uint256 prevStateBase = getLatestStateBase(stateId, year - 1);
        stateAnnualBase[stateId][year] = (prevStateBase * stateRatio) / WAD;

        emit StateRatioUpdated(stateId, year, stateRatio, stateAnnualBase[stateId][year]);
    }

    function getLatestFedBase(uint256 year) public view returns (uint256) {
        while (year >= LAUNCH_YEAR) {
            if (fedAnnualBase[year] > 0) return fedAnnualBase[year];
            unchecked { year--; }
        }
        return BASE_ALLOCATION;
    }

    function getLatestStateBase(uint8 stateId, uint256 year) public view returns (uint256) {
        while (year >= LAUNCH_YEAR) {
            if (stateAnnualBase[stateId][year] > 0) return stateAnnualBase[stateId][year];
            unchecked { year--; }
        }
        return BASE_ALLOCATION;
    }

    function getGrossBase(address user) public view returns (uint256) {
        AccountInfo memory acc = accounts[user];
        if (!acc.isVerified) return 0;

        uint256 currentYear = getCurrentYear();
        uint256 fedBase = getLatestFedBase(currentYear);
        uint256 stateBase = getLatestStateBase(acc.stateId, currentYear);

        return fedBase + stateBase;
    }

    function getAvailableBalance(address user) public view returns (int256) {
        AccountInfo memory acc = accounts[user];
        if (!acc.isVerified) return 0;

        uint256 grossBase = getGrossBase(user);
        return int256(grossBase) - int256(acc.netWithdrawals);
    }

    function withdraw(uint256 amount) external nonReentrant {
        int256 available = getAvailableBalance(msg.sender);
        require(available >= int256(amount), "GenesisIssuance: Insufficient net available balance");

        accounts[msg.sender].netWithdrawals += amount;

        int256 remaining = getAvailableBalance(msg.sender);
        emit WithdrawalExecuted(msg.sender, amount, remaining);
    }
}
