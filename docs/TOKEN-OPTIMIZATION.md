# Token Efficiency & Cost Optimization

> Extracted from [README](../README.md).

> **Phase 5 hook output compression — shipped (2026-05-08):** The hook pipeline now compresses structured tool output before it reaches the context window. Items marked `[PIPELINE]` in the table below are now handled automatically by this compression layer. Items marked `[OPEN]` remain manual or opt-in. See `scripts/post-tool-hook.sh` for implementation details.

CAST uses multiple optimization layers to reduce token spend without sacrificing output quality:

| Layer | Impact | Status |
|---|---|---|
| **Model tiering** | Haiku for reviews/commits (high-frequency), Sonnet for writing/planning — 3x cost reduction on lightweight tasks | [PIPELINE] |
| **Response budgets** | Enforced token limits per agent: 300 (lightweight), 800 (medium), 2,000 (heavy) — prevents context bloat | [PIPELINE] |
| **Ollama contractor** | Cheap agents route to local codellama/deepseek-coder; fallback to Claude if unavailable — 40-60% cost drop for local tasks | [OPEN] opt-in |
| **Orchestrate skill preamble tiers** | Full context for complex agents, minimal for lightweight agents — ~80 tokens saved per dispatch | [PIPELINE] |
| **Output compression** | Hook pipeline compresses `hookSpecificOutput` before context injection — prevents window bloat | [PIPELINE] shipped Phase 5 |
| **Laconic Mode** | `/laconic [lite\|full\|ultra\|off]` — 15-25% output reduction via terse formatting (3 intensity levels) | [OPEN] manual |
| **RTK Hook** | `scripts/cast-rtk-install.sh` — 60-89% compression on tool outputs; optional install | [OPEN] opt-in |
| **Context Audit** | `scripts/audit-context-size.sh` — measures always-loaded context; warns if >500 lines | [OPEN] manual |
| **Compact Discipline** | Auto-trigger at 40 tool calls/session — suggests `/compact` via reminder hook | [PIPELINE] |
| **Thinking Budgets** | `config/thinking-budgets.json` — per-agent extended thinking tiers (0–8192 tokens) | [PIPELINE] |

**Net result:** ~30-50% reduction in swarm token spend vs. naive multi-agent dispatch.

---

## Ollama Integration & Local Model Fallback

LiteLLM proxy with transparent Ollama fallback.

```bash
# Start LiteLLM proxy (port 8000)
scripts/cast-litellm-start.sh

# Start Ollama with recommended models
ollama pull codellama:7b
ollama pull deepseek-coder:7b
ollama pull nomic-embed-text  # for semantic search

# Route cheap agents to local models
# Model routing in managed-settings.d/25-litellm.json
```

**Routing strategy:**
- `claude-haiku-4-5` (review, commit) → local-commit (codellama) if Ollama available
- `claude-sonnet-4-6` (write, plan) → claude-sonnet-4-6 (Claude API, no fallback)
- **Fallback:** If Ollama unavailable, silently retry via Claude API

`cast.db` tracks `model` in `agent_runs` — you can measure how many tokens stayed local vs. went to Claude.

```bash
# Cost breakdown: local vs Claude
sqlite3 ~/.claude/cast.db "SELECT model, COUNT(*), SUM(input_tokens + output_tokens) AS total_tokens \
  FROM agent_runs WHERE started_at > datetime('now', '-7 days') GROUP BY model;"
```
