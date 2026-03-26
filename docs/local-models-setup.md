# CAST Local Models Setup

This guide covers pulling the Ollama models used by Phase 7b's agent routing tier.

## Prerequisites

Install Ollama: https://ollama.com/download

Verify it's running:
```bash
curl -s http://localhost:11434/api/tags | python3 -m json.tool
```

---

## Model Pull Commands

Pull models in tier order — start small, verify, then pull larger ones.

```bash
# Hot-path router (~1 GB) — pull first, used for real-time classification
ollama pull qwen3:1.7b

# Lightweight agents (~4.7 GB) — commit, structured output tasks
ollama pull qwen2.5-coder:7b

# General agent work (~5.2 GB) — chain-reporter, verifier, report-writer, meeting-notes
ollama pull qwen3:8b

# Heavy reasoning / debugging (~9 GB, 128K context)
ollama pull deepseek-r1:14b

# Code review + security (~15 GB, SWE-bench 65.8%) — largest model
ollama pull devstral:24b

# Embeddings for semantic routing (~475 MB) — pull last, upgrade from nomic-embed-text
ollama pull nomic-embed-text-v2-moe
```

After pulling the embedding model, regenerate agent embeddings:
```bash
./scripts/cast-embed-agents.sh
```

---

## Hardware Requirements

| Model | RAM/VRAM | Load Time | Notes |
|---|---|---|---|
| `qwen3:1.7b` | ~2 GB | <3s | Hot-path only; always keep warm |
| `qwen2.5-coder:7b` | ~5 GB | 5–10s | Good on M2/M3 8 GB unified |
| `qwen3:8b` | ~6 GB | 5–15s | Workhorse tier |
| `deepseek-r1:14b` | ~10 GB | 10–20s | Needs 16 GB+ RAM/VRAM |
| `devstral:24b` | ~16 GB | 15–30s | Needs 24 GB+ unified or dedicated GPU |
| `nomic-embed-text-v2-moe` | <1 GB | <2s | Embedding only, always fast |

**M-series Mac guidance:**
- M2/M3 8 GB: run up to `qwen3:8b` comfortably; skip `devstral:24b`
- M2/M3 Pro 16 GB: all models except `devstral:24b` at reduced speed
- M2/M3 Max 32 GB+: full stack including `devstral:24b`

**Linux (NVIDIA):**
- 8 GB VRAM: qwen3 tier only
- 16 GB VRAM: deepseek-r1:14b
- 24 GB VRAM: full stack

---

## Escalation Ladder

CAST routes through this ladder from cheapest to most capable:

```
local:qwen3:1.7b  →  local:qwen3:8b  →  local:devstral:24b
     ↓                    ↓                     ↓
cloud:haiku        →  cloud:haiku      →  cloud:sonnet
```

If a local model isn't available, `cast-model-resolver.sh` falls back to the `model_fallback:` value in the agent definition. No agent task is ever blocked by a missing local model.

---

## Verify Installation

Run the health check to populate the availability cache:
```bash
./scripts/cast-ollama-health.sh
cat ~/.claude/config/ollama-available.json | python3 -m json.tool
```

Test model resolution for a specific agent:
```bash
./scripts/cast-model-resolver.sh commit
./scripts/cast-model-resolver.sh debugger 800
./scripts/cast-model-resolver.sh planner
```

---

## Performance Notes (M-series Mac)

These are rough benchmarks on M3 Pro 18 GB:

| Model | Tokens/sec | First-token latency |
|---|---|---|
| `qwen3:1.7b` | ~120 tok/s | ~0.5s |
| `qwen3:8b` | ~55 tok/s | ~1.5s |
| `deepseek-r1:14b` | ~25 tok/s | ~3s |
| `devstral:24b` | ~12 tok/s | ~5s |

`devstral:24b` at 12 tok/s produces ~1800 tokens/minute — typical code review (~600 tokens) completes in ~20 seconds. This is fast enough for non-interactive post-commit review but too slow for real-time hot-path routing.
