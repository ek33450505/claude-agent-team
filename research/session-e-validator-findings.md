# Session E — `cast-validate-all-hooks.sh` findings (measured 2026-08-20)

> Companion to `session-e-hook-surface.md` (native hook surface, re-sourced from docs).
> This file covers CAST's **own** hook-contract gate. Everything below was measured on
> `main` @ `65c58e5`, not inferred. Probe commands are inline so each claim is re-runnable.

`scripts/cast-validate-all-hooks.sh` is a **real CI gate** — `hook-contract-validation` runs
`--source`, and `CLAUDE.md` documents it as run directly and BEFORE the `act` loop precisely so a
later failure cannot silently skip it. It is therefore load-bearing, and all three findings below are
about it reporting success it did not earn.

---

## E-1 (CRITICAL) — the destructive-op guard is NEVER validated, and the gate still exits 0

`settings.json` registers the guard as a **`python3`** command, not `bash`:

```
"command": "python3 ~/.claude/scripts/cast-pretool-dispatch.py"
```

The resolver at `scripts/cast-validate-all-hooks.sh:132-134`:

```bash
script_path="${cmd#bash }"                    # no-op — command starts with "python3", not "bash "
script_path="${script_path/#\~/$HOME}"        # no leading ~ any more; nothing to expand
script_path="${script_path%% *}"              # -> "python3"
```

`script_path` becomes the bare string `python3`, `[[ ! -f "$script_path" ]]` is true (there is no file
named `python3` in the CWD), and `:136-140` emits a warn and `continue`s. **The hook is never
executed.** Measured:

```
$ bash scripts/cast-validate-all-hooks.sh --source
[warn] cast-pretool-dispatch (PreToolUse) — script not found: python3
validated 29 hooks: 23 ok, 6 warn, 0 fail
$ echo $?
0
```

**Why this is the worst possible hook to skip.** `cast-pretool-dispatch.py` is the enforcement point
for every irreversibility interrupt — `git push`/force-push, force-merge, raw `git commit`,
`rm -rf`, `pkill`/`killall`, DB row deletion, and the `git branch -D` guard. It is the mechanism the
whole §2.5 ledger rests on. The gate that exists to prove the hook surface is intact has never once
run it, and reports `0 fail` while doing so.

⚠️ Note the guard itself **works** — verified live today: `git branch -D` was correctly blocked with
the documented message. The defect is in the *validator*, not the guard. That is exactly what makes
it dangerous: the guard could silently break tomorrow and this gate would keep printing `0 fail`.

**Secondary:** `validated 29 hooks` is itself an overstatement — 23 ran, 6 warned, and at least one
of those 6 was never executed at all.

---

## E-2 (HIGH) — `--source` validates the INSTALLED copy, not the repo; its `--help` says otherwise

`--source` only chooses which settings file to **enumerate** (`:59-60`,
`SETTINGS_FILE="$REPO_DIR/settings.json"`). The commands *inside* that file are hardcoded
`~/.claude/scripts/…`, and `:133` expands `~` to `$HOME`, so execution at `:151`
(`bash "$script_path"`) always hits the live installed script.

**Measured — 0 of 29 hook commands resolve into the working tree:**

```
total command hooks in REPO settings.json : 29
  resolve to ~/.claude (INSTALLED copy)   : 28
  resolve into the repo working tree      : 0
  (the 29th resolves to the bare string "python3" — see E-1)
```

**Proven empirically by ABSENCE of the marker**, not by reading the code: a loud
`echo "REPO_COPY_MARKER_XYZ"` was appended to the **repo** copy of
`scripts/cast-post-compact-hook.sh` (installed copy untouched), then `--source` was run:

```
repo copy contains marker: 1     installed copy contains marker: 0
[ok] cast-post-compact-hook.sh (PostCompact) — empty stdout (logging-only, ok)
marker occurrences in validator output: 0
```

Had it run the repo copy, stdout would have been non-empty and the contract validator would have
said so. File restored and `shasum -a 256 -c` verified.

**Consequence:** edit a hook in the repo, run `make ci-local`, get a green hook-contract gate — and
your edit was never checked. Real CI is fine (`bats-ci.yml:70-75` copies `scripts/*` into
`~/.claude/scripts/` first); the Makefile does not, so this bites **locally only**, which is worse,
because local green is what people act on before pushing.

The `--help` text is actively false:

```
--source     Validate repo scripts/ hooks (reads repo settings.json)
             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^  false      ^^^^^^^^^^^^^^ true
```

---

## E-3 (MEDIUM) — arguments are stripped, so hooks are not tested as configured

`:134` (`${script_path%% *}`) drops everything after the first space. Measured, 3 of 29 registrations
lose arguments:

| event | script | argument lost |
|---|---|---|
| `PostToolUse` | `cast-audit-hook.sh` | `--mode post` |
| `PreToolUse`  | `cast-audit-hook.sh` | `--mode pre` |
| `PreToolUse`  | `python3` | `~/.claude/scripts/cast-pretool-dispatch.py` (E-1) |

So `cast-audit-hook.sh` is registered twice with opposite modes and **both are validated as the
default `pre` mode** — the `PostToolUse` contract is never exercised. This is the likely source of the
recorded `ERROR cast-audit.py: invalid JSON on stdin` log noise: a hook is fed a payload shaped for a
mode it was not told it is in, and the gate counts the resulting empty stdout as `[ok]`.

---

## What the DOCS say the contract is (re-sourced 2026-08-20, `code.claude.com/docs/en/hooks`)

This reframes the fix — the validator is not merely buggy, it invokes hooks **differently from how
Claude Code invokes them**:

- **Shell form** (hook entry has NO `args` key): the `command` string is passed whole to `sh -c`.
  Everything after the first space is part of the command; Claude Code does not split or truncate it.
- **Exec form** (hook entry HAS `args`): `command` is resolved on `PATH` and spawned directly with
  `args` as the argv vector, no shell.

**Measured: all 29 CAST command hooks are shell form** (0 carry an `args` key). So the documented
behavior for every one of them is `sh -c "<the whole string>"`, while the validator does
`bash "<first token after stripping a leading 'bash '>"`. That is wrong on both axes — it discards the
arguments AND forces `bash` as the interpreter even when the command says `python3`.

## Proposed fixes (ranked; Session E's mandate is to implement the top 1–2 only)

1. **Invoke the hook the way the docs say Claude Code does** — `sh -c "$cmd"` on the full (tilde-
   expanded) command string, instead of decomposing it into `bash "$script_path"`. This is the
   *native-over-bespoke* fix and it is SMALLER than the decompose-and-parse approach I first proposed:
   one invocation change fixes E-1 (`python3 …` runs instead of resolving to the bare word `python3`)
   and E-3 (`--mode post` survives) together, with no interpreter-guessing logic at all.
   `sh` performs tilde expansion itself, so the manual `~`→`$HOME` step can go too.
   ⚠️ Keep a resolvability/existence check for the *reporting* path, and make an unrunnable hook a
   **FAIL, not a WARN** — a hook the gate cannot execute is precisely the case the gate exists to catch.
   ⚠️ If an `args` key is ever added to a CAST hook, this must branch to exec form; assert on it.
2. **Make `--source` mean what it says**: rewrite `~/.claude/scripts/` → `$REPO_DIR/scripts/` when
   `MODE=source`, so the flag validates the working tree. Alternative (heavier): have `ci-local`
   stage `scripts/*` into a temp HOME first, mirroring what `bats-ci.yml` already does.
3. **Pass the registered arguments through** to the invocation, so `--mode post` is tested as `post`.
4. **Make the summary line honest** — report executed vs skipped separately rather than folding an
   unexecuted hook into a 29-hook "validated" count.

⚠️ **Whatever is implemented must be mutation-tested**: break a hook deliberately, confirm the gate
goes RED. A gate that has never failed is indistinguishable from one that cannot fail — which is how
all three of these survived.

## Still open (not yet measured this session)

- Carry-forward 10: whether any CI check validates BOTH readers of `_default_unknown`; if none exists
  it is a config key both readers ignore.
- Carry-forward 9: `EGRESS_POLICY_CANDIDATES` prefers `$CWD/config/egress-policy.json`, so an
  unexpected CWD can shadow the real policy (audit-accuracy only; no enforcement path).
- Confirmed log pollution: each validator run appends `+1` line to `audit.jsonl` and `+2` to
  `hook-errors.log`, all `ERROR cast-audit.py: invalid JSON on stdin`.

---

## Addendum — event-count correction, and a number worth not conflating

- **The docs list 31 hook events**, fetched directly from `code.claude.com/docs/en/hooks` on
  2026-08-20. Prior CAST notes said "~29 events." That is a real discrepancy, not a rounding —
  correct it wherever CAST cites a hook-event count. (Third-party mirrors say 30, suggesting the
  count moved recently; the live first-party page is authoritative.)
- ⚠️ **Two different 29s, do not conflate them.** "~29 events" (a claim about the DOCS' event table,
  actually 31) and "validated 29 hooks" (CAST's own count of registered *command* hooks) are
  unrelated numbers that happen to coincide. CAST registers **18 distinct events / 29 command hooks**,
  out of 31 events the platform documents.
- **Not a finding:** `settings.json` also carries 3 `type: "prompt"` hooks (2 × `PreToolUse`,
  1 × `PostCompact`). These are not commands and the validator correctly ignores them — checked
  before reporting, so the 32-entry vs 29-command gap is explained, not a coverage hole.

## Native surface vs CAST's bespoke guards (from the re-sourced docs)

Relevant to the *collapse bespoke → native* question, which is Session E's actual mandate:

- Claude Code has a **built-in, non-overridable circuit breaker on `rm`/`rmdir` targeting critical
  paths** (fs root, top-level dirs, home, cwd + parents). Real, but it does **not** generalize to the
  rest of CAST's irreversibility ledger — `git push`, force-merge, `pkill`, schema migration, DB row
  deletion are all uncovered.
- The **built-in protected-paths list is FIXED** (`.git`, `.claude`, `.mcp.json`, shell rc files) and
  does not include CAST's actual protected surfaces (`config/policies.json`, `managed-settings.d/`,
  `install.sh`). It also does **not apply to subprocess file I/O** — a Python script opening a
  protected path directly is unaffected.

**Provisional read: the bespoke guards do NOT collapse into the native surface.** The overlap is
partial and the gaps are exactly CAST's cases. The honest Session E outcome may be "keep the bespoke
guard, but fix the gate that was supposed to be proving it works" — which is E-1.
