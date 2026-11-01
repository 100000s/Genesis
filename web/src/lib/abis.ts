export const ABI_MAP = {
  GenesisToken: [
    'function balanceOf(address) view returns (uint256)',
    'function symbol() view returns (string)',
    'function totalSupply() view returns (uint256)',
    'function decimals() view returns (uint8)'
  ],
  GenesisIssuance: [
    'function availableFederal(address) view returns (uint256)',
    'function availableState(address,uint8) view returns (uint256)',
    'function currentYear() view returns (uint256)',
    'function currentEpoch() view returns (uint256)',
    'function withdraw(uint8,uint8,uint256) returns ()'
  ],
  WorkerSplit: [
    'function epoch() view returns (uint64)',
    'function activity() view returns (uint256)',
    'function participantCount(uint8) view returns (uint256)',
    'function getMembers(uint8) view returns (address[])'
  ],
  GenesisGovernance: [
    'function getBootstrapStatus() view returns (uint256,uint256,bool,bool)',
    'function getProposal(bytes32) view returns (tuple(bytes32 id, uint8 track, address proposer, bytes32 specificationHash, bytes32 ordinalHash, uint64 createdAt, uint64 lastCallEnds, uint8 status))',
    'function computeWeightedSignals(bytes32) view returns (bool)'
  ],
  AppTeamDAO: [
    'function getCurrentCycle() view returns (uint64)',
    'function getCategoryPool(uint8) view returns (uint256)',
    'function getPendingReward(uint8,address) view returns (uint256)'
  ],
  GenesisEscrow: [
    'function nextEscrowId() view returns (uint256)',
    'function nextPurchaseId() view returns (uint256)',
    'function isVerifiedArbitrator(address) view returns (bool)'
  ],
  GenesisIdentityRegistry: [
    'function getJurisdiction(address) view returns (uint16)',
    'function canClaim(address,uint8) view returns (bool)',
    'function hasCredential(address,uint8) view returns (bool)'
  ],
  GenesisValidatorRegistry: [
    'function count() view returns (uint256)',
    'function getValidatorCount() view returns (uint256)',
    'function getActiveValidators() view returns (address[])'
  ],
  GenesisOracle: [
    'function getTwapPrice() view returns (uint256)',
    'function getTwapMultiplier() view returns (uint256)',
    'function getDynamicIssuanceRateBps() view returns (uint256)'
  ],
  GenesisNoteRegistry: [
    'function issued(bytes32) view returns (bool)',
    'function metadata(bytes32) view returns (uint256,bytes32,bytes32,bytes32,bytes32,uint64,bytes32,bytes32,uint64,bytes32,uint16)'
  ]
} as const;

export type ContractAbiKey = keyof typeof ABI_MAP;
