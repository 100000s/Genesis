# Genesis Ecosystem

App, sovereign blockchain, and digital/physical tokens.

## Background

The Genesis app will allow anyone to 
- Selectively reveal his soulbound identity and/or history,
- Participate in escrowed digital transactions - regardless of residency or medium, 
- Earn tokens by 
	- Running a verifier node on his smartphone,
	- Running a validator node on his laptop, desktop, or Raspberry Pi, 
	- Participating in app development,
	- Operating an ATM, or
	- Arbitrating disputes.
- Claim free digital or physical tokens with proof of U.S. citizenship or State residency. 

The smartphone app will be downloadable to Android or iOS from any Pi or PC validator node. Anyone with a Raspberry Pi or old laptop/desktop with a minimum 128 GB SSD can run a validator node, earning a bigger share of tokens. The app will show balance information, allow shopping, selling, getting or redeeming digital or physical Genesis Tokens, and reporting issues and bugs. It will be overlaid on a live interactive map by default, and allow functionality with AI and immersive 3D/AR/VR platforms.

The Genesis blockchain is the framework for digital value exchange with a built-in escrow and arbitration mechanism that ensures that buyers get the product or service that they ordered, as advertised. The Genesis wallet also includes an integrated soul-bound token (SBT) mechanism that allows buyers, sellers, and other participants to selectively reveal their identity, history, or credentials (via zero-knowledge proofs), ranging from citizenship or residency to training and expertise or employment, medical history, and property titles. Any U.S. citizen or resident with a soul-bound identity can also claim up to 100 Genesis tokens until January 1, 2027, without cost or obligation.

Digital GenesisTokens will be exchangeable for other ERC-20-compatible tokens on a typical exchange, and will not incur transaction or use fees. 

## Physical tokens

Genesis tokens can also be claimed and redeemed in physical form at an authorized printer or ATM in fixed preloaded denominations (1, 5, 20, and 100 Gens), which can be physically deposited into an account at any designated ATM, or used like cash. For these physical tokens, no electronic wallet is required. No cell phone. No technical know-how. No password or passphrase to remember.

Since these counterfeit-resistant physical notes ("Gens") cannot circulate until they are loaded with digital tokens matching their face value, no digital verification is necessary. But scanning the interactive dynamic QR code can reveal the note's entire digital history.

Each physical note's dynamic QR will contain real-time detailed metadata:

- Denomination
- Serial number
- Design version
- Vault transaction ID
- Signature from vault controller
- Signature from issuer
- Issue date and time
- Place and printer of origin
- ATM signature, scan time/location
- Last known scan
- Last known condition score
- Note hash (lightweight hash of any other noteworthy information about it)

Unlike Bitcoin, which apportions new coins to owners of competing "farms" packed with expensive energy-consuming mining rigs capable of performing difficult mathematical calculations (PoW, "proof of work"), or Ethereum, which apportions new coins to stakeholders based on the massiveness of their holdings (PoS, "proof of stake"), Genesis tokens are minted on demand in limited amounts for free (PoE, "proof of existence"). Genesis utilizes a universal citizen/resident airdrop, accompanied by a UBI (universal basic income) framework for residents of tax-friendly states.

## Issuance and inflation

New tokens are minted on demand by `GenesisIssuance` for eligible citizen/resident claims and by the integrated `WorkerSplit` for prior-epoch activity. Inflation is targeted below a 1% average mint rate: the `WorkerSplit` component is 0.5% of measured active transaction volume, while citizen/resident issuance follows its separate immutable budget-adjustment formula, capped at 0.5% based on withdrawals from the prior day and month. Both mints also have an allowance for an increased token exchange value.

`WorkerSplit` is derived from circulating digital GenesisTokens, current purchase escrow value, and cumulative circulating note value. Its pool is split as follows:

- 40: Node operators
  - 20: Validators (continuous nodes, laptops/desktops)
  - 20: Verifiers (sporadic nodes, smartphones)
- 30: App team
  - 10: Physical token technology R&D (secure Gen production, physical merchant integration)
  - 10: Digital token technology R&D (Cellular interface, AX.25, Reticulum, Iridium, Kinesis, &c)
  - 10: AI/3D/VR/AR immersive shopping integration (Genesis Mall partnerships, Virtual world portals)
- 20: Note team
  - 10: Hardware bounty
  - 08: Anonymous active presence
  - 02: Note recycling/maintenance
- 10: Arbitrators
  - 10: Equally divided among all arbitrators for completed arbitrations from the previous month

Inactivity rolls over to the next monthly epoch, and arbitrator awards are distributed equally among active arbitrators at the beginning of the succeeding month. For months with no disputes, the 10% arbitrator pool will be split among the other three groups at 40/30/30 respectively. These percentages can only be altered via the defined GIP protocol.

## Budget and citizenship issuance

The available balance for all citizens will initially be 100 (50 federal-derived and 50 state-derived), and will be adjusted annually from official federal and state fiscal data in accordance with an official ALFRED data feed. Beginning January 1, 2027, the prior year's available balance (not factoring individual withdrawals or deposits) is multiplied by the prescribed ratio of the relevant fiscal-year receipts (total fiscal-year receipts from two prior years divided by those of the succeeding year). Citizen/resident GenesisIssuance rules are immutable and cannot be changed by a GIP.

## Governance and GIPs

GIPs use six tracks: Authentication (A), Core (C), Interface (I), Knowledge (K), Oracle (O), and Process (P). Proposals are introduced as GitHub pull requests, require three acknowledged authors, pass review and peer audit, remain in a 28-day Last Call, and have a 12-week activation window. The genesis block and each subsequent protocol iteration commit a hash and URI for the GitHub GIP and BTC Ordinals text recording implemented contract changes. Ordinal publication may be paid by any party; consensus relies on the content hash, not ordinal availability.

The GIP process is enabled after at least one transaction is initiated in each of the 50 states, and an ATM transaction in 10 distinct states.

In the canonical governance model, GIP implementation requires more than 50% total positive signals from:

- Verifiers: 15%
- Validators: 15%
- ATM operators: 15%
- Note Team (developers and maintainers): 15%
- AppTeam: 15%
- 1% or more of ATM customers (verified unique customer votes at ATMs - offset by negative vote percent): 25%

## Canonical contract boundary

The production boundary is the following named set:

- `GenesisToken`: ERC-20-compatible token with explicit minter authorization.
- `GenesisIssuance`: Annual pull-based allocation ledger; This module mints claimable allocations for residents and citizens, acting as an airdrop/UBI limited minter of GenesisTokens derived from annual state and federal budgetary adjustments.
- `WorkerSplit`: Monthly epoch activity ledger and pull-based 40/30/20/10 distribution; This module mints claimable worker allocations of GenesisTokens for Validators, Verifiers, App Team, ATM operators, and Arbitrators
- `GenesisIdentityRegistry`: A read-only identity and credential router for citizens, residents, workers, claimants, and arbitrators, with hashes to external zk proofs for competence and market identifiers, providing zero-knowledge soul-bound identity (SBTs) selective revelation for market participation
- `GenesisEscrow`: Canonical default escrow contract for purchases, with automated arbitration mechanism for disputes; Arbitration is a state path of an escrow, not a second purchase contract. All token transfers are 2-of-3 by default.
- `GenesisOracle`: Native data feed observation reports with source hash, timestamp, and round, for daily Genesis token price (TWAP), monthly `WorkerSplit` calculation, and annual state and federal `GenesisIssuance` budgetary adjustments via ALFRED budget feeds, as well as external zero-knowledge identity and ATM firmware proofs. 
- `GenesisValidatorRegistry`: Verification for Validation, Verification, ATM operation, Arbitration, GIP implementation, zk production, geography, and hardware-attestation registry; While staking is not required for worker eligibility zero-knowledge proof of identity is required for production. 
- `GenesisNoteRegistry`: Detailed metadata for physical Gens; denomination, serial, replacement, vault and transaction history for 1, 5, 20, and 100 Gens tied to dynamic QR.
- `GenesisGovernance`: Automated GIP (Genesis Improvement Proposal) protocol; canonical GIP metadata, voting window, and resolution status, AppTeamDAO framework.
- `AppTeamDAO`: Integrated GitHub-based Genesis tech development platform, live ongoing Genesis ecosystem research, development, and delivery. 

## Repository status

The canonical version of each Genesis module is maintained in this repository at https://github.com/100000s/Genesis/tree/main/contracts/src and should be considered the authoritative definition for production use.


