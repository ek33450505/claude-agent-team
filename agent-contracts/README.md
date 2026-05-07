# Agent Contracts

Machine-verifiable behavioral specs for CAST core agents. Each contract defines what a well-formed agent response must contain, tested against recorded fixture files — no live API calls required.

See [docs/agent-contracts.md](../docs/agent-contracts.md) for the full spec: assertion types, fixture recording, and how to add a contract for a new agent.

---

## Contracts

| Agent | File | Description |
|---|---|---|
| `commit` | [commit.contract.yaml](commit.contract.yaml) | Asserts Status block, Work Log, cast_db write, and no raw `git commit` commands |
| `code-reviewer` | [code-reviewer.contract.yaml](code-reviewer.contract.yaml) | Asserts Status block, severity word (CRITICAL/WARNING/INFO/PASS), and cast_db write |
| `planner` | [planner.contract.yaml](planner.contract.yaml) | Asserts Status block, JSON dispatch block with `batches`, `target_branch`, and cast_db write |
| `code-writer` | [code-writer.contract.yaml](code-writer.contract.yaml) | Asserts Status block, Work Log, files changed list, and cast_db write |
| `push` | [push.contract.yaml](push.contract.yaml) | Asserts Status block, `origin` reference, and cast_db write |

## Fixtures

Recorded sample outputs used by the contract runner live in `fixtures/`:

| File | Agent | Scenario |
|---|---|---|
| `fixtures/commit-basic.txt` | commit | Basic commit with README.md change |
| `fixtures/code-reviewer-basic.txt` | code-reviewer | Code review with severity classification |

## Running Contracts

```bash
cast test                    # run all contracts
cast test commit             # run one agent
cast test --record commit    # record new fixture from live run
cast test --ci               # CI mode — no ANSI, machine-readable exit
```
