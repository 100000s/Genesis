// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGenesisToken { function mint(address to, uint256 amount) external; }
interface IGenesisIdentity { function canClaim(address account, uint8 kind) external view returns (bool); }
interface IGenesisOracleRatios { function federalRatio(uint256) external view returns (uint256, bytes32, bool); function stateRatio(uint8,uint256) external view returns (uint256, bytes32, bool); function getDynamicIssuanceRateBps() external view returns (uint256); }

contract GenesisIssuance {
    uint256 public constant WAD = 1e18;
    uint256 public constant BASE_CLAIM = 50 * WAD;
    uint256 public constant LAUNCH_YEAR = 2026;
    uint256 public constant BOOTSTRAP_WITHDRAWALS = 100;
    uint256 public constant BOOTSTRAP_MAX_CLAIM = 100 * WAD;
    uint256 public constant BOOTSTRAP_SUPPLY_CAP = 20_000 * WAD;
    uint256 public constant FEDERAL = 0;
    uint256 public constant STATE = 1;
    address public owner; IGenesisToken public immutable token; IGenesisIdentity public immutable identity; IGenesisOracleRatios public immutable oracle;
    address public workerSplit; uint256 public bootstrapWithdrawals; uint256 public bootstrapMinted;
    mapping(uint256 => uint256) public federalBase; mapping(uint8 => mapping(uint256 => uint256)) public stateBase;
    mapping(address => uint256) public claimedFederal; mapping(address => uint256) public claimedState; mapping(address => uint256) public workerMinted;
    mapping(uint256 => bool) public federalRatioApplied; mapping(uint8 => mapping(uint256 => bool)) public stateRatioApplied;
    mapping(uint256 => uint256) public monthVolume; mapping(uint256 => uint256) public weekVolume;
    event ClaimMinted(address indexed claimant,uint8 indexed kind,uint256 indexed year,uint256 amount); event RatioApplied(uint256 indexed year,uint8 indexed stateId,uint256 ratio);
    modifier onlyOwner(){require(msg.sender==owner,"Issuance: owner only");_;} modifier onlyWorker(){require(msg.sender==workerSplit,"Issuance: worker only");_;}
    constructor(address tokenAddress,address identityAddress,address oracleAddress){require(tokenAddress!=address(0)&&identityAddress!=address(0)&&oracleAddress!=address(0),"Issuance: zero"); owner=msg.sender; token=IGenesisToken(tokenAddress); identity=IGenesisIdentity(identityAddress); oracle=IGenesisOracleRatios(oracleAddress); federalBase[LAUNCH_YEAR]=BASE_CLAIM;}
    function setWorkerSplit(address worker) external onlyOwner { require(worker!=address(0),"Issuance: zero"); workerSplit=worker; }
    function currentYear() public view returns(uint256){ return block.timestamp < 1767225600 ? LAUNCH_YEAR : LAUNCH_YEAR + (block.timestamp-1767225600)/365 days; }
    function _apply(uint256 year,uint8 stateId) internal { if(year<=LAUNCH_YEAR)return; if(!federalRatioApplied[year]) { (uint256 r,,bool set)=oracle.federalRatio(year); require(set,"Issuance: federal ratio missing"); federalBase[year]=federalBase[year-1]*r/WAD; federalRatioApplied[year]=true; emit RatioApplied(year,0,r); } if(!stateRatioApplied[stateId][year]) { (uint256 r,,bool set)=oracle.stateRatio(stateId,year); require(set,"Issuance: state ratio missing"); uint256 prior=stateBase[stateId][year-1]; if(prior==0)prior=BASE_CLAIM; stateBase[stateId][year]=prior*r/WAD; stateRatioApplied[stateId][year]=true; emit RatioApplied(year,stateId,r); } }
    function setStateBaseForBootstrap(uint8 stateId) external onlyOwner { require(stateId>0&&stateId<=50,"Issuance: state"); if(stateBase[stateId][LAUNCH_YEAR]==0) stateBase[stateId][LAUNCH_YEAR]=BASE_CLAIM; }
    function available(address account,uint8 kind,uint8 stateId) public view returns(uint256){ if(!identity.canClaim(account,kind))return 0; uint256 year=currentYear(); if(kind==FEDERAL)return federalBase[year]-claimedFederal[account]; if(kind==STATE){uint256 base=stateBase[stateId][year]; if(base==0)base=BASE_CLAIM; return base-claimedState[account];} return 0; }
    function withdraw(uint8 kind,uint8 stateId,uint256 amount) external { require(kind==FEDERAL||kind==STATE&&stateId>0&&stateId<=50,"Issuance: kind"); require(amount>0&&amount<=available(msg.sender,kind,stateId),"Issuance: unavailable"); uint256 cap=bootstrapWithdrawals<BOOTSTRAP_WITHDRAWALS?BOOTSTRAP_MAX_CLAIM:monthCap(); require(amount<=cap,"Issuance: cap"); if(kind==FEDERAL){_apply(currentYear(),stateId);claimedFederal[msg.sender]+=amount;}else{_apply(currentYear(),stateId);claimedState[msg.sender]+=amount;} if(bootstrapWithdrawals<BOOTSTRAP_WITHDRAWALS){require(bootstrapMinted+amount<=BOOTSTRAP_SUPPLY_CAP,"Issuance: bootstrap supply");bootstrapWithdrawals++;bootstrapMinted+=amount;} monthVolume[month()] += amount; weekVolume[week()] += amount; token.mint(msg.sender,amount); emit ClaimMinted(msg.sender,kind,currentYear(),amount); }
    function month() public view returns(uint256){return block.timestamp/30 days;} function week() public view returns(uint256){return block.timestamp/7 days;}
    function monthCap() public view returns(uint256){uint256 prior=monthVolume[month()-1]; if(prior==0)return 10*WAD; uint256 cap=prior*1005/1000; uint256 high=prior; for(uint256 i=2;i<=12;i++)if(monthVolume[month()-i]>high)high=monthVolume[month()-i]; return cap>high?cap:high;}
    function mintWorkerReward(address recipient,uint256 amount) external onlyWorker {require(recipient!=address(0)&&amount>0,"Issuance: reward");workerMinted[recipient]+=amount;token.mint(recipient,amount);emit ClaimMinted(recipient,2,currentYear(),amount);}
}
