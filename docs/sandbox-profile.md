# Sandbox-ON Supported Profile

CAST supports running Claude Code with the Bash sandbox ON (macOS Seatbelt). This page lists what works inside it, what degrades, and what needs a command typed by you at the `!` prompt, which runs outside the sandbox.

Config: `managed-settings.d/61-sandbox.json`, merged into `~/.claude/settings.json` by `install.sh`. Turn it on per session with `/sandbox`. A project `.claude/settings.local.json` with `"sandbox": {"enabled": false}` turns it off for that repo, silently.

**Positive control first.** Before you trust any sandbox result, run `touch ~/x`. It must fail with `Operation not permitted`. With the sandbox on, `$TMPDIR` is `/tmp/claude-501`, not `/var/folders/...`.

## What the sandbox allows

| Surface | Inside the sandbox |
|---|---|
| Writes | the session's working directory, `$TMPDIR`, `/tmp/claude*` |
| `~/.claude/**` | write-denied (`settings.json`, `scripts/`, `rules/`, `logs/`, `projects/`, ...) |
| `~/.claude/cast.db` | read-only (readable through `allowRead`) |
| `~/.claude/logs/` | read- and write-denied |
| `~/Projects/**/.git/worktrees`, `.githooks` | write-denied on purpose (blocks a planted `worktree prune` target) |
| Network | allowlisted domains only (`allowManagedDomainsOnly`) |
| Process list | blocked: `pgrep` exits 3, `ps` gets EPERM |
| `/dev/fd/N` opened by an external command | blocked: `diff <(…) <(…)` fails. A builtin redirect such as `cat <(…)` works. |
| `open`, `osascript` | blocked |

The Write and Edit tools are not sandboxed. Hooks run outside the sandbox, so `cast.db` rows from hooks still land.

## Workflow matrix

| Workflow | Status | Notes |
|---|---|---|
| `pre-commit` lints, plugin-drift check, stats refresh | works | Before 2026-10-11, the plugin-drift check died on `mktemp` (EPERM) and reported "plugin/ is out of sync". Fixed. |
| `commit` agent | works | The `post-commit` provenance write fails (logs/`cast.db` are denied). The unsandboxed PostToolUse hook records the row instead (verified 2026-10-12: rows exist for every commit whose agent reported "not-recorded"). |
| D5 reconcile (`pre-push`) | degrades, loudly | `audit.jsonl` is unreadable, so the result is `"status": "unverifiable"` and pre-push prints "NOT verified … push allowed". Commits made in the sandbox do not false-block a later unsandboxed push. To get a real verdict, push from your terminal. |
| `git fetch` / `ls-remote` | works | |
| `git switch` / `pull` that rewrites `.githooks/` | fails | `.githooks` is write-denied, so a checkout that changes a file there aborts part-way. Run that pull or switch with `!`. |
| Push (`CAST_PUSH_OK=1 bash scripts/cast-push.sh <branch>`) | works | Verified 2026-10-11: the pre-push hook ran in the sandbox and every gate reached a verdict (reconcile degrades as above). Before 2026-10-11 it died at its first `mktemp`. `.git/config` lock may be denied, so `--set-upstream` may not stick. |
| `gh` (PRs, checks, merge) | works | Needs `enableWeakerNetworkIsolation: true`. Verified 2026-10-11: `gh pr list` and `gh api` succeed after `install.sh`, with no restart. Without the key, gh fails with `x509: OSStatus -26276`, because the trustd lookup is blocked. The key opens only `com.apple.trustd.agent`; gh stays sandboxed. |
| `install.sh`, `cast-rules-sync.sh --apply`, `cast-merge-settings.sh` | `!` only | They write `~/.claude`. Never start them sandboxed: a partial install is worse than none. |
| BATS (`tests/run.sh`) | works, with exceptions | On Darwin, `tests/run.sh` puts `tests/helpers/bin/mktemp` first on PATH, because BSD `mktemp` ignores `$TMPDIR`. Tests that write a temp `.claude/settings.json` (Claude Code protects that name) or that hard-code `/tmp/...` still fail in the sandbox. Run the full suite with `!` or `make test-ubuntu`. |
| Python unit suite | sandbox-only failures | 2146 tests, measured 2026-10-11: 52 errors (EPERM on fixture writes to `.claude/settings.json`) and 5 guard-test failures. The failures also occur on a clean `HEAD` in the sandbox. Unsandboxed: 2146 OK. Run it with `!` before pushing. |
| `isolation: worktree` agents | read/edit only | `git add` gets EPERM on `.git/worktrees/<id>/index.lock`. Commit from the main checkout. Remove a leftover worktree with `! git worktree remove <path>`. |
| `cast-otel.sh status`, plan-doctor otel probe | degrades | A blocked process list reports "unknown" or WARN, not "not running". |
| `gen-cast-stats.sh --check`, `gen-ecosystem-versions.sh --check` | works | The verdict is a string comparison. The diff display is best-effort. |
| `launchctl list` | misleading | It shows an empty domain. CAST uses `launchctl print` instead. |
| Work repos (`~/Projects/work/*`) from a CAST session | `!` only | They are outside the write allowlist: no commits, tests, or `cros_push_qa.sh`. Bitbucket egress itself works. Start a session in that repo instead. |

## Accepted residual: `enableWeakerNetworkIsolation`

Ed chose this on 2026-10-11, and the security review approved it with a residual. The key lets sandboxed processes message the macOS trust daemon (`com.apple.trustd.agent`), which `gh` needs to verify TLS. trustd runs outside the sandbox proxy. A sandboxed process that can run code can therefore induce trustd to make OCSP, CRL, or AIA fetches to hosts that are not allowlisted. That is a blind, low-bandwidth, GET-only exfiltration side channel, and it bypasses both the domain allowlist and proxy logging.

Limits of the residual:
- The denyRead paths (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.claude/logs`, `history.jsonl`) stay unreadable. `cast.db` is readable by design.
- The allowlisted GitHub, npm, and Google domains are already a wider channel.

Rejected alternatives:
- `excludedCommands: ["gh …"]` gives gh unrestricted filesystem and network access. For example, `gh pr create --body-file <any file>` would upload any file.
- Running gh only through `!` is the safest option, and costs a manual step on every PR.

Revisit if Claude Code ships a narrower option, or if gh is no longer needed in the sandbox.

## The `!` steps

Type these at the Claude Code prompt. `!` commands run unsandboxed in most sessions.

```
! bash install.sh
! bash scripts/cast-rules-sync.sh --apply
! CAST_PUSH_OK=1 bash scripts/cast-push.sh <branch>
! git worktree remove <path>
! bash tests/run.sh
```

Auto mode has denied `CAST_PUSH_OK=1 bash scripts/cast-push.sh` as a safety-bypass flag (2026-10-09). On 2026-10-11 it allowed the command. When it denies, push with `!`.

## Related

- [Enforcement / awareness split](architecture/enforcement-awareness-split.md): why the worktree and `.githooks` denies exist.
- [Escape hatches](escape-hatches.md)
- [Known limitations](known-limitations.md)
