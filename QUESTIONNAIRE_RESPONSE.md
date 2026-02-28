# Questionnaire Responses (Code-Aligned)

## 1) Explain your weighted voting mechanism design. Why did you choose this approach over alternatives (quadratic, logarithmic, capped), and how does it prevent whale dominance while maintaining meaningful stake-based influence?
I use a **snapshot + non-linear** model:

- Snapshot source of truth: OpenZeppelin `ERC20Votes` (`getPastVotes`) so voting power is measured at proposal snapshot block.
- Tallying transform in `GovernanceCore`: `weight = sqrt(linearVotes)` via `Math.sqrt`.
- This non-linear weight is applied consistently to proposal threshold checks, vote tallying, and quorum math.

Why this approach:

- Compared with linear voting, `sqrt` compresses very large holders and reduces whale dominance while still rewarding larger stake.
- Compared with logarithmic voting, `sqrt` is easier for participants to reason about and still strongly dampens concentration.
- Compared with hard caps, `sqrt` is smoother and avoids sharp discontinuities where small stake changes create sudden voting jumps.

How it balances influence:

- Influence still increases with stake, but at diminishing marginal power.
- Example intuition: 4x stake gives ~2x voting weight, not 4x.
- That keeps stake economically meaningful while reducing governance capture risk by single very-large holders.

## 2) How does your delegation system work, and what edge cases did you handle? Specifically, address: delegation during active votes, delegation revocation, transitive delegation, and preventing delegation loops.
Delegation is implemented through OpenZeppelin `ERC20Votes` in `GovernanceVotes`.

Core behavior:

- A token holder delegates using `delegate(delegatee)`.
- Voting power used in governance comes from snapshots (`getPastVotes`) at the proposal snapshot block.

Edge cases:

- **Delegation during active votes:** Changes after snapshot do not affect that proposal’s already-fixed voting power; they apply to future snapshots/proposals.
- **Delegation revocation:** A holder can revoke/redirect by delegating to self or another address, and future snapshots reflect the new delegate choice.
- **Transitive delegation:** Not supported as compounding chains (A→B→C does not recursively compound delegated balances through B); delegation is one-hop in practice for vote accounting.
- **Delegation loops:** Loop amplification is prevented by the one-delegate-per-account model and non-transitive vote accounting; cyclical delegate choices do not mint extra voting power.

## 3) Explain your timelock implementation and its security benefits. What attack vectors does it prevent, and how did you determine appropriate timelock durations for different proposal types?
Timelock is enforced through `GovernanceTimelock` + `GovernanceCore` integration.

Flow:

- Proposals store on-chain execution payload (`target`, `value`, `data`, `descriptionHash`).
- `queue(proposalId)` schedules operation in timelock via `timelock.schedule(...)` and records `operationId`/`eta`.
- `execute(proposalId)` calls `timelock.execute(...)`; execution is impossible before delay expiry.

Security benefits / prevented vectors:

- Prevents **instant execution after vote**, giving users/guards reaction time.
- Prevents **payload mutation after approval**, because the queued operation hash binds target/value/calldata/salt.
- Reduces impact window for **governance capture or compromised privileged actor** by requiring delayed, observable execution.

Duration design:

- Per-type delay is configurable in `ProposalTypeConfig`.
- Baseline from timelock `minDelay`.
- Defaults: Operational = `minDelay`, Experimental = `minDelay`, HighConviction = `minDelay * 3`.
- Rationale: higher-impact proposals require longer review/exit window.

## 4) Did you implement the governance system as a single contract or multiple contracts? Explain your architectural decision, including trade-offs considered (gas costs, upgradability, modularity, deployment complexity).
I implemented a **multi-contract architecture**:

- `GovernanceVotes` for token + delegation + snapshots
- `GovernanceCore` for proposal lifecycle and governance rules
- `GovernanceTimelock` for delayed execution
- Separate treasuries (`OperationalTreasury`, `InvestmentTreasury`, `ReserveTreasury`) for segmented fund control

Why this architecture:

- Strong separation of concerns and clearer audit boundaries.
- Reuse of battle-tested OpenZeppelin components.
- Different treasury risk domains can have different policy limits.

Trade-offs:

- **Pros:** modularity, maintainability, clearer security surfaces.
- **Cons:** higher deployment/configuration complexity and more cross-contract calls than a monolith.
- **Upgradability:** current design is non-proxy and favors explicit redeploy/migration over upgrade-proxy complexity.

## 5) What are the top 3 security vulnerabilities you protected against in your implementation? For each, explain the attack vector and your mitigation strategy with specific code patterns used.
1. **Unauthorized treasury drains**

- Attack vector: External callers invoke treasury transfer functions.
- Mitigation: `onlyRole(EXECUTOR_ROLE)` on public transfer entry points in all treasury contracts.
- Pattern: strict RBAC gate at external function boundary (not only internal helper functions).

2. **Timelock bypass / instant governance execution**

- Attack vector: Execute successful proposals immediately without enforced delay.
- Mitigation: `queue` must `schedule` in `GovernanceTimelock`; `execute` routes through timelock and only succeeds after readiness.
- Pattern: two-step queue/execute with operation hash tracking and ETA.

3. **Snapshot manipulation (including flash-loan-style voting influence at execution block)**

- Attack vector: Temporarily acquire voting power around voting to inflate influence.
- Mitigation: snapshot-based voting power (`getPastVotes`) fixed at proposal snapshot block, plus one-vote-per-address guard (`hasVoted`).
- Pattern: historical checkpoints + deterministic snapshot block usage.

## 6) If you were to rebuild this system, what would you do differently? What limitations or trade-offs exist in your current implementation that you would improve with more time or resources?
Main improvements I would make:

1. **Multi-action proposals**
	- Current limitation: single `target/value/data` action per proposal.
	- Improvement: move to arrays (`targets`, `values`, `calldatas`) to support richer governance operations in one proposal.

2. **Decentralized parameter governance**
	- Current trade-off: admin can update proposal type configs and treasury mappings.
	- Improvement: route config changes through governance/timelock itself, reducing trusted admin surface.

3. **Deeper adversarial testing and formal verification scope**
	- Current state: strong flow tests exist, but broader invariant/fuzz coverage can be expanded.
	- Improvement: add fuzz/invariant suites for vote accounting, timelock state transitions, and treasury authorization boundaries.

Overall, the current implementation is functional and secure for core flow, but I would prioritize broader proposal expressiveness and reduced administrative trust in a next iteration.