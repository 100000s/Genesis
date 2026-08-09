// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GenesisIssuance
 * @notice Manages per-capita dynamic GenToken allocations adjusted annually by budget ratios.
 * @dev Replaces available balances on January 1st based on fiscal receipt changes.
 */
contract GenesisIssuance {
    uint256 public constant WAD = 1e18;
    uint256 public constant BASE_ALLOCATION = 50 * WAD; // 50 tokens baseline (2026)
    uint256 public constant LAUNCH_YEAR = 2026;

    address public owner;
    address public oracle;

    // Federal annual multiplier per year (Year => Multiplier in WAD)
    // Year 2026 starts at 1.0 (1e18)
    mapping(uint256 => uint256) public fedAnnualBase;

    // State annual multiplier per year per state (StateID => Year => Base in WAD)
    mapping(uint8 => mapping(uint256 => uint256)) public stateAnnualBase;

    struct AccountInfo {
        uint8 stateId;            // State residency ID (1 to 50)
        bool isVerified;          // Verified via GenCreds ZK Proof
        uint256 netWithdrawals;   // Cumulative tokens withdrawn/spent
    }

    mapping(address => AccountInfo) public accounts;

    event RatiosUpdated(uint256 indexed year, uint256 fedBase, uint8 stateId, uint256 stateBase);
    event WithdrawalExecuted(address indexed user, uint256 amount, int256 remainingBalance);

    modifier onlyOwner() {
        require(msg.sender == owner, "GenesisIssuance: Caller is not owner");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "GenesisIssuance: Caller is not oracle");
        _;
    }

    constructor(address _oracle) {
        owner = msg.sender;
        oracle = _oracle;

        // Initialize 2026 baseline allocations (50 Fed + 50 State = 100 GEN Total)
        fedAnnualBase[LAUNCH_YEAR] = BASE_ALLOCATION;
    }

    /**
     * @notice Registers or updates verified state residency for a user via ZK-SBT verification.
     */
    function registerResident(address user, uint8 stateId) external onlyOwner {
        require(stateId >= 1 && stateId <= 50, "GenesisIssuance: Invalid State ID");
        accounts[user].stateId = stateId;
        accounts[user].isVerified = true;

        // Ensure state baseline is initialized for 2026
        if (stateAnnualBase[stateId][LAUNCH_YEAR] == 0) {
            stateAnnualBase[stateId][LAUNCH_YEAR] = BASE_ALLOCATION;
        }
    }

    /**
     * @notice Sets the newly calculated base for Federal or State stream on Jan 1st.
     * @param year Current year (>= 2027)
     * @param fedRatio Ratio in WAD: Receipts(FY t-3) / Receipts(FY t-2)
     * @param stateId State ID (1-50)
     * @param stateRatio Ratio in WAD for the given state
     */
    function updateAnnualRatios(
        uint256 year,
        uint256 fedRatio,
        uint8 stateId,
        uint256 stateRatio
    ) external onlyOracle {
        require(year > LAUNCH_YEAR, "GenesisIssuance: Adjustments begin in 2027");

        // Compute federal base: Base(t) = Base(t-1) * Ratio
        uint256 prevFedBase = fedAnnualBase[year - 1] > 0 ? fedAnnualBase[year - 1] : BASE_ALLOCATION;
        fedAnnualBase[year] = (prevFedBase * fedRatio) / WAD;

        // Compute state base: StateBase(t) = StateBase(t-1) * StateRatio
        uint256 prevStateBase = stateAnnualBase[stateId][year - 1] > 0 
            ? stateAnnualBase[stateId][year - 1] 
            : BASE_ALLOCATION;
            
        stateAnnualBase[stateId][year] = (prevStateBase * stateRatio) / WAD;

        emit RatiosUpdated(year, fedAnnualBase[year], stateId, stateAnnualBase[stateId][year]);
    }

    /**
     * @notice Calculates the real-time gross base balance available for a specific year.
     */
    function getGrossBase(address user, uint256 currentYear) public view returns (uint256) {
        AccountInfo memory acc = accounts[user];
        if (!acc.isVerified) return 0;

        uint256 fedBase = fedAnnualBase[currentYear];
        if (fedBase == 0 && currentYear > LAUNCH_YEAR) {
            fedBase = fedAnnualBase[LAUNCH_YEAR]; // Fallback to last known base if oracle delay
        }

        uint256 stateBase = stateAnnualBase[acc.stateId][currentYear];
        if (stateBase == 0 && currentYear > LAUNCH_YEAR) {
            stateBase = stateAnnualBase[acc.stateId][LAUNCH_YEAR];
        }

        return fedBase + stateBase;
    }

    /**
     * @notice Returns the available net spendable balance (can be negative).
     * @dev Available = GrossBase(CurrentYear) - NetWithdrawals
     */
    function getAvailableBalance(address user, uint256 currentYear) public view returns (int256) {
        AccountInfo memory acc = accounts[user];
        if (!acc.isVerified) return 0;

        uint256 grossBase = getGrossBase(user, currentYear);
        return int256(grossBase) - int256(acc.netWithdrawals);
    }

    /**
     * @notice Executes a withdrawal or transfer attempt.
     */
    function withdraw(uint256 amount, uint256 currentYear) external {
        int256 available = getAvailableBalance(msg.sender, currentYear);

        require(available >= int256(amount), "GenesisIssuance: Insufficient net available balance");

        // Debit account
        accounts[msg.sender].netWithdrawals += amount;

        int256 remaining = getAvailableBalance(msg.sender, currentYear);
        emit WithdrawalExecuted(msg.sender, amount, remaining);

        // Standard ERC-20 transfer out logic here...
    }
}
