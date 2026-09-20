# Genesis Ecosystem

App, sovereign blockchain, and digital/physical tokens.

## Background

The Genesis app will allow anyone to perform escrowed transactions or earn tokens by running a verifier node on their smartphone or a validator node on their laptop or Raspberry Pi. It will also allow anyone to use the app to make direct transactions with encrypted keys and use public keys for identity.

The smartphone app will be downloadable to Android or iOS from any Pi or PC validator node. Anyone with a Raspberry Pi or old laptop/desktop with a minimum 128 GB SSD can run a validator node, earn Gens, and become part of the Genesis chain.

The Genesis blockchain is the framework for digital value exchange with a built-in escrow and arbitration mechanism that ensures that buyers get the product or service that they ordered, as advertised, while sellers get paid if all conditions are satisfied.

## No transaction fees

Digital tokens can be traded for other digital tokens on any ERC-20-compatible exchange anywhere on the planet without a transaction fee. They can also be claimed and redeemed in physical form at ATMs.

## Canonical protocol modules

The canonical protocol is organized around nine modules:

- `GenesisToken`
- `GenesisIssuance`
- `GenesisIdentityRegistry`
- `GenesisEscrow`
- `GenesisOracle`
- `WorkerSplit`
- `GenesisValidatorRegistry`
- `GenesisNoteRegistry`
- `GenesisGovernance`

These are the only canonical contract names for production use. Legacy names such as `GenesisValidatorSet.sol` and `GenesisEscrowArbitration.sol` are compatibility surfaces and should not be treated as primary modules.

## Note and token model

Since these physical notes ("Gens") cannot circulate until they are loaded with digital tokens matching their face value, no digital verification is necessary. However, scanning the interactive dynamic QR code on the note will always confirm that the points of issuance, custody, and condition match the state of the note.

Each counterfeit-resistant physical note QR will contain detailed metadata:

- Denomination
- Serial number
- Design version
- Vault ID
- Signature from vault controller
- Signature from issuer
- Issue date and time
- Place and printer of origin
- ATM signature, scan time/location
- Last known scan
- Last known condition score
- Note hash (lightweight hash of any other noteworthy information about it)

Unlike Bitcoin, which apportions new coins to owners of competing "farms" packed with expensive energy-consuming mining rigs capable of performing difficult mathematical calculations (PoW, "proof of work"), Genesis uses a different model.

## Issuance and inflation

New tokens are minted on demand by `GenesisIssuance` for eligible citizen/resident claims and by the integrated `WorkerSplit` for prior-epoch activity. Inflation is targeted below a 1% average minimum threshold.

`WorkerSplit` is derived from circulating digital GenesisTokens, current purchase escrow value, and cumulative circulating note value. Its pool is split as follows:

- 40: Node operators
  - 20: Validators (continuous nodes, laptops/desktops)
  - 20: Verifiers (sporadic nodes, smartphones)
- 30: App team
  - 06: Note technology R&D
  - 06: Cellular network integration
  - 06: Old phone/computer integration
  - 06: Shortwave/HF integration (packet radio, AX.25, Reticulum, etc.)
  - 06: Satellite integration (Iridium, Kinesis, etc.)
- 20: Note team
  - 10: Hardware bounty
  - 08: Anonymous active presence
  - 02: Note recycling/maintenance
- 10: Arbitrators
  - 10: Equally divided among all arbitrators for completed arbitrations from the previous month

If a month has no disputes, these funds are split 40:30:30 as above among the Node Operators, App Team, and Note Team respectively.

Inactivity rolls over to the next monthly epoch, and arbitrator awards are distributed equally among active arbitrators at the beginning of the succeeding month. For months with no disputes, the 10% arbitrator share is redistributed to the other categories.

## Budget and citizenship issuance

The available balance for all citizens will initially be 100 (50 federal and 50 state), and will be adjusted annually from official federal and state fiscal data in accordance with an official data feed and proof model.

## Governance and GIPs

GIPs use six tracks: Authentication (A), Core (C), Interface (I), Knowledge (K), Oracle (O), and Process (P). Proposals are introduced as GitHub pull requests, require three acknowledged authors, and must pass the relevant review gates before being merged.

In the canonical governance model, GIP implementation requires more than 50% total positive signals from:

- Verifiers: 15%
- Validators: 15%
- ATM operators: 25%
- Note developers: 15%
- Note maintainers: 15%
- UX team: 15%

## Canonical contract boundary

The production boundary is the following named set:

- `GenesisToken`: ERC-20-compatible token with explicit minter authorization.
- `GenesisIssuance`: annual pull-based federal and state allocation ledger; this module mints claimable allocations for residents and citizens.
- `WorkerSplit`: monthly epoch activity ledger and pull-based 40/30/20/10 distribution; this module mints claimable worker allocations.
- `GenesisIdentityRegistry`: read-only identity and credential router for citizens, residents, workers, claimants, and arbitrators, with hashes to external zk proofs for competence and market identifiers.
- `GenesisEscrow`: canonical purchase escrow; arbitration is a state path of an escrow, not a second purchase contract. All token transfers are 2-of-3 by default.
- `GenesisOracle`: native data feed observation reports with source hash, timestamp, and round, for daily Genesis token price, monthly `WorkerSplit` calculation, and annual state and federal `GenesisIssuance` budgetary adjustments, as well as from external zero-knowledge identity proofs.
- `GenesisValidatorRegistry`: zk production, geography, and hardware-attestation registry; staking is not required for eligibility.
- `GenesisNoteRegistry`: denomination, serial, replacement, and vault-custody registry for 1, 5, 20, and 100 Gens tied to dynamic QR.
- `GenesisGovernance`: canonical GIP metadata, voting window, and resolution status, AppTeamDAO framework.

Legacy contract surfaces should not be deployed once equivalent functionality is migrated into the canonical modules. Test doubles belong only under `contracts/mocks/`.

## Merge and naming policy

This repository is the canonical source of truth for the Genesis ecosystem module names and architecture. Duplicate or legacy module names are intentionally deprecated to prevent unnecessary splits, duplication, or omission.

### Naming and interoperability conflicts to watch

- `GenesisToken` is the canonical token contract name and should be used consistently across the codebase and docs.
- `GenesisValidatorRegistry` vs. old `GenesisValidatorSet.sol`: canonical name is `GenesisValidatorRegistry`.
- `GenesisEscrow` vs. old `GenesisEscrowArbitration.sol`: arbitration is not a separate canonical module; it is a state path within `GenesisEscrow`.
- `GenesisOracle` should remain the canonical interface name even if older files or helper contracts are present under other names (for example, oracle consumer or direct oracle helper contracts).
- Helper contracts such as `GenesisSBT`, `GenesisAttestationManager`, or `GenesisDirectOracle` are implementation details or supporting layers; they are not replacements for the nine canonical modules.

This repository should maintain a single canonical module set and adapt internal implementations to those names wherever required for interoperability.

## Repository status

The canonical version of each Genesis module is maintained in this repository and should be considered the authoritative definition for production use.
