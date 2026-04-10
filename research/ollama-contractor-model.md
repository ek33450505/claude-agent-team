# Research: Ollama as a "Contractor" in CAST Multi-Agent Systems
**Date:** 2026-04-06
**Question:** Can Claude act as PM/orchestrator and delegate well-defined tasks to local Ollama models as cost-saving contractors? Is this a known pattern, is the metaphor sound, and how would it work in CAST?

---

## 1. Is Anyone Else Doing This?

**Yes — this is a well-established and actively growing pattern in 2025-2026.**

### Named Projects Using This Pattern

| Project | Role | Stars / Activity | Notes |
|---|---|---|---|
| [lm-sys/RouteLLM](https://github.com/lm-sys/RouteLLM) | Router framework between strong/weak models | High activity, ICLR 2025 paper | Routes to local or cheap model; escalates to GPT-4/Claude. 95% quality at 26% cost. |
| [aurelio-labs/semantic-router](https://github.com/aurelio-labs/semantic-router) | Intent-based routing to different backends | Active | Classifies requests and routes to appropriate model/action |
| [vllm-project/semantic-router](https://github.com/vllm-project/semantic-router) | Red Hat vLLM system-level router | 2,000+ stars within 2 months of launch | Uses ModernBERT to classify query complexity, routes to local or cloud |
| [BerriAI/litellm](https://github.com/BerriAI/litellm) | Unified API proxy for 100+ LLMs | Very active | Single endpoint, routes to Claude OR Ollama transparently |
| [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router) | Claude Code proxy with model switching | Active 2025 | Per-session model routing for Claude Code |
| [mattlqx/claude-code-ollama-proxy](https://github.com/mattlqx/claude-code-ollama-proxy) | Proxy to run Claude Code on Ollama | Active 2025 | Full Claude Code on Ollama local models |
| DeerFlow 2.0 | ByteDance multi-agent system | Enterprise | Supports Claude, GPT, DeepSeek, Ollama in same pipeline |
| CrewAI / AutoGen | Multi-agent frameworks | Widely used | Both are model-agnostic: each agent can use a different model |

### Research Backing

- **RouteLLM (ICLR 2025):** Matrix factorization router achieves 95% of GPT-4 performance while routing only 26% of calls to GPT-4. 85% cost reduction documented.
- **xRouter paper (arXiv 2510.08439):** Reinforcement learning-trained router, cost-aware orchestration across model tiers.
- **Industry numbers (Swfte AI / MindStudio):** Organizations using multi-model routing report 30-70% cost reductions; some achieve 85%+ for specific workloads.
- **Enterprise adoption:** Atlassian, Salesforce, Microsoft, Walmart are publicly using multi-model strategies as of 2025.

### The Active GitHub Issue That Proves Demand

[anthropics/claude-code#38698](https://github.com/anthropics/claude-code/issues/38698) — "Per-agent model provider routing (e.g. local Ollama for subagents, Anthropic for orchestrator)"

Filed April 2026, labeled `area:agents` + `area:providers` + `enhancement`. The exact feature requested is:
- Orchestrator agent stays on Anthropic API (Opus or Sonnet)
- Simple/repetitive subagents route to `llama3.3:70b` on Ollama

This is the CAST contractor model precisely. It is open, not implemented natively yet.

**Verdict: The contractor metaphor has strong legs. This is an active frontier of LLM systems architecture.**

---

## 2. What Can Ollama Realistically Handle as a CAST Contractor?

Hardware baseline: Apple Silicon M-series Mac, 8B model at Q4_K_M = ~4-5GB VRAM, 40+ tokens/sec.

### Recommended Models for Contractor Work (2025-2026)

| Model | Size | Strengths | CAST Fit |
|---|---|---|---|
| `qwen2.5-coder:7b` | 7B | Code tasks, strong at structured output | Commit msg, test stubs |
| `llama3.1:8b` | 8B | Strong function calling, general instruction following | Routing, summaries |
| `phi4:14b` | 14B | Better reasoning, moderate hardware requirement | Classification, review checklists |
| `tavernari/git-commit-message` | 8B | Purpose-built for commit messages from diffs | Commit agent replacement |

---

### Task-by-Task Honest Assessment

#### GREEN — Good candidates for local delegation

**Commit message generation from diffs**
- A purpose-built Ollama model (`tavernari/git-commit-message`) exists for exactly this.
- The task is pattern matching: diff in, formatted message out.
- No multi-step reasoning required. Well-bounded input/output.
- Risk: commits to non-obvious refactors may get vague messages. Add a review gate.

**Agent routing classification**
- Classifying "which CAST agent should handle this?" from a task description is a classic low-complexity classification problem.
- Semantic routing models (BERT-based, sub-1B) can do this well and are faster than any LLM.
- For CAST: a small model classifying `[commit | code-write | test-write | debug | research | ...]` is ideal.

**Log summarization / morning briefing data prep**
- Summarizing structured cast.db data or log files into a few bullet points is well within 7B range.
- Risk: hallucination of numbers. Always pass structured data (JSON/CSV), not raw logs, and validate numerics in the output.

**Documentation linting / formatting**
- Checking for broken markdown, missing headers, improper code fence syntax — pure pattern matching.
- Well within 3B-7B capability.

**Test stub generation (boilerplate, not logic)**
- Generating `describe('Component', () => { it('should render', () => { ... }) })` shells from a component signature is mechanical.
- Risk: generated test logic may be wrong (wrong assertions, wrong mock setup). Treat as scaffold only.

**Memory file summarization / compaction**
- Condensing a MEMORY.md file or a session log into a shorter version is a summarization task.
- Good at 8B. Risk: important nuance may be dropped. Keep original, use compacted version as secondary index.

#### YELLOW — Possible but requires validation

**Code review checklists (not deep reasoning)**
- A 7B model can match patterns: "does this function have error handling?", "is there a missing return type?", "is this variable shadowed?"
- NOT a replacement for semantic understanding. Will miss architectural issues, subtle bugs, incorrect logic.
- Use case: first-pass checklist generation for `code-reviewer` (haiku) to confirm or reject. A pre-filter, not a replacement.

#### RED — Do not delegate to local models

**Security analysis**
- Small models lack the training breadth to reliably flag SSRF, injection vectors, timing attacks, or CORS misconfigurations.
- A false-negative here has real consequences. Keep on Claude.

**Debugger agent (root cause analysis)**
- Multi-step causal reasoning across files, stack traces, and runtime state is exactly where 7B models degrade.
- They may generate plausible-sounding but wrong hypotheses. Escalation cost is debug time, not just API cost.

**Planner agent (task decomposition)**
- Breaking a complex feature request into 15-30 min units requires understanding of the full codebase context.
- Small models will produce plans that look correct but miss dependencies or create conflicting work units.

**Code-writer (complex implementation)**
- Boilerplate is fine; real implementation of multi-file features is not.
- The risk is subtle bugs that pass review but fail at runtime. Cost of the bug exceeds the cost saved.

**Any task requiring > 8K token context**
- Most 7B Ollama models can handle 8K-32K context, but degradation begins early.
- CAST tasks with full file contents + instructions can easily exceed this.

---

## 3. Architectural Fit in CAST

### Current State

CAST dispatches agents via Claude Code's Agent tool. All agents use Claude (Sonnet/Haiku), configured by `agent_type` and model fields in agent `.md` files. There is no native per-agent model routing.

The GitHub issue #38698 confirms this is not natively supported. The workaround: a proxy layer between CAST and the model endpoint.

### Option A: LiteLLM Proxy (Recommended)

```
CAST task
  → Claude (Sonnet) as PM
  → Dispatches agent with task type
  → cast-router.sh inspects task type
  → LiteLLM proxy routes:
      simple tasks → Ollama (localhost:11434)
      complex tasks → Anthropic API
```

**How it works:**
1. Run `litellm --config cast-litellm.yaml` as a local proxy on port 4000.
2. Set `ANTHROPIC_BASE_URL=http://localhost:4000` in CAST's environment.
3. LiteLLM routes based on model name: `ollama/qwen2.5-coder:7b` → Ollama, `claude-sonnet-4-6` → Anthropic.
4. No changes to Claude Code itself — it just sees a compatible endpoint.

**LiteLLM routing config example:**
```yaml
# cast-litellm.yaml
model_list:
  - model_name: claude-sonnet-4-6
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY
  - model_name: local-fast
    litellm_params:
      model: ollama/qwen2.5-coder:7b
      api_base: http://localhost:11434
  - model_name: local-commit
    litellm_params:
      model: ollama/tavernari/git-commit-message
      api_base: http://localhost:11434

router_settings:
  fallback_models: ["claude-haiku"]  # escalation gate
```

### Option B: cast-router.sh Wrapper

A simpler Bash-level approach: before calling Claude, classify task type and decide at the shell level.

```bash
# cast-router.sh — inspect task metadata and route
classify_task() {
  local task_type="$1"
  case "$task_type" in
    commit|log-summary|doc-lint|test-stub)
      echo "local";;
    *)
      echo "claude";;
  esac
}

route_task() {
  local task_type="$1"
  local task_payload="$2"
  local target
  target=$(classify_task "$task_type")

  if [ "$target" = "local" ]; then
    curl -s http://localhost:11434/api/generate \
      -d "{\"model\": \"qwen2.5-coder:7b\", \"prompt\": \"$task_payload\"}" \
    | jq -r '.response'
  else
    # fall through to existing CAST Claude dispatch
    cast_dispatch_claude "$task_type" "$task_payload"
  fi
}
```

**Limitation:** Bypasses Claude Code's Agent tool entirely. No tool use, no structured sub-agent pattern. Works for simple fire-and-forget tasks only.

### Option C: MCP Server for Ollama (Emerging)

The [mcp-llama-swap](https://github.com/oussama-kh/mcp-llama-swap) project suggests an MCP server wrapping local model inference. This would let Claude use Ollama as a tool, keeping the PM/orchestrator pattern fully intact. Status: experimental (as of April 2026).

---

### Quality Gate Pattern (Escalation)

This is the most important architectural piece. Contractor output should not go directly to commit/push without review.

**Proposed implementation:**

```
Ollama contractor output
  → Output validation (schema check, linting)
      pass → emit to next CAST stage
      fail → escalate to code-reviewer (Haiku)
           → code-reviewer rejects → escalate to original Claude agent
           → log escalation in cast.db
```

For structured outputs (commit messages, JSON configs):
- Validate format first (regex or JSON schema)
- Word count / length sanity checks
- Keyword rejection list ("I cannot", "As an AI", "I'm not sure")

For code outputs:
- Run the project's existing linter/tests as the quality gate
- If tests fail → escalate to debugger (Sonnet)

---

## 4. Cost Analysis

### CAST Token Consumption Estimates

Typical CAST agent calls (based on project patterns):
- Haiku agent (commit, review, docs): ~800-2,000 tokens per call
- Sonnet agent (code-writer, debugger, researcher): ~3,000-10,000 tokens per call

**Current monthly cost estimate (heavy CAST use, ~50 agent calls/day):**
```
30 Haiku calls/day × 1,500 avg tokens × $0.00025/1K = $0.34/day = ~$10/month
20 Sonnet calls/day × 6,000 avg tokens × $0.003/1K  = $0.36/day = ~$11/month
Total: ~$21/month
```

**With Ollama routing (40% of Haiku-class tasks → local):**
```
18 Haiku calls/day (remaining) = $6/month
12 Ollama calls/day            = $0 (local)
20 Sonnet calls/day            = $11/month
Total: ~$17/month  (~20% savings)
```

**Why the savings are modest at this scale:** CAST tasks are already agent-routed, meaning the PM model (Sonnet) handles orchestration and cheap tasks already go to Haiku at $0.25/1M input tokens. Haiku is already very cheap. The real savings emerge at high volume or if current usage is primarily Sonnet.

**At 10x scale (enterprise / high-frequency use):**
```
Baseline: ~$210/month
With 40% local routing: ~$170/month + one-time hardware if needed
```

**Bigger win: latency, not cost.** Local Ollama inference on Apple Silicon M-series delivers 40+ tokens/sec with no round-trip. For commit messages and log summaries called multiple times per session, this is perceptibly faster than API calls.

---

## 5. Tools and Frameworks Summary

| Tool | What It Does | Fit for CAST | Stars / Status |
|---|---|---|---|
| [LiteLLM](https://github.com/BerriAI/litellm) | Unified proxy for 100+ LLMs including Ollama | High — transparent proxy, no CAST code changes | Very active, widely deployed |
| [RouteLLM](https://github.com/lm-sys/RouteLLM) | Trained router between strong/weak model pairs | Medium — requires training data from CAST tasks | ICLR 2025 paper, active |
| [aurelio-labs/semantic-router](https://github.com/aurelio-labs/semantic-router) | Intent-based routing via embeddings | Medium — classifies task type, routes to local or cloud | Active, 5K+ stars |
| [vllm/semantic-router](https://github.com/vllm-project/semantic-router) | Red Hat system-level intelligent routing | Low for CAST (designed for inference servers) | 2,000+ stars, 2025 |
| [claude-code-router](https://github.com/musistudio/claude-code-router) | Claude Code proxy with per-session model switching | High — designed exactly for this | Active 2025 |
| CrewAI | Multi-agent framework, per-agent model assignment | Low — not built on Claude Code Agent tool | Widely used |
| AutoGen | Same, mix-and-match model per agent | Low — separate framework from CAST | Widely used |

---

## 6. Recommended Implementation Path for CAST

### Phase 1: Zero-cost tasks (no new infrastructure)
- Replace `commit` agent (haiku) invocations for simple diffs with a direct `curl` to Ollama's `/api/generate`.
- Model: `tavernari/git-commit-message` (8B, purpose-built).
- Add length/format validation. Escalate to haiku on failure.
- Expected savings: minimal cost, maximum speed improvement.

### Phase 2: LiteLLM proxy (routing infrastructure)
- Install LiteLLM as a local proxy.
- Add `cast-litellm.yaml` config to the repo.
- Set `ANTHROPIC_BASE_URL=http://localhost:4000` in CAST startup.
- Route `local-fast` model to Ollama for morning briefing, log summary, doc lint tasks.
- This requires no changes to agent `.md` files — just model name conventions.

### Phase 3: Quality gate integration
- Add a `cast-validate.sh` that checks Ollama output before passing to the next stage.
- Log all escalations to `cast.db` with model used, escalation reason, final outcome.
- Use escalation data to tune which tasks truly belong local vs cloud.

### Phase 4: Semantic classifier (optional, high-ROI at scale)
- Train or fine-tune a small BERT/embedding model on CAST task history from `cast.db`.
- Feed it task descriptions → outputs routing decision.
- Replaces manual case-statement routing with learned routing.

---

## Key Conclusions

1. **The contractor metaphor is sound and well-precedented.** Multiple production systems use exactly this pattern. The vocabulary is different (model tiering, smart routing, hybrid inference) but the architecture is identical.

2. **The cost savings for CAST at current scale are real but modest (~15-25%)** because Haiku already handles cheap tasks. The latency win for local inference is the stronger argument.

3. **Commit messages and log summaries are the best first targets.** Low risk, bounded output, measurable quality, existing purpose-built models.

4. **Never delegate: security analysis, root cause debugging, planning, complex code generation.** These require capabilities that 7B models simply do not have reliably.

5. **LiteLLM is the highest-leverage starting point.** It acts as a transparent proxy between CAST and model backends, requires no changes to Claude Code agent definitions, and supports gradual rollout.

6. **Claude Code does not natively support per-agent model routing (as of April 2026).** Issue #38698 is open. The LiteLLM proxy workaround is the practical path until that feature ships.

---

## Sources

- [Claude Code + Ollama official docs](https://docs.ollama.com/integrations/claude-code)
- [LiteLLM + Ollama routing implementation guide](https://medium.com/@michael.hannecke/implementing-llm-model-routing-a-practical-guide-with-ollama-and-litellm-b62c1562f50f)
- [anthropics/claude-code#38698 — per-agent model routing request](https://github.com/anthropics/claude-code/issues/38698)
- [RouteLLM GitHub](https://github.com/lm-sys/RouteLLM)
- [RouteLLM paper (ICLR 2025)](https://arxiv.org/abs/2406.18665)
- [aurelio-labs/semantic-router](https://github.com/aurelio-labs/semantic-router)
- [vLLM Semantic Router blog](https://blog.vllm.ai/2025/09/11/semantic-router.html)
- [LiteLLM GitHub](https://github.com/BerriAI/litellm)
- [claude-code-router](https://github.com/musistudio/claude-code-router)
- [claude-code-ollama-proxy](https://github.com/mattlqx/claude-code-ollama-proxy)
- [Intelligent LLM Routing: 85% cost reduction](https://www.swfte.com/blog/intelligent-llm-routing-multi-model-ai)
- [Red Hat LLM Semantic Router article](https://developers.redhat.com/articles/2025/05/20/llm-semantic-router-intelligent-request-routing)
- [Best Ollama models for developers 2025](https://collabnix.com/best-ollama-models-for-developers-complete-2025-guide-with-code-examples/)
- [tavernari/git-commit-message on Ollama](https://ollama.com/tavernari/git-commit-message)
- [xRouter paper (arXiv 2510.08439)](https://arxiv.org/html/2510.08439v1)
