# Questionnaire Responses (Code-Aligned)

## 1) Timelock and execution security
The governance flow is now integrated with `GovernanceTimelock` end-to-end. A proposal stores `target`, `value`, `data`, and `descriptionHash` in `GovernanceCore`. On success, `queue` calls `timelock.schedule(...)` and stores ETA/operationId; `execute` calls `timelock.execute(...)` and marks executed.

The timelock delay is configurable per proposal type (Operational, Experimental, HighConviction), and each type can be updated by admin using `setProposalTypeConfig`.

## 2) Access control model
The system uses OpenZeppelin `AccessControl` with separated responsibilities:
- `GOVERNOR_ROLE`: propose, vote, queue
- `EXECUTOR_ROLE`: execute queued proposals
- `GUARDIAN_ROLE`: emergency cancel for queued proposals

Treasuries (`OperationalTreasury`, `InvestmentTreasury`, `ReserveTreasury`) enforce `onlyRole(EXECUTOR_ROLE)` on public transfer entrypoints, preventing arbitrary external drains.

## 3) Voting mechanism and whale resistance
Voting uses snapshot balances from `ERC20Votes`, then applies non-linear weighting in `GovernanceCore` as `sqrt(linearVotes)`. This transformed weight is used during vote tallying.

The contract also exposes:
- `currentVotingPower(address)`
- `pastVotingPower(address,uint256)`

Both return non-linear voting power values.

## 4) Proposal types and treasury awareness
The system defines three proposal types with independent config:
- `Operational`
- `Experimental`
- `HighConviction`

Per-type parameters include proposal threshold, quorum BPS, approval BPS, and timelock delay. Each type is mapped to an allowed treasury target through `setProposalTypeTreasury`, and proposal creation enforces that mapping.

`executedValueByType` tracks executed value per category on-chain.

## 5) Known trade-offs and current limitations
- Governance currently supports a single target/value/calldata action per proposal (not batched multi-action arrays).
- Default per-type config values are initialized in constructor and are admin-updatable.
- Proposal creation still requires `GOVERNOR_ROLE`; this is a deliberate policy choice to keep membership gating strict in this implementation.

## 6) Testing and verification
`test/GovernanceFlow.test.ts` validates:
- end-to-end propose → vote → queue → execute against treasury transfer
- timelock waiting before execution
- double-vote prevention

Current local run: `npx hardhat test` passes.