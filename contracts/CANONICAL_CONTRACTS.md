# Canonical contract boundary

The production boundary is the following named set:

- `GenesisToken`: ERC-20-compatible GEN token with explicit minter authorization.
- `GenesisIssuance`: pull-based federal and state allocation ledger; only this module mints claimable allocations.
- `GenesisIdentityRegistry`: read-only identity and credential router for citizens, residents, workers, claimants, and arbitrators.
- `GenesisEscrow`: canonical purchase escrow; arbitration is a state path of an escrow, not a second purchase contract.
- `GenesisOracle`: native quorum reports with source hash, timestamp, and round.
- `WorkerSplit`: epoch activity ledger and pull-based 40/30/20/10 distribution.
- `GenesisValidatorRegistry`: geography and hardware-attestation registry; staking is not required for eligibility.
- `GenesisNoteRegistry`: denomination, serial, replacement, and vault-custody registry for 1, 5, 20, and 100 Gens.
- `GenesisGovernance`: canonical GiP metadata, voting window, and resolution status.

Files with the old names `GenToken.sol`, `GenesisValidatorSet.sol`, and `GenesisEscrowArbitration.sol` are legacy surfaces. They should not be deployed once equivalent functionality is migrated into the canonical modules. Test doubles belong only under `contracts/mocks/`.

GiPs should keep large human-readable specifications off-chain and commit their content hash on-chain. Bitcoin Ordinals can be an archival transport, but consensus should depend on the hash and a retrievable URI, not on ordinal availability.