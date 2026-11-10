export const ABI_MAP = {
  GenesisToken: [
    'function balanceOf(address) view returns (uint256)',
    'function symbol() view returns (string)',
    'function totalSupply() view returns (uint256)',
    'function decimals() view returns (uint8)',
    'function allowance(address,address) view returns (uint256)',
    'function approve(address,uint256) returns (bool)',
    'function transfer(address,uint256) returns (bool)'
  ],
  GenesisIssuance: [
    'function availableFederal(address) view returns (uint256)',
    'function availableState(address,uint8) view returns (uint256)',
    'function currentYear() view returns (uint256)',
    'function currentEpoch() view returns (uint256)',
    'function LAUNCH_CLAIM_END() view returns (uint256)',
    'function getIndividualDailyLimit() view returns (uint256)',
    'function withdraw(uint8,uint8,uint256)',
    'event ClaimMinted(address indexed claimant,uint8 indexed kind,uint256 indexed year,uint256 amount)'
  ],
  WorkerSplit: [
    'function epoch() view returns (uint64)',
    'function epochStart() view returns (uint64)',
    'function activity() view returns (uint256)',
    'function pool(uint64,uint8) view returns (uint256)',
    'function epochFinalized(uint64) view returns (bool)',
    'function contributionWeight(uint64,uint8,address) view returns (uint256)',
    'function totalContributionWeight(uint64,uint8) view returns (uint256)',
    'function participantCount(uint8) view returns (uint256)',
    'function getMembers(uint8) view returns (address[])',
    'function claim(uint64,uint8)',
    'function distributeBootstrap()',
    'event EpochFinalized(uint64 indexed epoch,uint256 workerPool,uint256 dynamicRateBps,uint256 twapMul)',
    'event RewardClaimed(uint64 indexed epoch,uint8 indexed kind,address indexed member,uint256 amount)'
  ],
  GenesisGovernance: [
    'function getBootstrapStatus() view returns (uint256,uint256,bool,bool)',
    'function getProposal(bytes32) view returns (tuple(bytes32 id,uint8 track,address proposer,bytes32 specificationHash,bytes32 ordinalHash,uint64 createdAt,uint64 lastCallEnds,uint8 status))',
    'function computeWeightedSignals(bytes32) view returns (bool)',
    'function propose(bytes32,uint8,bytes32,bytes32)',
    'function vote(bytes32,bool,uint256)',
    'function resolve(bytes32)',
    'function activate(bytes32)'
  ],
  AppTeamDAO: [
    'function getCurrentCycle() view returns (uint64)',
    'function credits(address) view returns (uint256)',
    'function appTeamProposalActivated(bytes32) view returns (bool)',
    'function propose(bytes32)',
    'function vote(bytes32,bool,uint256)',
    'function execute(bytes32)'
  ],
  AppTeamRewardDistributor: [
    'function epochFinalized(uint64) view returns (bool)',
    'function fundingByEpoch(uint64) view returns (uint256)',
    'function technologyPool(uint64,uint8) view returns (uint256)',
    'function contributionWeight(uint64,uint8,address) view returns (uint256)',
    'function contributionTotal(uint64,uint8) view returns (uint256)',
    'function claimed(uint64,uint8,address) view returns (bool)',
    'function claim(uint64,uint8)',
    'function technologyAllocationBps(uint8) view returns (uint16)',
    'event RewardClaimed(uint64 indexed epoch,uint8 indexed technology,address indexed contributor,uint256 amount)'
  ],
  NoteTeamRewardDistributor: [
    'function finalized(uint64) view returns (bool)',
    'function fundingByEpoch(uint64) view returns (uint256)',
    'function hardwarePool(uint64) view returns (uint256)',
    'function presencePool(uint64) view returns (uint256)',
    'function newOperatorCount(uint64) view returns (uint256)',
    'function activityWeight(uint64,bytes32) view returns (uint256)',
    'function payoutAddress(bytes32) view returns (address)',
    'function claimHardware(uint64,bytes32)',
    'function claimPresence(uint64,bytes32)',
    'event HardwareClaimed(uint64 indexed epoch,bytes32 indexed operator,address recipient,uint256 amount)',
    'event PresenceClaimed(uint64 indexed epoch,bytes32 indexed operator,address recipient,uint256 amount)'
  ],
  NoteTeamDAO: [
    'function treasuryBalance() view returns (uint256)',
    'function nextProposalId() view returns (uint256)',
    'function proposals(uint256) view returns (address proposer,address recipient,uint128 amount,uint64 deadline,bytes32 metadataHash,uint8 state)',
    'function createProposal(address,uint128,uint64,bytes32) returns (uint256)',
    'function reviewProposal(uint256,bool)',
    'function approveProposal(uint256)',
    'function executeGrant(uint256)',
    'function verifyCompletion(uint256,bytes32)'
  ],
  GenesisEscrow: [
    'function nextEscrowId() view returns (uint256)',
    'function nextPurchaseId() view returns (uint256)',
    'function isVerifiedArbitrator(address) view returns (bool)',
    'function createEscrow(address,uint256,bytes32,uint64) returns (uint256)',
    'function fulfillEscrow(uint256,bytes)',
    'function triggerDefault(uint256)',
    'function initiateSecurePurchase(address,uint256,uint256,uint64) returns (uint256)',
    'function castArbitrationVote(uint256,bool)',
    'event EscrowSettled(uint256 indexed id,address indexed recipient,uint256 itemValue,uint256 feePaid)'
  ],
  GenesisIdentityRegistry: [
    'function getJurisdiction(address) view returns (uint16)',
    'function canClaim(address,uint8) view returns (bool)',
    'function hasCredential(address,uint8) view returns (bool)',
    'function identities(address) view returns (bool active,uint16 jurisdiction,bytes32 fingerprintCommitment,uint64 issuedAt)',
    'function registerIdentity(uint16,bytes32,bytes32,bytes)',
    'function registerCredential(address,uint8,bytes32,bytes32,bytes)'
  ],
  GenesisValidatorRegistry: [
    'function count() view returns (uint256)',
    'function getValidatorCount() view returns (uint256)',
    'function getActiveValidators() view returns (address[])',
    'function validators(address) view returns (bytes32 identityCommitment,bytes32 hardwareCommitment,bytes32 geography,uint64 registeredAt,bool active,uint256 stakedAmount,bytes consensusPubKey)',
    'function register(bytes32,bytes32,bytes32)',
    'function registerValidator(bytes,uint256)',
    'function deregisterValidator()'
  ],
  GenesisOracle: [
    'function getTwapPrice() view returns (uint256)',
    'function getTwapMultiplier() view returns (uint256)',
    'function getDynamicIssuanceRateBps() view returns (uint256)',
    'function getBaseGrowthMultiplier() view returns (uint256)',
    'function federalRatio(uint256) view returns (uint256,bytes32,bool)',
    'function stateRatio(uint8,uint256) view returns (uint256,bytes32,bool)'
  ],
  GenesisNoteRegistry: [
    'function issued(bytes32) view returns (bool)',
    'function metadata(bytes32) view returns (uint256,bytes32,bytes32,bytes32,bytes32,uint64,bytes32,bytes32,uint64,bytes32,uint16)',
    'function recordScan(bytes32,bytes32,uint64,bytes32,uint16)',
    'function replace(bytes32,bytes32)'
  ]
} as const;

export type ContractAbiKey = keyof typeof ABI_MAP;
