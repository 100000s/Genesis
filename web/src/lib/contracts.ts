import { ethers } from 'ethers';

declare global {
  interface Window {
    ethereum?: ethers.Eip1193Provider;
  }
}

export type ContractKey =
  | 'GenesisToken'
  | 'GenesisIssuance'
  | 'WorkerSplit'
  | 'GenesisGovernance'
  | 'AppTeamDAO'
  | 'AppTeamRewardDistributor'
  | 'NoteTeamRewardDistributor'
  | 'NoteTeamDAO'
  | 'GenesisEscrow'
  | 'GenesisIdentityRegistry'
  | 'GenesisValidatorRegistry'
  | 'GenesisOracle'
  | 'GenesisNoteRegistry';

export type ContractConfig = {
  address: string;
  name: string;
  description: string;
  methods: string[];
};

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

export const DEFAULT_CONTRACTS: Record<ContractKey, ContractConfig> = {
  GenesisToken: {
    address: ZERO_ADDRESS,
    name: 'GenesisToken',
    description: 'Genesis ERC-20-compatible token and mint authority',
    methods: ['balanceOf(address)', 'symbol()', 'totalSupply()', 'allowance(address,address)', 'approve(address,uint256)', 'transfer(address,uint256)']
  },
  GenesisIssuance: {
    address: ZERO_ADDRESS,
    name: 'GenesisIssuance',
    description: 'Citizen/resident claim ledger and ALFRED-adjusted issuance',
    methods: ['availableFederal(address)', 'availableState(address,uint8)', 'currentYear()', 'LAUNCH_CLAIM_END()', 'withdraw(uint8,uint8,uint256)']
  },
  WorkerSplit: {
    address: ZERO_ADDRESS,
    name: 'WorkerSplit',
    description: 'Monthly epoch authority for 20/20/30/20/10 reward allocations',
    methods: ['epoch()', 'pool(uint64,uint8)', 'claim(uint64,uint8)', 'participantCount(uint8)', 'distributeBootstrap()']
  },
  GenesisGovernance: {
    address: ZERO_ADDRESS,
    name: 'GenesisGovernance',
    description: 'Genesis Improvement Proposal lifecycle and weighted governance',
    methods: ['getBootstrapStatus()', 'getProposal(bytes32)', 'propose(bytes32,uint8,bytes32,bytes32)', 'vote(bytes32,bool,uint256)', 'resolve(bytes32)', 'activate(bytes32)']
  },
  AppTeamDAO: {
    address: ZERO_ADDRESS,
    name: 'AppTeamDAO',
    description: 'App Team governance and contribution coordination; reward claims are handled by AppTeamRewardDistributor',
    methods: ['getCurrentCycle()', 'credits(address)', 'propose(bytes32)', 'vote(bytes32,bool,uint256)', 'execute(bytes32)']
  },
  AppTeamRewardDistributor: {
    address: ZERO_ADDRESS,
    name: 'AppTeamRewardDistributor',
    description: 'App technology utilization-gated, contribution-weighted rewards',
    methods: ['technologyPool(uint64,uint8)', 'contributionWeight(uint64,uint8,address)', 'claim(uint64,uint8)', 'technologyAllocationBps(uint8)']
  },
  NoteTeamRewardDistributor: {
    address: ZERO_ADDRESS,
    name: 'NoteTeamRewardDistributor',
    description: 'Note Team 10% hardware, 8% active presence, and 2% maintenance rewards',
    methods: ['hardwarePool(uint64)', 'presencePool(uint64)', 'claimHardware(uint64,bytes32)', 'claimPresence(uint64,bytes32)']
  },
  NoteTeamDAO: {
    address: ZERO_ADDRESS,
    name: 'NoteTeamDAO',
    description: 'Open-ended governance of the Note Team maintenance allocation only',
    methods: ['treasuryBalance()', 'createProposal(address,uint128,uint64,bytes32)', 'reviewProposal(uint256,bool)', 'approveProposal(uint256)', 'executeGrant(uint256)', 'verifyCompletion(uint256,bytes32)']
  },
  GenesisEscrow: {
    address: ZERO_ADDRESS,
    name: 'GenesisEscrow',
    description: 'Genesis escrow and arbitration settlement',
    methods: ['nextEscrowId()', 'nextPurchaseId()', 'createEscrow(address,uint256,bytes32,uint64)', 'fulfillEscrow(uint256,bytes)', 'triggerDefault(uint256)', 'initiateSecurePurchase(address,uint256,uint256,uint64)', 'castArbitrationVote(uint256,bool)']
  },
  GenesisIdentityRegistry: {
    address: ZERO_ADDRESS,
    name: 'GenesisIdentityRegistry',
    description: 'Identity and ZK credential registry for claim eligibility',
    methods: ['identities(address)', 'canClaim(address,uint8)', 'hasCredential(address,uint8)', 'getJurisdiction(address)', 'registerIdentity(uint16,bytes32,bytes32,bytes)']
  },
  GenesisValidatorRegistry: {
    address: ZERO_ADDRESS,
    name: 'GenesisValidatorRegistry',
    description: 'Validator identity, hardware, geography, and active status registry',
    methods: ['count()', 'getActiveValidators()', 'validators(address)', 'register(bytes32,bytes32,bytes32)']
  },
  GenesisOracle: {
    address: ZERO_ADDRESS,
    name: 'GenesisOracle',
    description: 'TWAP and immutable ALFRED budget-ratio oracle',
    methods: ['getTwapPrice()', 'getTwapMultiplier()', 'getDynamicIssuanceRateBps()', 'federalRatio(uint256)', 'stateRatio(uint8,uint256)']
  },
  GenesisNoteRegistry: {
    address: ZERO_ADDRESS,
    name: 'GenesisNoteRegistry',
    description: 'Physical note issuance, scan, and replacement metadata',
    methods: ['issued(bytes32)', 'metadata(bytes32)', 'recordScan(bytes32,bytes32,uint64,bytes32,uint16)']
  }
};

export const CONTRACT_ORDER: ContractKey[] = [
  'GenesisToken',
  'GenesisIssuance',
  'WorkerSplit',
  'GenesisGovernance',
  'AppTeamDAO',
  'AppTeamRewardDistributor',
  'NoteTeamRewardDistributor',
  'NoteTeamDAO',
  'GenesisEscrow',
  'GenesisIdentityRegistry',
  'GenesisValidatorRegistry',
  'GenesisOracle',
  'GenesisNoteRegistry'
];

export function getRuntimeContracts(): Record<ContractKey, ContractConfig> {
  return Object.fromEntries(
    CONTRACT_ORDER.map((key) => {
      const envKey = `VITE_${key.toUpperCase()}_ADDRESS`;
      const value = (import.meta.env[envKey] as string | undefined) || DEFAULT_CONTRACTS[key].address;
      return [key, { ...DEFAULT_CONTRACTS[key], address: value }];
    })
  ) as Record<ContractKey, ContractConfig>;
}

/** Optional expected EVM chain ID, supplied by deployment environment. */
export function getExpectedChainId(): bigint | null {
  const configured = import.meta.env.VITE_GENESIS_CHAIN_ID as string | undefined;
  if (!configured) return null;
  try {
    return BigInt(configured);
  } catch {
    throw new Error('VITE_GENESIS_CHAIN_ID must be an integer chain ID');
  }
}

export function getEthersProvider(): ethers.BrowserProvider | null {
  if (!window.ethereum) return null;
  return new ethers.BrowserProvider(window.ethereum);
}

export function createContract(address: string, abi: ethers.InterfaceAbi) {
  const provider = getEthersProvider();
  if (!provider) return null;
  return new ethers.Contract(address, abi, provider);
}
