#  CryptoVentures DAO – Governance System

A fully on-chain, modular DAO governance system implementing proposal creation with executable action payloads, non-linear weighted voting, delegation, quorum enforcement, timelock-based execution, and multi-tier treasury management.

Built with **Solidity + Hardhat + OpenZeppelin**.

---

##  Overview

CryptoVentures DAO enables members to:

* Deposit stake and receive governance influence
* Create proposals with spam prevention
* Vote using snapshot-based, delegation-aware voting
* Enforce quorum and approval thresholds
* Queue approved proposals through a type-specific timelock delay
* Execute proposals securely after delay using a dedicated executor role
* Manage multiple treasuries with different risk profiles

The system is **deterministic, auditable, and test-driven**.

---

##  Architecture

### Core Components

| Contract              | Responsibility                                              |
| --------------------- | ----------------------------------------------------------- |
| `GovernanceVotes`     | ERC20Votes governance token with delegation & snapshots     |
| `GovernanceCore`      | Proposal lifecycle, voting, quorum, execution state machine |
| `GovernanceTimelock`  | Enforces execution delay & emergency control                |
| `OperationalTreasury` | Small, fast-approval operational expenses                   |
| `InvestmentTreasury`  | High-value investment proposals                             |
| `ReserveTreasury`     | Long-term DAO reserves                                      |

---

### Proposal Lifecycle

```
Pending → Active → Succeeded → Queued → Executed
                  ↘ Defeated
```

* **Snapshot voting** prevents vote manipulation
* **One-way transitions** prevent replay or double execution
* **Timelock delay** allows emergency intervention

### Proposal Types

* **Operational**: baseline threshold, quorum, and delay
* **Experimental**: lower threshold/quorum, higher approval requirement
* **HighConviction**: higher threshold/quorum and longer timelock delay
* Each type is bound to a specific treasury target and has independently configurable parameters

---

##  Tech Stack

* **Solidity** `^0.8.28`
* **Hardhat**
* **OpenZeppelin v4.9**
* **TypeScript**
* **ethers v6**
* **ERC20Votes (Compound-style governance)**

---

## Project Structure

```
contracts/
 ├─ governance/
 │   ├─ GovernanceCore.sol
 │   ├─ GovernanceVotes.sol
 │   └─ GovernanceTimelock.sol
 ├─ treasury/
 │   ├─ OperationalTreasury.sol
 │   ├─ InvestmentTreasury.sol
 │   └─ ReserveTreasury.sol
 ├─ interfaces/
 └─ mocks/

scripts/
 └─ deploy.ts

test/
 ├─ GovernanceFlow.test.ts
 └─ Lock.ts

.env.example
hardhat.config.ts
README.md
```

---

##  Governance Model

### Voting Power

* Based on **ERC20Votes snapshots**, transformed with **sqrt weighting**
* Delegation is:

  * Optional
  * Revocable
  * Automatically included in vote weight

### Whale Protection

* Proposal threshold enforced in non-linear units
* Quorum required for validity
* Votes weighted by `sqrt(stake)` to reduce whale dominance

---

##  Test Coverage

All critical paths are tested:

* Proposal creation (threshold enforced)
* Voting (for / against / abstain)
* Double-vote prevention
* Quorum enforcement
* Full lifecycle: propose → vote → queue → execute
* Edge cases: no quorum, tie votes, expired proposals

### Run Tests

```bash
npx hardhat test
```
**All tests pass (11/11)**

---

##  Deployment 

### Install Dependencies

```bash
npm install
```

###  Start Local Blockchain

```bash
npx hardhat node
```

###  Deploy & Seed DAO

```bash
npx hardhat run scripts/deploy.ts --network localhost
```

This will:

* Deploy all contracts
* Grant timelock proposer/executor roles to governance core

---

##  Environment Variables

Create `.env` from template:

```bash
cp .env.example .env
```

### `.env.example`

```env
RPC_URL=http://127.0.0.1:8545
DEPLOYER_PRIVATE_KEY=0xabc123...
GOV_MIN_DELAY_SECONDS=172800
GOV_VOTING_DELAY_BLOCKS=1
GOV_VOTING_PERIOD_BLOCKS=45818
GOV_QUORUM_BPS=2000
GOV_PROPOSAL_THRESHOLD_ETH=100
OPERATIONAL_MAX_ETH_TRANSFER=10
INVESTMENT_MAX_ETH_TRANSFER=100
```

 **Never commit real private keys**

---

## Design Decisions

* **AccessControl over Ownable** → flexible DAO roles
* **ERC20Votes** → proven snapshot governance
* **Explicit state machine** → no implicit transitions
* **Timelock separation** → defense-in-depth security
* **Modular treasuries** → risk-segmented fund control
* **Role separation** → governor (propose/vote/queue), executor (execute), guardian (cancel)

---

##  Security Considerations

* Snapshot-based voting prevents flash-loan attacks
* Re-execution is impossible (executed flag)
* Strict role-based access control on governance and treasury execution paths
* Input validation on all external calls
* Timelock is enforced for proposal queue/execute operations
* Guardian role can cancel queued operations in emergency scenarios

---

##  Gas & Performance

* Optimized vote storage
* Minimal on-chain loops
* Suitable for DAOs with **50 → 200+ members**

---