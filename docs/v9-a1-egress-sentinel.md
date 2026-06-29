# CAST v9 · A1 — Egress / Privacy Sentinel (design + scaffold)

> **Status:** SCAFFOLD. Ed owns the design calls + the build; this doc + the
> skeleton are the advisory groundwork (research, structure, decision points).
> Branch `feature/v9-a1-egress-sentinel`. Effort: M.

## 1. What & why
A `PreToolUse` hook that **records every off-machine-bound tool call to a local
egress ledger** and can advise / ask / block when sensitive content would leave
the machine. It makes the sovereignty guarantee — *"know what leaves"* —
**enforceable, not aspirational**. Motivated directly by the GitHub-MCP
re-exposure flag (§6).

Watched surfaces (matcher `mcp__.*|WebFetch|WebSearch|Bash|Read`):
1. **Cloud-bound MCP** calls (`mcp__<server>__<tool>`), classified per-server.
2. **WebFetch / WebSearch** (URL/query + content sensitivity).
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
  event → `logs/egress.jsonl` (and optionally `cast.db`) is the sovereignty
  deliverable.
- **(b) Content sensitivity** — native gates on *tool + destination*, never on
  *what is being sent*. The sentinel inspects payloads (reuse `cast-redact.py`)
  for credentials/PII leaving the machine.
- **(c) Compound correlation** — "credential read, then `curl`, same session" is
  higher-confidence exfil than either event alone. Native sees neither in context.
- **(d) `CAST_REPO_CLASS` awareness** — work vs personal tightens thresholds;
  native has no concept of it.

> **Rule of thumb:** access control → native `permissions.deny`/`ask`.
> *Recording + content + context* → the sentinel. If `github.com` is already in a
> native WebFetch allowlist, the sentinel stays quiet unless sensitive content is
> detected.

## 3. Key design fact — classify MCP by SERVER, not transport
The live `github` MCP uses **local stdio** (`command: npx …server-github`) yet
calls `api.github.com` → it is **cloud-bound by behavior**. Transport (stdio vs
http) is therefore *not* a valid egress signal. Classification is a **named
per-server map** (`config/egress-policy.json → mcp_servers`), unknown servers
default to `cloud_bound` (fail-closed *classification*, fail-open *enforcement*).

Starting classification (Ed: confirm/extend):
- **cloud-bound:** `github`, `ms365`, `claude_ai_Gmail/Calendar/Drive`
- **local-only:** `obsidian`, `obsidian-claude`
- `claude_ai_*` are Anthropic-brokered (flagged, but Anthropic-sanctioned).

## 4. Modes & config
- **Mode** (`advisory` | `ask` | `strict`): env `CAST_EGRESS_ENFORCEMENT`
  (precedence) → `~/.claude/config/cast-cli.json` key `egress_enforcement` →
  default **`advisory`**. Mirrors the existing `CAST_PII_ENFORCEMENT` pattern.
- **Policy data:** `config/egress-policy.json` (server map, credential globs,
  network commands, host safelist, telemetry keys). Mirrors `policies.json` /
  `pii-patterns.json` split (toggle in cast-cli.json, data in config/).
- Modes:
  - **advisory (default)** — record + warn via `additionalContext`; **exit 0,
    never blocks.** This is what ships in the scaffold: useful immediately
    (it builds the egress record) and zero risk.
  - **ask** — emit `permissionDecision: "ask"` (interactive confirm) on
    `warn`/`high`.
  - **strict** — `permissionDecision: "deny"` on **high-confidence hits only**
    (Ed defines which).

## 5. ⚠ Fail-open + the headless caveat (state plainly)
- The hook **fails open**: any internal error → exit 0, logged to
  `hook-errors.log`, never interrupts work (mirrors `cast-command-guard.py`).
- **`strict` blocking is advisory-grade, not a security boundary.** Claude Code
  `PreToolUse` hooks are **bypassed in headless / managed / cron runs** (the CAST
  irreversibility rule). For hard, unattended guarantees use native
  `permissions.deny` (enforced at the API layer), not this hook. The sentinel is
  a *data-sovereignty audit + awareness* tool, not a sandbox.

## 6. ⚠ Live findings surfaced this session (§5 of the roadmap)
1. **GitHub MCP re-exposed (config drift, NOT a leaked secret):** `settings.json`
   wires `mcpServers.github`, contradicting the 2026-06-19 decision to drop it.
   **But the token is *not* on disk** — the config uses `${GITHUB_TOKEN}` (runtime
   env expansion); `GITHUB_TOKEN` is absent from `settings.json env` and the
   checked shell profiles. So: revisit *whether the server should be wired at all*
   (a policy call), not an exposed-credential emergency. → Ed's call.
2. **Todoist plaintext token** (from memory `project_github_mcp_dropped`) — still
   pending rotation/keychain. Pairs with **A2 Local Secrets Vault**.
3. **OTEL exporters** — confirm any `OTEL_EXPORTER_OTLP_ENDPOINT` points at
   `localhost` (OTEL is a *local* feed per the thesis).

## 7. Scaffolded vs. Ed-builds
**Scaffolded (works today, advisory/log-only):**
- `scripts/cast-egress-sentinel.py` — stdin parse, fail-open, mode resolution,
  4-surface classification, per-server MCP map, credential-path globbing,
  coarse bash network-command name-matching, egress-ledger recording,
  advisory/ask/deny output plumbing.
- `scripts/cast-pretool-dispatch.py` — the unified PreToolUse dispatcher that runs the egress sentinel (the former thin `cast-egress-hook.sh` shim was folded into it; removed v9 S5).
- `config/egress-policy.json` — starter policy data.
- Hook registration in `managed-settings.d/25-hooks-security.json` (inert until
  `bash install.sh`; **advisory by default**).
- `tests/cast-egress-sentinel.bats` — test surface stub.

**Ed builds (marked `TODO(ed)` in code):**
- `assess_sensitivity()` — the real decision: reuse `cast-redact.py --mode
  analyze` on outbound url/query/command payloads; define `high`-confidence
  block rules (private key / token in an outbound `curl`; `scp` of a credential
  file to a remote host).
- `_bash_network_hits()` → replace the name-match stub with the
  `cast-command-guard.py` segment tokenizer for real exfil-pipe detection
  (`cat secret | curl …`), loopback-vs-remote host parsing, and FP suppression.
- Compound correlation (credential_read → egress within a session window).
- `CAST_REPO_CLASS=work` threshold tightening.
- Optional `cast.db` egress row + a `cast egress` CLI (`--enforcement`, report).
- Decide whether to **also** add native complements, e.g.
  `"ask": ["mcp__github__*"]` or `"deny": ["WebSearch"]`, per your risk appetite.

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
- strict mode + a high-confidence rule → `permissionDecision: deny` (once Ed wires one).
- **HARD RULE:** temp-HOME isolation; no real GUI side effects.
