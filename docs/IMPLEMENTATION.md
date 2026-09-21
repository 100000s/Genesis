# Genesis implementation notes

## Automated oracle and UTC

The canonical `GenesisOracle` accepts automated relayer transactions carrying public FRED/ALFRED receipt data, exchange-price observations, and source hashes. Smart contracts cannot retrieve HTTP data directly. The relayer key is therefore an operational key, not a human approval step. All contract timestamps use `block.timestamp` interpreted as UTC; annual issuance begins at the UTC timestamp for January 1.

Suggested placeholders (replace during genesis configuration):

- `ORACLE_RELAYER = 0x0000000000000000000000000000000000000001`
- `ZK_VERIFIER = 0x0000000000000000000000000000000000000002`
- `GENESIS_UPGRADE_AUTHORITY = 0x0000000000000000000000000000000000000003`
- `NOTE_ATM_ROUTER = 0x0000000000000000000000000000000000000004`

Never commit private keys. The HP node should run the relayer under a restricted service account or hardware-backed key. Other workers receive ordinary identity/validator credentials from the genesis onboarding process; no staking is required when a valid soul-bound fingerprint attestation is available.

## Issuance and bootstrap

2026 starts with 50 federal and 50 state GEN per eligible identity. The annual ALFIN/ALFRED ratio is stored once per year and applied to the prior year's base. State eligibility uses residence credentials and federal eligibility uses citizenship credentials. Claims mint on pull. The first 100 withdrawals are capped at 100 GEN each and share a 20,000 GEN global bootstrap ceiling.

WorkerSplit uses a 0.5% activity pool, dynamic oracle ceiling, 40/30/20/10 allocation, pull claims, and rollover. The first finalized epoch includes a 10,000 GEN worker bootstrap pool. Arbitrator rewards are divided among successful arbitrators from the preceding epoch.

## GIP and operational security

GIPs store specification and BTC Ordinal hashes on-chain. Changes must pass the six-track review/last-call lifecycle. The ALFIN formula, WorkerSplit allocation, escrow security, and ZK requirements are protocol invariants and must not be weakened by a future implementation. Production deployments should add a timelocked, GIP-gated UUPS authority; testnet uses placeholder verifier and relayer addresses.

Build with Foundry from `contracts/` using `forge build`, then run the existing Hardhat tests after updating their fixtures to the canonical `contracts/src` contracts. A security audit is required before mainnet: in particular, validate the external ZK verifier, relayer key rotation, oracle freshness, and the gas cost of arbitrator participant enumeration.
