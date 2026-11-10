import { ethers } from 'ethers';
import { ABI_MAP, type ContractAbiKey } from '../lib/abis';
import { getEthersProvider, getExpectedChainId, getRuntimeContracts, type ContractKey } from '../lib/contracts';

export async function ensureWalletSigner() {
  const provider = getEthersProvider();
  if (!provider) throw new Error('Wallet provider unavailable');
  const signer = await provider.getSigner();
  return { provider, signer };
}

export function getContractInstance(contractKey: ContractKey) {
  const address = getRuntimeContracts()[contractKey].address;
  const provider = getEthersProvider();
  if (!address || address === ethers.ZeroAddress) return null;
  if (!provider) return null;
  return new ethers.Contract(address, ABI_MAP[contractKey as ContractAbiKey], provider);
}

export async function readContract<T = unknown>(contractKey: ContractKey, method: string, args: unknown[] = []) {
  const contract = getContractInstance(contractKey);
  if (!contract) return null;
  if (typeof contract[method] !== 'function') throw new Error(`Method ${method} not found on ${contractKey}`);
  return (await contract[method](...args)) as T;
}

export async function writeContract(contractKey: ContractKey, method: string, args: unknown[] = []) {
  const { provider, signer } = await ensureWalletSigner();
  const expectedChainId = getExpectedChainId();
  if (expectedChainId !== null) {
    const network = await provider.getNetwork();
    if (network.chainId !== expectedChainId) {
      throw new Error(`Wrong network: connected to chain ${network.chainId}; Genesis requires chain ${expectedChainId}.`);
    }
  }

  const address = getRuntimeContracts()[contractKey].address;
  if (!address || address === ethers.ZeroAddress) throw new Error(`No deployed address configured for ${contractKey}`);
  if (!ethers.isAddress(address)) throw new Error(`Invalid address configured for ${contractKey}`);
  const contract = new ethers.Contract(address, ABI_MAP[contractKey as ContractAbiKey], signer);
  if (typeof contract[method] !== 'function') throw new Error(`Method ${method} not found on ${contractKey}`);
  return contract[method](...args);
}

export async function getConnectedAddress() {
  const provider = getEthersProvider();
  if (!provider) return null;
  const accounts = await provider.listAccounts();
  return accounts[0]?.address ?? null;
}

export function formatAddress(address: string | null) {
  if (!address) return 'Not connected';
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}
