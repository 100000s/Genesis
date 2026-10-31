import { ethers } from 'ethers';

export type ContractKey =
  | 'GenesisToken'
  | 'GenesisIssuance'
  | 'WorkerSplit'
  | 'GenesisGovernance'
  | 'AppTeamDAO'
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

export const DEFAULT_CONTRACTS: Record<ContractKey, ContractConfig> = {
  GenesisToken: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisToken',
    description: 'ERC-20 compatible token and mint authority',
    methods: ['balanceOf(address)', 'symbol()', 'totalSupply()', 'allowance(address,address)']
  },
  GenesisIssuance: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisIssuance',
    description: 'Claim and issuance ledger for citizenship and state budgets',
    methods: ['availableFederal(address)', 'availableState(address,uint8)', 'withdraw(uint8,uint8,uint256)']
  },
  WorkerSplit: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'WorkerSplit',
    description: 'Epoch-based worker and app team distribution',
    methods: ['epoch()', 'recordActivity(uint256)', 'finalizeEpoch()', 'claim(uint64,uint8)']
  },
  GenesisGovernance: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisGovernance',
    description: 'GIP proposal voting and governance activation gating',
    methods: ['propose(bytes32,uint8,bytes32,bytes32)', 'vote(bytes32,bool,uint256)', 'resolve(bytes32)']
  },
  AppTeamDAO: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'AppTeamDAO',
    description: 'App team governance and category allocation',
    methods: ['getCurrentCycle()', 'allocate(uint8,address,uint256)', 'claim(uint8)']
  },
  GenesisEscrow: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisEscrow',
    description: 'Canonical escrow and dispute arbitration',
    methods: ['createEscrow(address,uint256,bytes32,uint64)', 'fulfillEscrow(uint256,bytes)', 'triggerDefault(uint256)']
  },
  GenesisIdentityRegistry: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisIdentityRegistry',
    description: 'Soulbound identity verification and credential routing',
    methods: ['registerIdentity(uint16,bytes32,bytes32,bytes)', 'registerCredential(address,uint8,bytes32,bytes32,bytes)', 'canClaim(address,uint8)']
  },
  GenesisValidatorRegistry: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisValidatorRegistry',
    description: 'Validator identity, hardware, and staking registry',
    methods: ['register(bytes32,bytes32,bytes32)', 'registerValidator(address,string)', 'count()']
  },
  GenesisOracle: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisOracle',
    description: 'Native TWAP and fiscal-ratio oracle feed',
    methods: ['getTwapPrice()', 'getTwapMultiplier()', 'getDynamicIssuanceRateBps()']
  },
  GenesisNoteRegistry: {
    address: '0x0000000000000000000000000000000000000000',
    name: 'GenesisNoteRegistry',
    description: 'Physical-note metadata, issuance, and scan tracking',
    methods: ['issue(bytes32,uint256,bytes32,(uint256,bytes32,bytes32,bytes32,bytes32,uint64,bytes32,bytes32,uint64,bytes32,uint16))']
  }
};

export const CONTRACT_ORDER: ContractKey[] = [
  'GenesisToken',
  'GenesisIssuance',
  'WorkerSplit',
  'GenesisGovernance',
  'AppTeamDAO',
  'GenesisEscrow',
  'GenesisIdentityRegistry',
  'GenesisValidatorRegistry',
  'GenesisOracle',
  'GenesisNoteRegistry'
];

export function getRuntimeContracts(): Record<ContractKey, ContractConfig> {
  const values = Object.fromEntries(
    CONTRACT_ORDER.map((key) => {
      const envKey = `VITE_${key.toUpperCase()}_ADDRESS`;
      const value = (import.meta.env[envKey] as string | undefined) || DEFAULT_CONTRACTS[key].address;
      return [key, { ...DEFAULT_CONTRACTS[key], address: value }];
    })
  ) as Record<ContractKey, ContractConfig>;

  return values;
}

export function getEthersProvider() {
  if (!window.ethereum) return null;
  return new ethers.BrowserProvider(window.ethereum as any);
}

export function createContract(address: string, abi: any[]) {
  const provider = getEthersProvider();
  if (!provider) return null;
  return new ethers.Contract(address, abi, provider);
}
