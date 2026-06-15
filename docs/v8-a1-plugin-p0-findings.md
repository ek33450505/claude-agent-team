# CAST v8 — Plugin P0 (`cast-mini`) Empirical Findings

**Date:** 2026-06-14 · **Method:** hand-built throwaway `cast-mini` plugin loaded via `claude --plugin-dir` (Claude Code 2.1.170), validated headlessly with `claude -p` + SessionStart marker-file probes and `claude plugin validate`.

This is the DUAL-SHIP "prove it" gate from the plugin spike (`~/.claude/plans/cast-v8-a1-plugin-spike.md` §6). All six high-doubt mechanics were validated empirically (not just from docs) before committing the real manifest.

## Tooling discovered (de-risks the whole effort)

Claude Code ships first-class plugin CLI — the empirically validated design supports BOTH local development and marketplace distribution:

> **Superseded (2026-06-14):** This research initially concluded "LOCKED: local `--plugin-dir` only, no marketplace." The shipped decision (merged to main) is **dual-ship:** both `--plugin-dir plugin` (local path) AND marketplace install (`/plugin marketplace add`) are wired and coexist. The design leverages native Claude Code support for both paths, with the `cast-hook-owner` sentinel preventing double-init. See CHANGELOG v8 entry for shipped surface.

- **`claude --plugin-dir <path>`** — load a local plugin per session (session-scoped, no persistent config mutation). This is the beta distribution mechanism.
- **`claude plugin validate <path> [--strict]`** — validates a plugin OR marketplace manifest. `--strict` fails on unrecognized fields / missing metadata. **This is the Stage 3 CI gate** (replaces hand-rolled `jq` checks).
- `claude plugin details <name>` — component inventory + projected token cost.
- `claude plugin marketplace add <path|url|repo>` / `claude plugin install <name> -s local` — marketplace-based local install (needs a `.claude-plugin/marketplace.json`).

## Validation results

| # | Mechanic | Result | Evidence |
|---|---|---|---|
| V1 | Local load without a published marketplace | ✅ | `--plugin-dir ~/cast-mini-mp/cast-mini` loaded the plugin in every headless run |
| V2 | Component auto-discovery (agent, `SKILL.md` skill, flat command, hooks, MCP) | ✅ | `claude plugin validate --strict` passed; `cast-mini:mini-echo` agent was dispatchable |
| V3 | `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_DATA}` substitution in hook command strings | ✅ | SessionStart marker: `root=<plugin-install-dir> data=~/.claude/plugins/data/cast-mini-inline` |
| V4 | PreToolUse `prompt`-type hook with `if` path filter gates a Write | ⚠️ Refined — did NOT hard-block | In headless `-p`, the prompt-type hook did **not** block a Write to `./secret-zone/blocked.txt` (both secret + normal writes succeeded). `prompt`-type hooks are **advisory** (model-evaluated), not deterministic gates. CAST's real enforcement is **command**-type (see below), which fired deterministically. No regression vs install.sh. |
| V5 | SubagentStop `command` hook fires from a plugin (CAST's most load-bearing event) | ✅ | After dispatching `cast-mini:mini-echo`, `subagent-stop.marker` was written with the plugin root |
| V6 | stdio MCP server loads from plugin + `${user_config.*}` env substitution | ✅ | MCP startup marker: `MINI_TOKEN=default-mini-token` (the manifest's userConfig default, substituted into the server env) |

**Bonus:** plugin-provided **agents are dispatchable** from the main session (namespaced `cast-mini:mini-echo`).

## Key findings that shape Stage 3

1. **A curated agents dir is *required*, not optional.** `agents/core/morning-briefing.md` declares `permissionMode: bypassPermissions`, which is illegal for plugin-shipped agents and fails `validate --strict`. Pointing the manifest at `agents/core/` (all 23) would ship an invalid agent. → `gen-plugin.sh` must emit a curated `agents/` (A6 lean keep-list, ~17), so the plugin is a **generated build artifact**, not the raw repo.
2. **Plugin commands need YAML frontmatter** (at least `description`) or they warn under `--strict`. CAST's repo `commands/*.md` are bare markdown. → the generator must add minimal frontmatter (or the CI validate runs non-strict for commands). Confirmed: adding frontmatter cleared the warning.
3. **`marketplace.json` benefits from a `description`** (warns under `--strict` without one).
4. **`${CLAUDE_PLUGIN_DATA}`** resolves to `~/.claude/plugins/data/<plugin>-inline` for `--plugin-dir` loads — a real, writable, persistent dir. Runtime state still favors `~/.claude` (doctor/backup/canary tooling points there), per spike §5.4.
5. **Manifest field set that validates clean** (`.claude-plugin/plugin.json`): `name, version, description, author{name}, hooks` (path ptr), `userConfig`, `mcpServers` (inline). `components`/`install`/`postInstall`/binary `dependencies` from the stale v7.3.1 manifest are all rejected — rewrite from scratch confirmed necessary.
6. **O1 (does `agents` accept a path array?) — moot.** Since we generate a curated `agents/` at the plugin root (default location), no `agents` override is needed at all.
7. **`command`-type hooks are the real gate; `prompt`-type hooks are advisory.** CAST's deterministic enforcement (`pre-tool-guard.sh`, `write-guards.sh`, `cast-command-guard.sh`) is all `command`-type returning exit codes — and those fired from the plugin (V3/V5). The two `prompt`-type PreToolUse hooks in `27-hooks-advanced.json` are model-evaluated advisories and behave identically (advisory) in plugin and settings form — so the plugin must carry the `command`-type guard hooks for security to hold; `gen-plugin.sh` does (it derives all hook entries from the fragments).

## Conclusion

The plugin path is proven. CAST's Claude-Code-native surface (agents, skills, commands, `command`-type hooks, stdio MCP with userConfig) all load and fire from a local `--plugin-dir` plugin, with `${CLAUDE_PLUGIN_ROOT}` substitution working in hook/MCP command strings. (`prompt`-type hooks load but are advisory, same as in settings form — CAST's deterministic gating is `command`-type and confirmed firing.) The plugin remains a thin shell over `~/.claude` state (prose-layer scripts paths can't be rewritten), so the SessionStart bootstrap + install.sh Bucket C stay as designed. Cleared to build the real generated plugin (Stage 3).
