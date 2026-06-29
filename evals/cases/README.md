# CAST A3 Eval Cases

Agent-behavior eval cases for the CAST v8 A3 eval harness.

## YAML Schema

Each file at `evals/cases/<agent>/<id>.yaml` must conform to this schema:

```yaml
id: <slug>               # Unique eval case identifier (matches filename without .yaml)
version: "1"             # Schema version
agent: <agent-name>      # Target agent under evaluation
description: <string>    # Human-readable description of what is being tested
corpus_source: <source>  # honesty_tables | manual | bats_failure | agent_run
failure_type: <type>     # The failure mode being exercised
cost_tier: <tier>        # cheap | medium | expensive
tags: [<list>]           # Searchable labels (failure_type, agent, domain)

trigger: |
  <The prompt that is sent to the agent under test>

expected_behaviors:
  - "<description of expected behavior>"

forbidden_behaviors:
  - "<description of behavior that must NOT occur>"

graders:
  - id: <grader-slug>
    type: programmatic      # programmatic | llm_judge
    command: "<shell command or python3 call>"
    pass_criteria: exit_code_0   # programmatic: exit_code_0; llm_judge: confirmed
    on_error: error          # error | skip | fail
```

> **`on_error` values:** `skip`, `error`, and — for **programmatic** graders only — `fail`. `llm_judge` graders cap at `error` (an LLM verifier erroring is infrastructure, not a test failure). The eval-writer authoring discipline prefers `skip`/`error` and avoids `fail` — see `evals/cases/eval-writer/eval-writer-emits-runnable-graders.yaml`.

## Grader Commands

All `type: programmatic` graders must have a `command` that is directly executable.
Template variables substituted by the runner at runtime:

| Variable | Value |
|---|---|
| `{output_file}` | Temp file containing the captured agent response |
| `{output}` | Agent response as string (for llm_judge prompts) |
| `{agent_run_id}` | `agent_runs.agent_id` from the live dispatch |
| `{session_id}` | Current session ID |

## Stub Guard

The `validate-eval-yaml.py` script (run by the runner's load phase) rejects any grader
whose `command` does not contain at least one of: `grep`, `python3`, `test `, `-f`, `-q`,
`|`, `{output`. Pure prose commands ("check if status block exists") are invalid.

## Phase A Rules

- No `type: llm_judge` graders (Phase B only)
- No `votes` field (Phase B only)
- `cost_tier: cheap` for all Phase A cases (k=1 default)
- Graders use `on_error: skip` when the DB may be absent (honesty-table queries)

## Directory Layout

```
evals/cases/
  commit/                  # Commit agent evals
  bash-specialist/         # Bash-specialist evals
  code-writer/             # Code-writer evals
  chained-agent/           # Evals for any agent in a chain
```

Existing `evals/agents/*.jsonl` files are eval-writer fixtures (descriptive, not runnable).
The A3 YAML cases in this directory are the runnable behavioral evals — do not mix formats.
