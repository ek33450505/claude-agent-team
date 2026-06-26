# Local Cheap Mode — `cast cheap`

## What It Is

`cast cheap` launches a **fully-local** Claude Code session via [claude-code-router](https://github.com/musistudio/claude-code-router) (ccr) + Ollama. Sensitive code stays on your machine; personal spend drops. Opt-in whole-session mode for prose/review/documentation work — **NOT** for complex agentic tool loops (7B models lack the fidelity).

## Why Use It?

- **Privacy:** Sensitive code never leaves the machine.
- **Cost:** Replaces cloud LLM calls with local models.
- **Tied to cost goals:** Cuts personal spend before the Jul-10 5x-Max cap reduction.

## Setup

### Requirements

1. **ccr** (claude-code-router):
   ```bash
   npm install -g @musistudio/claude-code-router
   ```

2. **Ollama** with the model pulled:
   ```bash
   ollama pull qwen2.5:7b
   ```

3. **Ollama running:**
   ```bash
   ollama serve  # or use auto-launch via cast-ollama-ensure.sh
   ```

### Configuration

CAST automatically deploys a ccr config template to `~/.claude-code-router/config.json` during `install.sh`. The default routes to Ollama's `qwen2.5:7b`.

**Regenerate or repair the config:**
```bash
cast cheap config
```

This backs up the existing config and installs a fresh one from the CAST template (`config/cast-ccr-config.json`).

**Environment overrides:**
- `CAST_CCR_CONFIG` — path to ccr config (default: `~/.claude-code-router/config.json`)
- `CAST_OLLAMA_URL` — Ollama API base URL (default: `http://localhost:11434`)

## Usage

### Launch a Local Session

```bash
cast cheap                    # Start a local ccr session (runs preflight checks)
cast cheap "fix the bug"      # Pass a prompt directly
```

### Health Checks

```bash
cast cheap status             # Show ccr + Ollama health (config, model presence, warnings)
cast cheap check              # Quiet one-line verdict (used by `cast doctor`)
```

## Caveats

**Tool-Call Fidelity:** 7B models break tool-heavy agentic loops. Use `cast cheap` for:
- Code review (prose-only)
- Documentation edits (prose-only)
- Exploration (lightweight read/grep)

**Do NOT use for:**
- Complex CAST multi-agent work (dispatch still routes to Anthropic)
- Tasks requiring Opus/Sonnet capability (debugger, code-writer on hard problems, planner, researcher)
- Anything with heavy tool use or agentic iteration

**Ollama Silent Failure:** Ollama's curl-timeout default can mask network issues. Keep `LOG: true` in your ccr config and monitor `~/.claude-code-router.log`.

**Cloud Models:** Never configure a `:cloud` model (e.g., `ollama-community/gpt4:cloud`). The preflight and `cast doctor` reject them — they leave the machine.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `ccr not found` | `npm install -g @musistudio/claude-code-router` |
| Ollama not reachable | `ollama serve` (in another terminal) |
| Config not found | `cast cheap config` |
| Model not present | `ollama pull qwen2.5:7b` |
| Config targets mlx-server | `cast cheap config` (retired; regenerate) |
| Model is :cloud | Edit `~/.claude-code-router/config.json`, remove `:cloud` suffix |

## See Also

- CAST cost goals: `docs/cost-optimization.md` (if exists) or memory entry `project_cost_goal_clarified.md`
- ccr config template: `config/cast-ccr-config.json`
- ccr docs: https://github.com/musistudio/claude-code-router
- Ollama: https://ollama.ai
