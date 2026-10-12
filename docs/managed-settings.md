# Managed Settings (G5)

CAST's self-protection deny rules and core guard hooks can be installed as a root-owned Claude Code managed settings file. Source: `macos/managed-settings.json`.

## What moves and why

- Managed settings are the top-precedence scope. `permissions.deny` and `hooks` merge across scopes, and a managed deny cannot be overridden by a lower-scope allow ([managed-settings](https://code.claude.com/docs/en/managed-settings), [permissions](https://code.claude.com/docs/en/permissions)).
- `disableAllHooks` in user/project/local settings cannot disable managed hooks; only a managed-level setting can ([hooks](https://code.claude.com/docs/en/hooks)).
- `ConfigChange` cannot block `policy_settings` changes ([hooks](https://code.claude.com/docs/en/hooks)), so protection of the file comes from OS ownership. Agents cannot edit a root-owned file.

Contents: the destructive-`rm` home-directory denies, the `Edit(...)` self-protection denies (including `Edit(//Library/Application Support/ClaudeCode/**)`), the `ConfigChange` guard, and the `cast-pretool-dispatch` and `cast-write-guards` PreToolUse hooks. The file is hand-maintained and verified against a document derived from the user fragments: all `11-deny.json` entries except `Agent(model:...)`, `pkill` and `killall`, plus the hooks above, plus the extra deny `Edit(//Library/Application Support/ClaudeCode/**)`, which is added in code. The source check is key-order sensitive (stricter), while the `FLOOR_SHA256` floor (a hash of the canonical, key-sorted JSON) ignores object key order.

## What stays in user fragments

`managed-settings.d/` is unchanged. Duplicates are kept as defense in depth. Policy denies and the `cast-audit-hook.sh` telemetry hooks were deliberately not moved.

## Install (human only)

```bash
python3 -I scripts/cast-managed-settings-verify.py --print-install
```

Run from a COMMITTED, clean tree and read `macos/managed-settings.json` first. Run in a separate terminal, not via `!` inside Claude, then `sudo -k`. It runs the source checks, then prints (never runs) short lines: `SRC=` and `DEST=` assignments, then `sudo mkdir -p`, `sudo install -o root -g wheel -m 0644 "$SRC" "$DEST"` and `sudo -k`. Paste them as printed (one long line wrapped on paste and failed).

## Verify

```bash
python3 -I scripts/cast-managed-settings-verify.py          # source + installed
python3 -I scripts/cast-managed-settings-verify.py --source # source only
```

`/status` "Setting sources" should list "Enterprise managed settings (file)" ([settings](https://code.claude.com/docs/en/settings)).

## Limits

- A malformed managed file blocks startup; an unreadable (e.g. 600) file is silently skipped; source priority is first-wins remote > plist > file, so a plist or remote source shadows the file ([managed-settings](https://code.claude.com/docs/en/managed-settings)). Always run `--source` first.
- The hooks run user-owned scripts resolved via PATH (`python3`, `bash`) and HOME (`~`). Anyone who can change PATH/HOME/env or the scripts defeats the guard; the managed layer does not fix that. Accepted residual (2026-10-12): absolute paths were not adopted. Whatever can set Claude Code's env (e.g. project settings `env`) can usually also add project hooks or edit the user-owned scripts, and a bare `/usr/bin/python3` without the Command Line Tools is a shim that would make the guard fail open (only exit 2 blocks). Boundary: the managed layer keeps the denies and guard-hook entries out of reach of user/project settings files; it does not protect against code running as the user.
- Bash/MCP write paths to `~/.claude/scripts` are not covered by `Edit()` denies; only the user-owned dispatcher and the OS sandbox hold them.
- UNVERIFIED: that `Edit()` denies cover Write/NotebookEdit (live probe pending), and whether identical user and managed hooks run twice.
- The source file and verifier are agent-writable: install only from a committed tree, after reading the file.
- Trust root: the repo fragments and source file. The verifier's floor (`FLOOR_SHA256`, the sha256 of the canonical JSON) pins the entire managed document: every deny in order and both hook events, type-exact. Any change to the denies or guard hooks requires editing 3 places in one reviewed diff: the fragment, `macos/managed-settings.json`, and `FLOOR_SHA256` in the verifier. After a legitimate change, get the new value with `python3 -I scripts/cast-managed-settings-verify.py --print-floor-hash`. That flag only hashes (it does not validate against the fragments), so run `--source` first, and update the pin only in a reviewed diff. The repo remains the trust root.
- The verifier checks mode, owner and ACLs on the file and its immediate parent only. `--print-install` runs source checks only.

## Recovery

- Managed file misbehaving: `sudo rm "/Library/Application Support/ClaudeCode/managed-settings.json"`.
- `~/.claude/scripts` missing: the managed PreToolUse hook exits 2 and blocks every tool call. Fix from a plain terminal with `bash install.sh` (no sudo needed).

## Change workflow

Edit the source, run `--source`, have the human re-run the install, then run the verifier. Any change to the `11-deny` or `25-hooks-security` fragments makes `--source` fail until `macos/managed-settings.json` is updated by hand, together with `FLOOR_SHA256` in `scripts/cast-managed-settings-verify.py`, until `--source` passes, and reinstalled.
