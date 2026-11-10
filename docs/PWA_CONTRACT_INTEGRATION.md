# Genesis PWA contract integration

The PWA uses ethers v6 with an injected EIP-1193 wallet provider. Contract addresses are deployment-specific and are deliberately not hardcoded. Configure the following Vite variables in the deployment environment:

- `VITE_GENESIS_CHAIN_ID` — decimal EVM chain ID expected for transactions.
- `VITE_GENESISTOKEN_ADDRESS`
- `VITE_GENESISISSUANCE_ADDRESS`
- `VITE_WORKERSPLIT_ADDRESS`
- `VITE_GENESISGOVERNANCE_ADDRESS`
- `VITE_APPTEAMDAO_ADDRESS`
- `VITE_APPTEAMREWARDDISTRIBUTOR_ADDRESS`
- `VITE_NOTETEAMREWARDDISTRIBUTOR_ADDRESS`
- `VITE_NOTETEAMDAO_ADDRESS`
- `VITE_GENESISESCROW_ADDRESS`
- `VITE_GENESISIDENTITYREGISTRY_ADDRESS`
- `VITE_GENESISVALIDATORREGISTRY_ADDRESS`
- `VITE_GENESISORACLE_ADDRESS`
- `VITE_GENESISNOTEREGISTRY_ADDRESS`

Unset contract variables remain zero-address placeholders, so the PWA reports no deployment rather than sending transactions to an invented address. `VITE_GENESIS_CHAIN_ID` is optional during local development; when set, writes are blocked unless the connected wallet is on that chain.

## Deployment wiring

Deploy/configure on the same Genesis EVM network and publish all addresses together as one environment manifest. The normal dependency order is token and registries/oracle, issuance, WorkerSplit, App/Note reward distributors, NoteTeamDAO, AppTeamDAO/Governance, then escrow; set each authorized minter, worker, reporter, verifier, arbitration source, reward sink, and DAO relationship before enabling claims. Verify bytecode and constructor dependencies against the deployment manifest before publishing PWA environment values.

The PWA includes the canonical ten contracts plus the three supplemental reward modules. AppTeamDAO remains for governance coordination; AppTeamRewardDistributor is the App reward claimant interface. The NoteTeamDAO is scoped to the 2% maintenance treasury. Actual chain addresses, chain ID, deployment transactions, and production build/test results must be supplied/verified during deployment; repository configuration alone does not deploy contracts.

External proof and telemetry validation is performed by configured contract-side verifier/relayer integrations. The PWA must never treat an evidence hash or a successful wallet transaction as independent proof that off-chain utilization was genuine.
