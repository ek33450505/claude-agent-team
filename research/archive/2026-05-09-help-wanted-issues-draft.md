# Help Wanted / Good First Issues Draft — 2026-05-09
**Status:** DRAFT — Ed reviews then runs `gh issue create` per item.
**Goal:** Seed community contribution backlog; bump repo visibility.

Ten issues: 6 good-first-issues (≤30 min, doc/single-script/single-test), 2 help-wanted
(1–3 hours, needs code judgment), and 2 engagement issues (no code, pure visibility play).
All candidates were verified against current repo state before inclusion — three candidates
were dropped because they were already implemented (`tests/run.sh`, `cast-branch-groomer.sh
--dry-run`, zsh completion).

---

## Issue 1: Document the `bats tests/` non-recursive gotcha in CONTRIBUTING.md

**Labels:** `good first issue`, `documentation`
**Estimated time:** 15 min

`bats tests/` is non-recursive in BATS 1.13.0 — running it locally executes only 79 of
the 89+ BATS files, silently missing `tests/hooks/`, `tests/agents/`, and `tests/scripts/`.
CI uses an explicit glob list (see `tests/run.sh`) and is fine, but a first-time contributor
following `CONTRIBUTING.md` will see green output that misses ~74 tests and not know it.
There is currently no mention of this gotcha anywhere in CONTRIBUTING.md.

**What to change:** In `CONTRIBUTING.md`, under the "Running Tests" section, replace or
augment the `make test` / `bats tests/` guidance with a note that `bats tests/` is
non-recursive and contributors should use `bash tests/run.sh` (which mirrors the CI glob
exactly) or `make test` instead.

**Where to look:**
- `CONTRIBUTING.md:36` — the "Running Tests" section
- `tests/run.sh` — the CI-equivalent wrapper (shows the correct glob)
- `Makefile:19` — the `test` target

**Acceptance criteria:**
- `CONTRIBUTING.md` mentions `bash tests/run.sh` or `make test` as the canonical local
  test command.
- A note explains that `bats tests/` alone misses subdirectory suites.
- No other files changed.
- PR passes `make test` locally.

---

## Issue 2: Add `effort` frontmatter to `debugger.md` and `planner.md`

**Labels:** `good first issue`, `documentation`, `agent`
**Estimated time:** 10 min

27 of 29 agents in `agents/core/` carry an `effort:` frontmatter field (`low`, `medium`,
or `high`). The two that don't — `debugger.md` and `planner.md` — both have a comment
`# effort field is N/A on sonnet` which contradicts the convention: `researcher.md` and
`code-writer.md` are also sonnet-tier and both carry `effort: high`. The inconsistency
means documentation-generation tooling and the CHEATSHEET table have a gap for these two
agents.

**What to change:** Add `effort: high` to the frontmatter of both `agents/core/debugger.md`
and `agents/core/planner.md`, just below the `model:` line. Remove the stale comment on
each. Cross-check against `agents/core/code-writer.md` for the exact format.

**Where to look:**
- `agents/core/debugger.md:8` — the stale comment to replace
- `agents/core/planner.md:8` — same
- `agents/core/code-writer.md:10` — the `effort: high` reference pattern

**Acceptance criteria:**
- Both files have `effort: high` in their YAML frontmatter.
- The `# effort field is N/A` comment is removed from both.
- `grep -rn "^effort:" agents/core/` returns 29 results (all agents).
- No other files changed.

---

## Issue 3: Add a contract YAML for the `debugger` agent

**Labels:** `good first issue`, `tests`, `agent`
**Estimated time:** 25 min

`agent-contracts/` ships contracts for 5 agents (`commit`, `code-reviewer`, `planner`,
`code-writer`, `push`) but 24 others have no coverage. The `debugger` agent is a great
first contract to write: its output contract is simple (Status block + Work Log + at least
one root-cause line). The full spec for contract assertions is in `docs/agent-contracts.md`
and two passing contracts (`commit.contract.yaml`, `planner.contract.yaml`) serve as
working templates.

**What to change:** Create `agent-contracts/debugger.contract.yaml` with at least three
assertions: (1) output contains a Status block, (2) output contains `## Work Log`, (3)
output contains at least one of `root cause`, `cause:`, or `Fix:`. Follow the YAML
structure in `agent-contracts/commit.contract.yaml` exactly.

**Where to look:**
- `agent-contracts/commit.contract.yaml` — working template
- `agent-contracts/README.md` — table of existing contracts and their assertion summaries
- `docs/agent-contracts.md` — full assertion type reference
- `agents/core/debugger.md` — source of truth for what debugger must emit

**Acceptance criteria:**
- `agent-contracts/debugger.contract.yaml` exists and is valid YAML.
- `cast test debugger` exits 0 (runs the contract against the fixture runner).
- `agent-contracts/README.md` is updated with a row for `debugger`.
- No other files changed.

---

## Issue 4: Refactor `cast-subagent-stop-hook.sh:649` `echo` to `printf '%s\n'`

**Labels:** `good first issue`, `bash`
**Estimated time:** 15 min

`scripts/cast-subagent-stop-hook.sh:649` emits the `[CAST-TRUNCATED]` hook output using
`echo '...' "$SAFE_AGENT" ...` with bash string interpolation inside a JSON literal. The
v7 security audit (S-L1) flagged this as regression-prone: `SAFE_AGENT` is currently
sanitized correctly, but the pattern invites a future editor to skip sanitization and
introduce a JSON injection. Shell convention is to use `printf '%s'` for data that will
be embedded in a string.

**What to change:** Rewrite line 649 to use `printf` with a format string that embeds
`%s` for the agent name, rather than bash string interpolation directly in the JSON literal.
See `scripts/cast-validate-hook-contracts.sh` for examples of `printf` with JSON output.

**Where to look:**
- `scripts/cast-subagent-stop-hook.sh:649` — the line to change
- `scripts/cast-validate-hook-contracts.sh` — reference `printf` JSON pattern

**Acceptance criteria:**
- Line 649 uses `printf` (not `echo`) with a `%s` format placeholder for the agent name.
- `SAFE_AGENT` is still the value substituted.
- `make test` passes (existing BATS coverage exercises the truncation path).
- No behavior change — output JSON is identical for normal agent names.

---

## Issue 5: Add a `gh pr list` output-format comment to `cast-branch-groomer.sh`

**Labels:** `good first issue`, `bash`, `documentation`
**Estimated time:** 10 min

`scripts/cast-branch-groomer.sh:94` reads `gh pr list --json headRefName` output into a
bash array and compares branch names with `==`. The v7 security audit (S-L2) noted this
is safe today but is one refactor away from becoming an interpolation risk if someone
passes these values to a `git` invocation. A short comment at the call site recording this
constraint prevents future regression.

**What to change:** Add a 2–3 line comment above line 94 of `cast-branch-groomer.sh`
noting: (1) values are used only for `==` comparison, never interpolated into git/shell
commands; (2) if this ever changes, add input validation (alphanumeric + `-/_` only)
before passing to any shell command.

**Where to look:**
- `scripts/cast-branch-groomer.sh:94` — the `gh pr list` call to annotate

**Acceptance criteria:**
- A comment above line 94 documents the `==`-only constraint and the validation requirement
  for future callers.
- `make test` passes.
- Only `scripts/cast-branch-groomer.sh` is changed.

---

## Issue 6: Add `tests/run.sh` usage to CHEATSHEET.md quick reference

**Labels:** `good first issue`, `documentation`
**Estimated time:** 10 min

`CHEATSHEET.md` is the go-to quick reference for CAST contributors. Its "Testing" section
lists `bats tests/` as the local test command — but as documented in CONTRIBUTING.md (see
Issue 1 above), that command is non-recursive and misses ~74 tests. `tests/run.sh` is the
correct cross-platform equivalent of CI's glob, but it is not mentioned anywhere in the
cheatsheet.

**What to change:** In `CHEATSHEET.md`, find the Testing section and replace or augment
the `bats tests/` line with `bash tests/run.sh` (with a short note: "mirrors CI glob,
includes all subdirectories"). If `make test` is not already in the cheatsheet, add it
as the even-simpler alias.

**Where to look:**
- `CHEATSHEET.md` — locate the Testing section (search for `bats`)
- `tests/run.sh` — the one-liner to reference

**Acceptance criteria:**
- `bash tests/run.sh` appears in CHEATSHEET.md under the Testing section.
- A note clarifies that `bats tests/` alone is non-recursive.
- No other files changed.

---

## Issue 7: Add Fish shell completion for the `cast` CLI

**Labels:** `help wanted`, `bash`, `enhancement`
**Estimated time:** 1–2 hours

`cast` ships Zsh (`completions/_cast`) and Bash (`completions/cast.bash`) tab completion,
and `cast install-completions` wires them automatically. Fish shell users get nothing.
Fish completions use a different format (`complete -c cast -n ...`) but the subcommand
list is the same as the Zsh file. This is a self-contained task: no new CLI logic, just a
new completions file and a small patch to `_cmd_install_completions` to copy it.

**What to change:**
1. Create `completions/cast.fish` with `complete` directives covering all top-level
   subcommands visible in `cast --help` output (`status`, `exec`, `parallel`, `memory`,
   `budget`, `agents`, `hooks`, `doctor`, `upgrade-check`, `tidy`, `clean`, `dash`,
   `install-completions`, `new-agent`). Use `completions/_cast` as a reference for the
   subcommand list.
2. In `bin/cast:_cmd_install_completions` (~line 1733), add a Fish branch that copies
   `completions/cast.fish` to `~/.config/fish/completions/cast.fish` (standard Fish path).

**Where to look:**
- `completions/_cast` — Zsh completion (full subcommand list reference)
- `bin/cast:1733` — `_cmd_install_completions` function to extend
- Fish docs: https://fishshell.com/docs/current/completions.html

**Acceptance criteria:**
- `completions/cast.fish` exists and covers all top-level subcommands.
- `cast install-completions` installs the Fish file when Fish is detected.
- `bin/cast --help` output still mentions Fish completion in the install-completions
  description (add a line if needed).
- Existing Zsh/Bash install paths are unaffected.
- No BATS tests are required (completion files are not executable), but a smoke-test
  comment in the PR description showing `fish -c 'complete -C "cast "'` output is welcome.

---

## Issue 8: Add `--json` output mode to `cast doctor`

**Labels:** `help wanted`, `bash`, `enhancement`
**Estimated time:** 2–3 hours

`cast doctor` prints a human-readable health report. Several other `cast` subcommands
already support `--json` output via the `$CAST_JSON` flag (`cast agents`, `cast memory`,
`cast budget`, `cast hooks` — see `bin/cast:100` where `--json` sets `CAST_JSON=1`).
`cast doctor` does not check `$CAST_JSON` at all, making it impossible to consume health
data in scripts or dashboards without screen-scraping ANSI output.

**What to change:** Modify `_cmd_doctor()` (bin/cast:1157) to check `$CAST_JSON` after
all health checks run, and emit a JSON summary object instead of the human-readable table.
Minimum required keys: `{ "status": "ok|warn|error", "checks": [ { "name": "...",
"result": "ok|warn|error", "detail": "..." }, ... ] }`. Look at the `_cmd_agents()`
Python block (~line 534) for the pattern: branch on `$CAST_JSON`, emit JSON, exit early.

**Where to look:**
- `bin/cast:1157` — `_cmd_doctor()` function
- `bin/cast:534` — `_cmd_agents()` JSON branch pattern
- `bin/cast:100` — global `--json` flag parsing

**Acceptance criteria:**
- `cast doctor --json` emits valid JSON (verify with `cast doctor --json | python3 -m json.tool`).
- JSON contains at minimum a top-level `status` field and a `checks` array.
- `cast doctor` (no flag) output is unchanged.
- At least one BATS test in `tests/` asserts `cast doctor --json | grep -q '"status"'`.

---

## Issue 9: Share your favorite CAST hook pattern

**Labels:** `help wanted`, `enhancement`
**Estimated time:** N/A — discussion

CAST ships 13 wired hook scripts, but the framework is extensible — anyone can drop a
script into `~/.claude/scripts/` and wire it into `~/.claude/settings.json`. If you have
built a custom hook (session timer, Slack notification, cost alert, auto-journal trigger,
agent-loop guard, etc.), we want to hear about it. Community hook patterns are the best
source of inspiration for future built-in features.

**What to do:** Comment on this issue with:
1. **Hook name & trigger:** What event fires it? (`PreToolUse`, `PostToolUse`,
   `SubagentStop`, `SessionEnd`, `UserPromptSubmit`, ...)
2. **What it does:** One paragraph description.
3. **Snippet or gist (optional):** Paste a core snippet or link a gist. Even pseudocode
   is useful.

Patterns that get strong community interest may be promoted to built-in hooks in a future
CAST release with credit to the contributor.

**No PR needed** — this is a discussion issue.

---

## Issue 10: What agents would you add to CAST?

**Labels:** `help wanted`, `enhancement`
**Estimated time:** N/A — community input

CAST ships 30 agents today (`code-writer`, `debugger`, `planner`, `researcher`, and 26
others). Agent definition files are small YAML+Markdown files in `agents/core/` — adding
a new agent is one of the most accessible contributions in the repo. But we want to build
agents people actually need, not agents that sound cool in a README.

**What to do:** Comment on this issue with the agents you wish existed. For each, describe:
1. **Agent name:** (e.g. `changelog-writer`, `pr-splitter`, `dependency-upgrader`)
2. **What it does:** One sentence.
3. **When you'd use it:** What workflow pain does it solve?

Top-voted proposals from the community will be triaged for the next CAST release. If a
proposal gains traction, the issue will be converted into a `good first issue` with a
spec and implementation guide so the proposer (or anyone) can build it.

**No PR needed** — this is a discussion issue.

---

## Filing checklist (for Ed)

- [ ] Verify Issues 1–6 one more time: `grep -n` the exact lines before filing
- [ ] Decide whether to file Issue 3 (agent contract) now or after Phase 4 (Agent Inventory)
      sets a coverage target — it may be better to file a batch of 5–10 contracts together
- [ ] File Issues 9 and 10 first (zero-effort, max visibility) — they surface immediately
      in GitHub's "Issues" tab and drive watch/star behavior
- [ ] Suggested starter batch of 5 to file immediately:
      - Issue 1 (CONTRIBUTING.md gotcha — tiny, useful, trust-building)
      - Issue 2 (effort frontmatter — 10 min, zero risk)
      - Issue 4 (printf refactor — shows security awareness)
      - Issue 9 (hook pattern discussion — visibility play)
      - Issue 10 (agent wishlist — community engagement)
- [ ] For each issue, run:
      ```bash
      gh issue create \
        --title "..." \
        --body "..." \
        --label "good first issue,documentation"
      ```
- [ ] After filing, pin the two discussion issues (9, 10) to the repo for max visibility
