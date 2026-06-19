# MCP Resources/Prompts — Decision Record

**Date:** 2026-06-13
**Cycle:** CAST v8 A2 (reduced)
**Status:** CLOSED — met by native skills; no bespoke MCP server

## A2 Goal

Enable agents to auto-load reference without tool calls ("MCP resources/prompts" track).

## Decision: Already Met by Native Skills

CAST's native `skills:` frontmatter mechanism auto-loads reference material into agent
context at dispatch time with zero tool calls. `cast-conventions` and `stack-reference`
are live examples. The A2 goal is fully satisfied by this mechanism.

## Why CAST Is NOT Building a Bespoke MCP Server (This Cycle)

CAST's v8 north star is "less-bespoke, more-platform." Authoring a custom MCP server
(e.g., `cast-mcp-memory-server.py`) would be the opposite direction:

1. It requires authoring, hosting, and maintaining infra CAST does not own today.
2. The files that reference `cast-mcp-memory-server.py` (`.mcp.json.example`,
   `scripts/cast-mcp-setup-notes.md`) describe a server that was never built.
3. The only MCP server CAST uses today is the third-party `github` server.

## MCP Resources/Prompts — For Future Reference

When CAST eventually authors its own MCP server (Phase B), the resource/prompt mechanics are:

- **Resources** — expose docs/schemas as `@server:proto://path` URIs; agents can
  read them without a tool call once the MCP server is wired.
- **Prompts** — invoke as `/mcp__<server>__<prompt>` slash-commands in the session.
- Wire in `.mcp.json` at the project root; Claude Code auto-starts registered servers.

## Phase B Revisit Note

The `cast-memory` MCP entry in `.mcp.json.example` and the `cast-mcp-memory-server.py`
server design are **valid aspirational architecture** for Phase B. They should be kept
as reference, clearly marked aspirational, and not acted on until Phase B is scoped.

## Completed: thinking_budget Dead Code Removal (v8 fireproof)

Doc-verified 2026-06-13: `effort` IS a native Claude Code subagent-frontmatter field
(works on Sonnet; not Opus-only as CAST claimed). `thinking_budget:` is NOT native —
Claude Code reads no such field. The dead bespoke code has been removed in CAST v8:
`config/thinking-budgets.json` deleted, `thinking_budget:` frontmatter lines stripped from
all agent files, Check 13 in `cast-validate.sh` updated to drop the now-absent file,
and the scaffold template in `bin/cast` updated. Use native `effort:` for compute control.
