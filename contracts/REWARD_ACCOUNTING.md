# Reward accounting integration

The revised reward contracts use WorkerSplit's epoch counter as the shared epoch identifier. WorkerSplit funds AppTeamRewardDistributor and NoteTeamRewardDistributor with the closed epoch ID; evidence and contributions are recorded against the currently active WorkerSplit epoch. Each distributor finalizes only after WorkerSplit advances past that epoch.

## Worker allocation and claims

Validator and Verifier contributions are recorded by configured reporters during the active epoch. The reporter integrations must measure verified work (continuous node service for Validators; successful verification work for Verifiers) and not merely registration or device count. Worker claims remain open indefinitely. Once a pool is allocated to participants, it is a permanent liability and cannot be rolled over or settled again. If a Validator/Verifier epoch has no measured contribution, its category allocation remains in category-specific rollover until an epoch with eligible contribution weights.

Arbitration final outcomes are reported by a configured arbitration source using a unique case/outcome ID. Only registered Arbitrators can be credited. Successful eligible arbitrators share that epoch's 10% pool equally and may claim indefinitely. If none are eligible at epoch close, WorkerSplit applies the 40:30:30 fallback once: Chain Maintainers, App Team, and Note Team. Configure the escrow address as an arbitration source and ensure arbitrators are registered before relying on rewards.

## App technology rewards

WorkerSplit mints the 30% App allocation to AppTeamRewardDistributor and records its funding under the originating epoch. The distributor splits its pool into physical, digital, and immersive technology allocations. Use verifiers must attest qualifying end-user operations using unique operation IDs and evidence hashes; separate contribution verifiers report developer weights and evidence hashes. Use and contribution submissions must follow independently documented validation policies. A technology receives its epoch funding only when both qualifying use and contribution records exist; otherwise, the share rolls forward only in that technology's bucket.

## Note Team distributions

NoteTeamRewardDistributor receives the 20% Note allocation and automatically partitions each funded epoch into 10% hardware bounty, 8% active presence, and 2% NoteTeamDAO maintenance funding. Authorized qualification verifiers attest new ATM qualification; a registered ATM ID can qualify only once. Authorized activity verifiers attest unique operations and weighted activity. Eligible operator claims remain available indefinitely. The DAO treasury accepts only the 2% maintenance transfer and uses proposal, review, approval, grant payment, and completion-audit roles. Proposal metadata is an off-chain document commitment identified by a bytes32 hash.

Operator commitments are pseudonymous identifiers, not a cryptographic privacy system. The transaction and payout address can still be linkable on a public chain. Use privacy-preserving attestation and payout mechanisms before claiming strong anonymity.

## Deployment order and required configuration

1. Deploy GenesisToken, GenesisOracle, and GenesisIssuance according to their normal configuration.
2. Deploy WorkerSplit with issuance and oracle addresses.
3. Deploy AppTeamRewardDistributor(token, WorkerSplit).
4. Deploy NoteTeamRewardDistributor(token, WorkerSplit).
5. Deploy NoteTeamDAO(token, NoteTeamRewardDistributor), then set it in the Note distributor.
6. Configure WorkerSplit reward sinks and chain-maintainer fallback recipient.
7. Authorize WorkerSplit as a token minter in GenesisToken and configure WorkerSplit as a worker minter in GenesisIssuance.
8. Configure registry registration agents, verified contribution reporters, use verifiers, ATM qualification/activity verifiers, and GenesisEscrow as the arbitration source.
9. Register all eligible workers in their appropriate category before reporting contributions or arbitration outcomes.

All privileged verifier and reporter roles are security-critical. Changes to these roles should be governed and monitored. These contracts do not independently verify off-chain evidence; they enforce unique IDs, epoch/category separation, role authorization, and auditable evidence commitments.
