// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGenesisToken { function mint(address to, uint256 amount) external; }
interface IGenesisIdentity { function canClaim(address account, uint8 kind) external view returns (bool); }

contract GenesisIssuance {
    uint256 public constant WAD = 1e18;
    uint256 public constant BASE_CLAIM = 50 * WAD;
    uint256 public constant LAUNCH_YEAR = 2026;
    uint256 public constant CLAIM_WINDOW = 365 days;
    uint8 public constant FEDERAL = 0;
    uint8 public constant STATE = 1;
    uint8 public constant WORKER = 2;
    address public owner;
    IGenesisToken public immutable token;
    IGenesisIdentity public immutable identity;
    address public workerSplit;
    mapping(uint256 => uint256) public federalBase;
    mapping(uint8 => mapping(uint256 => uint256)) public stateBase;
    mapping(address => uint256) public claimedFederal;
    mapping(address => uint256) public claimedState;
    mapping(address => uint256) public workerMinted;
    mapping(uint256 => bool) public federalRatioSet;
    mapping(uint8 => mapping(uint256 => bool)) public stateRatioSet;

    event ClaimMinted(address indexed claimant, uint8 indexed kind, uint256 year, uint256 amount);
    event FederalBaseUpdated(uint256 indexed year, uint256 amount);
    event StateBaseUpdated(uint8 indexed stateId, uint256 indexed year, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "GenesisIssuance: owner only"); _; }
    modifier onlyWorkerSplit() { require(msg.sender == workerSplit, "GenesisIssuance: WorkerSplit only"); _; }

    constructor(address tokenAddress, address identityAddress) {
        require(tokenAddress != address(0) && identityAddress != address(0), "GenesisIssuance: zero address");
        owner = msg.sender;
        token = IGenesisToken(tokenAddress);
        identity = IGenesisIdentity(identityAddress);
        federalBase[LAUNCH_YEAR] = BASE_CLAIM;
    }

    function setWorkerSplit(address worker) external onlyOwner { require(worker != address(0), "GenesisIssuance: zero address"); workerSplit = worker; }

    function setFederalBase(uint256 year, uint256 amount) external onlyOwner {
        require(year >= LAUNCH_YEAR && amount > 0, "GenesisIssuance: invalid base");
        federalBase[year] = amount;
        emit FederalBaseUpdated(year, amount);
    }

    function setStateBase(uint8 stateId, uint256 year, uint256 amount) external onlyOwner {
        require(stateId > 0 && stateId <= 50 && year >= LAUNCH_YEAR && amount > 0, "GenesisIssuance: invalid base");
        stateBase[stateId][year] = amount;
        emit StateBaseUpdated(stateId, year, amount);
    }

    function claim(uint8 kind, uint8 stateId) external {
        require(kind == FEDERAL || kind == STATE, "GenesisIssuance: invalid claim");
        require(identity.canClaim(msg.sender, kind), "GenesisIssuance: identity ineligible");
        uint256 year = currentYear();
        if (kind == FEDERAL) {
            uint256 amount = federalBase[year];
            require(claimedFederal[msg.sender] < amount, "GenesisIssuance: federal claimed");
            uint256 remaining = amount - claimedFederal[msg.sender];
            claimedFederal[msg.sender] = amount;
            token.mint(msg.sender, remaining);
            emit ClaimMinted(msg.sender, kind, year, remaining);
        } else {
            require(stateId > 0 && stateId <= 50, "GenesisIssuance: invalid state");
            uint256 amount = stateBase[stateId][year];
            if (amount == 0) amount = BASE_CLAIM;
            require(claimedState[msg.sender] < amount, "GenesisIssuance: state claimed");
            uint256 remaining = amount - claimedState[msg.sender];
            claimedState[msg.sender] = amount;
            token.mint(msg.sender, remaining);
            emit ClaimMinted(msg.sender, kind, year, remaining);
        }
    }

    function mintWorkerReward(address recipient, uint256 amount) external onlyWorkerSplit {
        require(recipient != address(0) && amount > 0, "GenesisIssuance: invalid reward");
        workerMinted[recipient] += amount;
        token.mint(recipient, amount);
        emit ClaimMinted(recipient, WORKER, currentYear(), amount);
    }

    function currentYear() public view returns (uint256) {
        if (block.timestamp < 1767225600) return LAUNCH_YEAR;
        return LAUNCH_YEAR + (block.timestamp - 1767225600) / CLAIM_WINDOW;
    }
}