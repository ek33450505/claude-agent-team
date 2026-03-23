Analyze the user's request and break it into specialist agent tasks. Do NOT do any work inline — your ONLY job is to decompose and dispatch.

## Request
$ARGUMENTS

## Agent Registry
| Agent | Tier | Dispatch when |
|---|---|---|
| `planner` | sonnet | New features, complex changes, multi-step work |
| `debugger` | sonnet | Errors, bugs, failures, unexpected behavior |
| `test-writer` | sonnet | Writing or running tests |
| `code-reviewer` | haiku | After code changes |
| `commit` | haiku | Git commits |
| `security` | sonnet | Auth, input validation, secrets |
| `build-error-resolver` | haiku | Build/TS/ESLint errors |
| `refactor-cleaner` | haiku | Dead code, cleanup |
| `doc-updater` | haiku | README, docs, changelog |
| `researcher` | sonnet | Compare tools, evaluate libraries |
| `architect` | sonnet | System design, trade-offs |
| `e2e-runner` | sonnet | Playwright end-to-end tests |

## Protocol

1. **Classify** — Is this a single-agent task or multi-step?
2. **Dispatch immediately** — Use the Agent tool. Do not ask the user first.
   - Single-agent: dispatch one specialist with the full request
   - Multi-step: dispatch agents in dependency order — parallel where independent, sequential where dependent
   - Always prefer haiku-tier agents for routine tasks (saves tokens)
3. **Chain** — After code changes: `code-reviewer` → `commit`
4. **Never work inline** — If no agent fits, say so. Do not fall back to doing it yourself.

Dispatch now.
