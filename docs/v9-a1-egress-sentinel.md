# CAST v9 · A1 — Egress Audit Record (log-only)

> **Status:** SHIPPED (log-only). This is a log-only egress audit record —
> advisory by design. It records every off-machine-bound tool call to
> `logs/egress.jsonl` and never blocks or asks.
> Branch `feature/v9-a1-egress-sentinel`.

## 1. What & why
A `PreToolUse` hook that **records every off-machine-bound tool call to a local
egress ledger**. It makes the sovereignty guarantee — *"know what leaves"* —
**observable**: a local record of what leaves the machine (NOT enforcement).
Motivated directly by the GitHub-MCP re-exposure flag (§6).

Watched surfaces (matcher `mcp__.*|WebFetch|WebSearch|Bash|Read`):
1. **Cloud-bound MCP** calls (`mcp__<server>__<tool>`), classified per-server.
2. **WebFetch / WebSearch** (URL host/path — query/tokens never stored).
3. **Bash network egress** (`curl`/`wget`/`scp`/`rsync`/`ssh`/`nc`… carrying data).
4. **Credential reads** (`Read`/`cat` of `.env`, `~/.ssh/id_*`, `*.pem`, token files).

## 2. The native-first boundary (honor the thesis)
Native Claude Code already does **coarse access control** — use it, don't
reinvent it (all doc-verified via `claude-code-guide`):

| Native mechanism | Covers | Syntax |
|---|---|---|
| `permissions.deny` / `ask` on MCP server | block/confirm an entire server or tool | `"deny": ["mcp__github"]`, `"ask": ["mcp__github__create_*"]` |
| `WebFetch(domain:…)` | allow/deny by destination domain | `"deny": ["WebFetch(domain:*.evil.com)"]` |
| `WebSearch` (blunt only) | block the tool entirely | `"deny": ["WebSearch"]` — **no domain/query rule exists** |
| `Read(**/.env)` | block reading a path | `"deny": ["Read(**/.env)"]` |

**The sentinel's NET-NEW value** (what native cannot do) is exactly the v9 thesis:
- **(a) Local audit record** — native permissions keep no record. Every egress
  event → `logs/egress.jsonl` is the sovereignty deliverable.

Content inspection, credential→egress correlation, and repo-class tightening were
considered for a future enforcement build but are intentionally NOT implemented —
this surface is log-only.

> **Rule of thumb:** access control → native `permissions.deny`/`ask`.
> Local record of what leaves → this sentinel.

## 3. Key design fact — classify MCP by SERVER, not transport
The live `github` MCP uses **local stdio** (`command: npx …server-github`) yet
calls `api.github.com` → it is **cloud-bound by behavior**. Transport (stdio vs
http) is therefore *not* a valid egress signal. Classification is a **named
per-server map** (`config/egress-policy.json → mcp_servers`), unknown servers
default to `cloud_bound` (fail-closed *classification*; log-only — no enforcement).

Starting classification (Ed: confirm/extend):
- **cloud-bound:** `github`, `ms365`, `claude_ai_Gmail/Calendar/Drive`
- **local-only:** `obsidian`, `obsidian-claude`
- `claude_ai_*` are Anthropic-brokered (flagged, but Anthropic-sanctioned).

## 4. Behavior & config
There is a single behavior: **log-only advisory**. The sentinel records every
off-machine-bound call to `logs/egress.jsonl` and emits an advisory
`additionalContext` line on notable surfaces (severity `warn`). It never blocks,
never asks, and exits 0 unconditionally.

- **Policy data:** `config/egress-policy.json` (server map, credential globs,
  network commands, host safelist). This is the only config knob — no enforcement
  mode, no env override, no cast-cli.json key.

## 5. ⚠ Fail-open + the headless caveat (state plainly)
- The hook **fails open**: any internal error → exit 0, logged to
  `hook-errors.log`, never interrupts work (mirrors `cast-command-guard.py`).
- Claude Code `PreToolUse` hooks are **bypassed in headless / managed / cron
  runs** (the CAST irreversibility rule). The sentinel is a *log-only
  data-sovereignty audit* tool, not a sandbox. Hard egress / credential /
  filesystem enforcement is the OS sandbox + native `permissions.deny`.

## 6. ⚠ Live findings surfaced this session (§5 of the roadmap)
1. **GitHub MCP re-exposed (config drift, NOT a leaked secret):** `settings.json`
   wires `mcpServers.github`, contradicting the 2026-06-19 decision to drop it.
   **But the token is *not* on disk** — the config uses `${GITHUB_TOKEN}` (runtime
   env expansion); `GITHUB_TOKEN` is absent from `settings.json env` and the
   checked shell profiles. So: revisit *whether the server should be wired at all*
   (a policy call), not an exposed-credential emergency. → Ed's call.
2. **Todoist plaintext token — RESOLVED 2026-06-28:** the unused `mcpServers.todoist`
   entry + plaintext token were removed from `~/.claude/.claude.json` (live config now
   has zero todoist refs). Optional leftover: revoke the old token Todoist-side.
3. **OTEL exporters** — confirm any `OTEL_EXPORTER_OTLP_ENDPOINT` points at
   `localhost` (OTEL is a *local* feed per the thesis).

## 7. Scaffolded vs. Ed-builds
**Scaffolded (works today, advisory/log-only):**
- `scripts/cast-egress-sentinel.py` — stdin parse, fail-open, 4-surface
  classification, per-server MCP map, credential-path globbing, shell-aware bash
  network-command detection (segment/quote-correct via cast-command-guard.py's
  tokenizer — exfil-pipe + re-exec-wrapper aware, with false-positive suppression
  for network names inside quoted strings; #343), egress-ledger recording,
  advisory output (record + warn).
- `scripts/cast-pretool-dispatch.py` — the unified PreToolUse dispatcher that runs the egress sentinel (the former thin `cast-egress-hook.sh` shim was folded into it; removed v9 S5).
- `config/egress-policy.json` — starter policy data.
- Hook registration in `managed-settings.d/25-hooks-security.json` (inert until
  `bash install.sh`; **advisory by default**).
- `tests/cast-egress-sentinel.bats` — test surface stub.

**Intentionally NOT built (log-only by decision):**
The following were considered and deliberately left out to keep this surface
log-only. A future enforcement build could revisit them:
- Content inspection (payload scanning via `cast-redact.py`)
- Strict/ask blocking (`permissionDecision: deny/ask`)
- Compound correlation (credential read → egress within a session window)
- Repo-class threshold tightening (`CAST_REPO_CLASS=work`)
- `cast.db` egress row + `cast egress` CLI

## 8. Prior art (brief)
Classic DLP (MyDLP/OpenDLP/Symantec) = content inspection + context
classification + structural labels. The sentinel maps cleanly: `cast-redact.py`
= content inspector, surface detection = context classifier, `CAST_REPO_CLASS` =
structural label. The most borrowable pattern is **compound-event correlation**
(read-then-send) to keep false positives low — the same trick CrowdStrike/Carbon
Black use for exfil detection. Nextcloud's 2025 ICAP DLP is the closest
local-first analog (intercept-before-send, inspect, allow/block) and confirms the
`PreToolUse`-intercept shape is sound.

## 9. Test surface (stub → Ed/​`test-writer` fills)
- advisory mode: `warn` event → exit 0 + `additionalContext` emitted, ledger line written.
- fail-open: garbage stdin / missing policy → exit 0, no crash.
- MCP classification: `mcp__github__*` → recorded; `mcp__obsidian__*` → silent.
- credential read: `Read ~/.ssh/id_rsa` → `credential_read` event.
- bash: `curl localhost` safelisted-host (no warn) vs `curl https://evil.tld` (warn).
- **HARD RULE:** temp-HOME isolation; no real GUI side effects.
