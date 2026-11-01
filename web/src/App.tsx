import { useEffect, useState } from 'react';
import { formatAddress, getConnectedAddress, readContract, writeContract } from './services/contractService';
import { getEthersProvider, getRuntimeContracts, CONTRACT_ORDER, type ContractKey } from './lib/contracts';

const TAB_ITEMS = ['overview', 'issuance', 'governance', 'workers', 'escrow', 'notes', 'validators'] as const;
type Tab = (typeof TAB_ITEMS)[number];

function App() {
  const [tab, setTab] = useState<Tab>('overview');
  const [wallet, setWallet] = useState<string | null>(null);
  const [status, setStatus] = useState<string>('Not connected');
  const [loading, setLoading] = useState(false);
  const [contracts] = useState(getRuntimeContracts());
  const [message, setMessage] = useState<string>('Ready');

  useEffect(() => {
    const syncWallet = async () => {
      const address = await getConnectedAddress();
      if (address) {
        setWallet(address);
        setStatus('Wallet connected');
      }
    };

    void syncWallet();
  }, []);

  const connectWallet = async () => {
    if (!window.ethereum) {
      setStatus('No wallet detected. Install MetaMask or a compatible wallet.');
      return;
    }

    setLoading(true);
    try {
      const provider = getEthersProvider();
      if (!provider) throw new Error('Wallet provider unavailable');
      const accounts = await provider.send('eth_requestAccounts', []);
      const [account] = accounts;
      setWallet(account);
      setStatus('Wallet connected');
      setMessage('Wallet connected');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : 'Wallet connection failed');
    } finally {
      setLoading(false);
    }
  };

  const handleRead = async (key: ContractKey, method: string, args: unknown[] = []) => {
    try {
      const value = await readContract(key, method, args);
      setMessage(`${key}.${method} => ${JSON.stringify(value)}`);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Read failed');
    }
  };

  const handleWrite = async (key: ContractKey, method: string, args: unknown[] = []) => {
    try {
      const tx = await writeContract(key, method, args);
      setMessage(`${key}.${method} submitted: ${tx.hash ?? 'pending'}`);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Write failed');
    }
  };

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand-wrap">
          <div className="brand-mark">G</div>
          <div>
            <div className="eyebrow">Sovereign ecosystem</div>
            <h1>Genesis</h1>
          </div>
        </div>

        <div className="topbar-actions">
          <span className="status-pill">{status}</span>
          <button className="primary" onClick={connectWallet} disabled={loading}>
            {loading ? 'Connecting...' : wallet ? formatAddress(wallet) : 'Connect wallet'}
          </button>
        </div>
      </header>

      <nav className="nav" aria-label="Primary navigation">
        {TAB_ITEMS.map((item) => (
          <button
            key={item}
            className={item === tab ? 'nav-item active' : 'nav-item'}
            onClick={() => setTab(item as Tab)}
          >
            {item}
          </button>
        ))}
      </nav>

      <main className="content">
        {tab === 'overview' && <OverviewSection contracts={contracts} onRead={handleRead} />}
        {tab === 'issuance' && <IssuanceSection wallet={wallet} onRead={handleRead} onWrite={handleWrite} message={message} />}
        {tab === 'governance' && <GovernanceSection wallet={wallet} onRead={handleRead} onWrite={handleWrite} message={message} />}
        {tab === 'workers' && <WorkersSection wallet={wallet} onRead={handleRead} onWrite={handleWrite} message={message} />}
        {tab === 'escrow' && <EscrowSection wallet={wallet} onRead={handleRead} onWrite={handleWrite} message={message} />}
        {tab === 'notes' && <NotesSection wallet={wallet} onRead={handleRead} onWrite={handleWrite} message={message} />}
        {tab === 'validators' && <ValidatorsSection wallet={wallet} onRead={handleRead} onWrite={handleWrite} message={message} />}
      </main>
    </div>
  );
}

function OverviewSection({
  contracts,
  onRead
}: {
  contracts: ReturnType<typeof getRuntimeContracts>;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
}) {
  return (
    <section>
      <div className="hero-card">
        <div className="hero-copy">
          <div className="eyebrow">Genesis Ecosystem</div>
          <h2>App, token, sovereign blockchain, and digital identity</h2>
        </div>
        <p>
          Access citizenship issuance, governance, worker rewards, escrow, validator workflows, note metadata,
          and app team allocations from a single mobile-first interface.
        </p>
      </div>

      <div className="grid cards three-up">
        {CONTRACT_ORDER.map((key) => (
          <div className="card" key={key}>
            <div className="card-head">
              <h3>{contracts[key].name}</h3>
              <span className="dot" />
            </div>
            <p>{contracts[key].description}</p>
            <code>{contracts[key].address}</code>
            <small>{contracts[key].methods.slice(0, 2).join(' • ')}</small>
            <button className="secondary" onClick={() => onRead(key, contracts[key].methods[0], [])}>
              Read contract
            </button>
          </div>
        ))}
      </div>
    </section>
  );
}

function IssuanceSection({ wallet, onRead, onWrite, message }: {
  wallet: string | null;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  onWrite: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  message: string;
}) {
  return (
    <section className="panel">
      <h2>Issuance</h2>
      <p>Federal/state claims, dynamic availability windows, and referral rewards.</p>
      <div className="button-row">
        <button className="primary" onClick={() => onRead('GenesisIssuance', 'currentYear', [])}>Read year</button>
        <button className="primary" onClick={() => onWrite('GenesisIssuance', 'withdraw', [0, 0, 1n * 10n ** 18n])} disabled={!wallet}>Claim sample</button>
      </div>
      <p className="status-text">{message}</p>
      <ul>
        <li>availableFederal(address)</li>
        <li>availableState(address, uint8)</li>
        <li>withdraw(uint8 kind, uint8 stateId, uint256 amount)</li>
      </ul>
    </section>
  );
}

function GovernanceSection({ wallet, onRead, onWrite, message }: {
  wallet: string | null;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  onWrite: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  message: string;
}) {
  return (
    <section className="panel">
      <h2>Governance</h2>
      <p>GIP lifecycle, weighted voting, and bootstrap gate checks.</p>
      <div className="button-row">
        <button className="primary" onClick={() => onRead('GenesisGovernance', 'getBootstrapStatus', [])}>Check gate</button>
        <button className="primary" onClick={() => onWrite('GenesisGovernance', 'vote', [0, true, 1])} disabled={!wallet}>Vote sample</button>
      </div>
      <p className="status-text">{message}</p>
      <ul>
        <li>propose(bytes32, Track, bytes32, bytes32)</li>
        <li>vote(bytes32, bool, uint256)</li>
        <li>resolve(bytes32)</li>
        <li>activate(bytes32)</li>
      </ul>
    </section>
  );
}

function WorkersSection({ wallet, onRead, onWrite, message }: {
  wallet: string | null;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  onWrite: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  message: string;
}) {
  return (
    <section className="panel">
      <h2>Workers</h2>
      <p>Validator, verifier, app team, note team, and arbitrator reward pools.</p>
      <div className="button-row">
        <button className="primary" onClick={() => onRead('WorkerSplit', 'epoch', [])}>Read epoch</button>
        <button className="primary" onClick={() => onWrite('WorkerSplit', 'finalizeEpoch', [])} disabled={!wallet}>Finalize epoch</button>
      </div>
      <p className="status-text">{message}</p>
      <ul>
        <li>recordActivity(uint256)</li>
        <li>recordNativeVolume(uint256)</li>
        <li>finalizeEpoch()</li>
        <li>claim(uint64, uint8)</li>
      </ul>
    </section>
  );
}

function EscrowSection({ wallet, onRead, onWrite, message }: {
  wallet: string | null;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  onWrite: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  message: string;
}) {
  return (
    <section className="panel">
      <h2>Escrow & arbitration</h2>
      <p>Purchase escrow, proof-gated releases, and arbitrator-driven dispute flows.</p>
      <div className="button-row">
        <button className="primary" onClick={() => onRead('GenesisEscrow', 'nextEscrowId', [])}>Read next escrow</button>
        <button className="primary" onClick={() => onWrite('GenesisEscrow', 'triggerDefault', [0])} disabled={!wallet}>Trigger default</button>
      </div>
      <p className="status-text">{message}</p>
      <ul>
        <li>createEscrow(address seller, uint256 amount, bytes32 credentialType, uint64 duration)</li>
        <li>fulfillEscrow(uint256, bytes proof)</li>
        <li>triggerDefault(uint256)</li>
      </ul>
    </section>
  );
}

function NotesSection({ wallet, onRead, onWrite, message }: {
  wallet: string | null;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  onWrite: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  message: string;
}) {
  return (
    <section className="panel">
      <h2>Physical note registry</h2>
      <p>Serial metadata, denomination, vault data, ATM scans, and replacement tracking.</p>
      <div className="button-row">
        <button className="primary" onClick={() => onRead('GenesisNoteRegistry', 'issued', [0])}>Check issue status</button>
        <button className="primary" onClick={() => onWrite('GenesisNoteRegistry', 'recordScan', [0, 0, 0, 0, 0])} disabled={!wallet}>Record scan</button>
      </div>
      <p className="status-text">{message}</p>
      <ul>
        <li>issue(bytes32 serial, uint256 denomination, bytes32 vaultId, Metadata)</li>
        <li>recordScan(bytes32 serial, bytes32 atmSignature, uint64 scanAt, bytes32 location, uint16 conditionScore)</li>
        <li>replace(bytes32 oldSerial, bytes32 newSerial)</li>
      </ul>
    </section>
  );
}

function ValidatorsSection({ wallet, onRead, onWrite, message }: {
  wallet: string | null;
  onRead: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  onWrite: (key: ContractKey, method: string, args?: unknown[]) => Promise<void>;
  message: string;
}) {
  return (
    <section className="panel">
      <h2>Validators</h2>
      <p>Node registration, staking, hardware commitments, and validator registry status.</p>
      <div className="button-row">
        <button className="primary" onClick={() => onRead('GenesisValidatorRegistry', 'count', [])}>Count validators</button>
        <button className="primary" onClick={() => onWrite('GenesisValidatorRegistry', 'setActive', [wallet ?? '0x0000000000000000000000000000000000000000', true])} disabled={!wallet}>Set active</button>
      </div>
      <p className="status-text">{message}</p>
      <ul>
        <li>register(bytes32 identityCommitment, bytes32 hardwareCommitment, bytes32 geography)</li>
        <li>registerValidator(address validator, string nodeType)</li>
        <li>setActive(address validator, bool active)</li>
      </ul>
    </section>
  );
}

export default App;
