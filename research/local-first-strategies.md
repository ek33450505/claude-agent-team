# CAST Local-First Strategy Research
**Date:** 2026-04-06
**Author:** researcher agent
**Question:** What additional steps can CAST take to increase its local-first approach for data protection and offline use?

---

## Summary Table — All Recommendations Ranked by Impact and Feasibility

| # | Area | Tool/Approach | Impact | Feasibility | Effort | Priority |
|---|------|--------------|--------|-------------|--------|----------|
| 1 | Offline AI | Ollama + MLX (Apple Silicon) | High | High | Medium | P1 |
| 2 | Encrypted Storage | `age` + Secure Enclave plugin | High | High | Low | P1 |
| 3 | Local Search | SQLite FTS5 (already in DB) | High | High | Low | P1 |
| 4 | Local Backups | `sqlite3_backup` API + git config versioning | High | High | Low | P1 |
| 5 | Offline Packages | pnpm store + `brew fetch` pre-cache | Medium | High | Low | P2 |
| 6 | Network-Aware Mode | Shell `ping` gate + file-based queue | Medium | High | Low | P2 |
| 7 | Encrypted Storage | SQLCipher for cast.db | High | Medium | Medium | P2 |
| 8 | Local-First Sync | cr-sqlite (if multi-device needed) | Medium | Medium | High | P3 |
| 9 | Privacy Telemetry | Local-aggregate + opt-in export | Low | Medium | Medium | P3 |
| 10 | Offline AI | llama.cpp small model for routing | Medium | Medium | High | P3 |

---

## 1. Offline AI / LLM Capabilities

**Goal:** Supplement or replace Claude for lightweight tasks (routing, summarization, classification) when offline.

### 1a. Ollama + MLX (Apple Silicon) — RECOMMENDED

- **What:** Ollama is a local model server with a REST API. As of v0.19 (March 2026), it uses Apple's MLX framework on Apple Silicon, delivering 57% faster prefill and 93% faster decode vs. prior versions. Sustained throughput reaches ~230 tokens/sec on M-series chips.
- **Models suited for CAST tasks:** `phi3:mini` (3.8B, runs on 8GB RAM), `qwen2.5:3b`, `llama3.2:3b`. All run via `ollama run <model>`.
- **Tool/function calling:** Ollama's REST API supports structured tool calls via `message.tool_calls`. The `ollama` npm package provides JS/TS bindings. CAST's Express backend can POST to `http://localhost:11434/api/chat`.
- **Realistic CAST use cases:**
  - Agent routing classification ("is this a code task or a docs task?") — phi3:mini handles this at ~2-4B params
  - Memory summarization for MEMORY.md compaction when offline
  - Log summarization for morning briefings without hitting Anthropic API
- **Limitations:** Complex multi-step reasoning and code generation remain weak at small model sizes. Ollama recommends 32GB+ RAM for larger models.
- **Installation:** `brew install ollama` — fits CAST's Homebrew distribution model perfectly.
- **Stars:** 130k+ on GitHub. Weekly downloads: very high. Last updated: March 2026. Maturity: Production-ready.
- **Feasibility:** HIGH

**Concrete implementation steps:**
1. Add `ollama` as an optional dependency check in `cast status`
2. Create `~/.claude/scripts/cast-offline-llm.sh` that POSTs to Ollama's API
3. Add a `CAST_OFFLINE_MODEL` env variable (default: `phi3:mini`)
4. In `cast-events.sh`, detect `ANTHROPIC_API_KEY` absence and fall back to Ollama for summarization tasks
5. Add Ollama to the Brewfile in the homebrew-cast tap

### 1b. llama.cpp — Alternative / DIY

- **What:** C++ inference engine, runs GGUF quantized models directly. No server daemon required — just a binary.
- **Pros:** Smallest footprint, no background service, runs fully air-gapped.
- **Cons:** No built-in tool calling API in shell context. Integration requires more glue code than Ollama.
- **Best fit for CAST:** Embedded one-shot classification in Bash scripts via `llama-cli --prompt`.
- **Feasibility:** MEDIUM (more integration work, good for truly air-gapped scenarios)

### 1c. Apple MLX Direct — Advanced

- **What:** Apple's own ML framework. Can run Phi-3, Mistral, Gemma directly via Python with `mlx-lm`.
- **Pros:** Best raw performance on Apple Silicon (unified memory architecture).
- **Cons:** Python-only, adds a heavy Python dep to CAST's Bash-first stack.
- **Feasibility:** LOW for CAST core (fits better as an optional advanced feature)

---

## 2. Local-First Data Sync & Conflict Resolution

**Goal:** If CAST is ever used across multiple machines, keep data consistent without a cloud service.

### 2a. cr-sqlite — RECOMMENDED for CAST

- **What:** A SQLite extension from vlcn.io that adds CRDT semantics to regular SQLite tables. Works by adding metadata tables and triggers — no schema changes required.
- **npm package:** `@vlcn.io/crsqlite` — works with `better-sqlite3` (CAST's current driver).
- **CRDT types:** Last-write-wins, fractional index, counter CRDTs for columns.
- **CAST fit:** `cast.db` schema (sessions, agent_runs, routing_events, hook_health) maps well to LWW semantics. Syncing between a desktop and laptop dev environment would "just work" without a server.
- **Stars:** 6k+ on GitHub. Actively maintained. Last update: 2025.
- **Feasibility:** MEDIUM (requires schema migration and extension loading; valuable but only needed if multi-device use becomes a requirement)

### 2b. Automerge 3.0

- **What:** CRDT library for JSON documents. v3.0 (2025) cut memory usage from 700MB to 1.3MB for large documents.
- **Best fit:** Agent memory files (MEMORY.md, markdown) rather than the SQLite observability DB.
- **Feasibility:** LOW for CAST now — markdown files don't need merge conflict resolution at CAST's scale. Git handles this fine.

### 2c. Yjs

- **What:** High-performance CRDT for collaborative text. Binary encoding, garbage collection.
- **Best fit:** Rich text collaboration features — not CAST's use case.
- **Feasibility:** LOW (overkill for CAST's file-based memory)

**Recommendation:** Skip CRDTs for now. If multi-device use becomes a requirement in a future version, cr-sqlite is the right integration point because CAST already uses `better-sqlite3`.

---

## 3. Encrypted Local Storage

**Goal:** Protect `cast.db` and agent memory files at rest against unauthorized access.

### 3a. `age` + `age-plugin-se` (Apple Secure Enclave) — RECOMMENDED for files

- **What:** `age` is a minimal, modern CLI encryption tool (Go, by Filippo Valsorda). Keys are X25519 or SSH keys. The `age-plugin-se` plugin binds decryption to the Mac's Secure Enclave, controlled by Touch ID.
- **Command:** `age -r <recipient-pubkey> -o memory.md.age memory.md`
- **CAST fit:** Encrypt `~/.claude/agent-memory-local/` and `~/.claude/plans/` at rest. Decrypt on-demand via Touch ID.
- **Secure Enclave binding:** Private key cannot leave the device — hardware guarantee.
- **Installation:** `brew install age` (fits existing Homebrew model). Plugin: `brew install age-plugin-se`.
- **Stars:** 17k+ on GitHub. Stable v1.0 release. Actively maintained.
- **Feasibility:** HIGH — minimal integration, huge security win for agent memory files.

**Concrete steps:**
1. Add `cast secure` subcommand that runs `age` encryption over `~/.claude/agent-memory-local/`
2. Store the Secure Enclave public key in `~/.claude/cast-security.pub`
3. Decrypt at agent startup with `age --decrypt -i se:<key-handle>`
4. Document the workflow in CAST README

### 3b. SQLCipher for cast.db

- **What:** SQLite fork with AES-256 encryption for the entire database file. 5-15% performance overhead.
- **Node binding:** `@journeyapps/sqlcipher` (npm) — drop-in replacement for `better-sqlite3`.
- **Key management:** Derive key from macOS Keychain via `security find-generic-password -s cast`.
- **Pros:** Transparent encryption — SQL queries work identically.
- **Cons:** Requires migrating away from `better-sqlite3` to a different binding; adds a compiled native module.
- **Stars:** 6.5k on GitHub. Used by WhatsApp, 1Password, Signal.
- **Feasibility:** MEDIUM — high value but requires dependency surgery on the dashboard's Express backend.

### 3c. macOS Keychain for secrets only

- **What:** Use macOS `security` CLI to store encryption keys and API key references rather than `.env` files.
- **Command:** `security add-generic-password -s cast -a cast -w "$SECRET"`
- **CAST fit:** Store `ANTHROPIC_API_KEY` reference and any future encryption key handles in Keychain instead of shell env files.
- **Feasibility:** HIGH — pure Bash, no new dependencies, immediate improvement to secret hygiene.

---

## 4. Offline Package / Dependency Management

**Goal:** Make CAST installable and runnable without internet access.

### 4a. pnpm Offline Store — RECOMMENDED for dashboard

- **What:** pnpm stores packages in a content-addressable global store. `pnpm install --offline` uses the store without any network requests.
- **Workflow:** Run `pnpm install` once online to populate the store, then copy `~/.local/share/pnpm/store` to offline environments.
- **Config:** Add `prefer-offline=true` to `.npmrc` for the dashboard.
- **Feasibility:** HIGH — nearly zero effort, immediate benefit for air-gapped workflows.

### 4b. Homebrew Bottle Pre-caching

- **What:** `brew fetch <formula>` downloads and verifies the bottle (binary package). Bottles live in `~/Library/Caches/Homebrew/`. `brew install` uses the cache without network if the bottle exists.
- **CAST workflow:**
  1. Distribute a script: `cast prefetch` that runs `brew fetch` for all CAST dependencies
  2. For the homebrew-cast tap, use `brew bundle dump` to generate a `Brewfile`
  3. Users can run `brew bundle --no-upgrade` offline
- **Feasibility:** HIGH — already within the Homebrew model CAST uses.

### 4c. pip Offline for Python Dependencies

- **What:** `pip download -d ./vendor <package>` downloads wheels to a local dir. `pip install --no-index --find-links=./vendor <package>` installs without network.
- **CAST Python scripts:** `cast-redact.py`, `cast-db-log.py`, `cast-memory-router.py` — all use stdlib only (no pip deps currently). This is a non-issue for CAST now.
- **Feasibility:** HIGH (if Python deps ever added), N/A (currently no pip deps in CAST)

---

## 5. Local-First Search & Indexing

**Goal:** Fast search across agent memory (markdown files), logs, and cast.db records.

### 5a. SQLite FTS5 (Already in cast.db) — RECOMMENDED, immediate

- **What:** FTS5 is SQLite's built-in full-text search extension. Zero additional dependencies. Supports BM25 ranking, prefix queries, snippet highlighting.
- **Storage efficiency:** ~26MB index for a dataset where MeiliSearch requires ~217MB for the same data.
- **CAST fit:** Create a `memory_search` virtual table that mirrors `agent-memory-local/` content. Create a `log_search` FTS5 table for cast.db events.
- **Already available:** `better-sqlite3` exposes FTS5 natively. No new dependencies.
- **Feasibility:** HIGH — the research from 2026-04-05 already identified FTS5 as the right approach.

**Concrete steps:**
```sql
-- In cast.db schema migration
CREATE VIRTUAL TABLE memory_fts USING fts5(
  content, path, agent, updated,
  tokenize='porter unicode61'
);
-- Trigger memory file sync via Python indexer script
```

### 5b. Tantivy (via SQLite extension or standalone)

- **What:** Rust-based full-text search library. Used inside TursoDB as a SQLite extension. ~10x faster than FTS5 for large corpora.
- **Pros:** Superior ranking, fuzzy search, field weighting.
- **Cons:** Requires a compiled Rust extension. At CAST's current scale (hundreds of memory files), FTS5 is sufficient.
- **Feasibility:** LOW now, MEDIUM if CAST memory grows to 10k+ documents.

### 5c. MeiliSearch (self-hosted)

- **What:** Open-source search engine with a REST API. Typo-tolerant, fast.
- **Cons:** Requires running a separate server process. 8x larger index than FTS5. Overkill for local developer tooling.
- **Feasibility:** LOW — adds operational complexity that violates CAST's simplicity principle.

---

## 6. Network-Aware Mode Switching

**Goal:** Detect connectivity and gracefully degrade; queue agent requests for when connectivity returns.

### 6a. Shell-based connectivity gate — RECOMMENDED for CAST core

- **What:** CAST is Bash-first. A simple connectivity check is appropriate:
  ```bash
  ping -c 1 -W 2 api.anthropic.com &>/dev/null && ONLINE=true || ONLINE=false
  ```
- **Queue mechanism:** A FIFO file queue at `~/.claude/cast/offline-queue/` stores pending agent invocations as JSON. A cron job (already used in CAST) replays the queue when online.
- **Feasibility:** HIGH — pure Bash, fits CAST's existing cron-based scheduling model.

**Concrete steps:**
1. Add `cast_check_connectivity()` function to `cast-events.sh`
2. When offline, write agent requests to `~/.claude/cast/offline-queue/<timestamp>.json`
3. Add a cron entry: `* * * * * ~/.claude/scripts/cast-queue-replay.sh`
4. `cast-queue-replay.sh` checks connectivity, drains queue if online

### 6b. Dashboard (React + Express) — Network-aware UI

- **What:** The claude-code-dashboard uses React 19 + Vite. Add a `useNetworkStatus` hook using the browser's `navigator.onLine` and `window addEventListener('online'/'offline')`.
- **API requests:** Wrap Express fetch calls with a retry queue using `react-query`'s `retry` and `networkMode: 'offlineFirst'` options (TanStack Query v5 has built-in offline support).
- **Feasibility:** HIGH — TanStack Query v5 (already in stack per stack-context.md) has native offline support via `networkMode`.

### 6c. Service Worker / Background Sync

- **What:** PWA Background Sync API queues requests in IndexedDB and replays when connectivity returns. Works when the browser tab is closed.
- **CAST fit:** The dashboard is a local dev tool, not a PWA. Browser tab persistence is not a concern.
- **Feasibility:** LOW for CAST dashboard specifically.

---

## 7. Local Backups & Versioning

**Goal:** Protect cast.db and agent memory against data loss without cloud storage.

### 7a. `sqlite3_backup` API for cast.db — RECOMMENDED

- **What:** SQLite's built-in online backup API creates a consistent snapshot without blocking writers, even in WAL mode. Exposed via Python's `sqlite3` module as `connection.backup(dest)`.
- **Script:** `cast-backup.sh` runs daily via cron, storing snapshots in `~/.claude/backups/cast-db-YYYY-MM-DD.db`.
- **Retention:** Keep 7 daily + 4 weekly snapshots. Total storage: ~50MB for typical CAST usage.
- **Feasibility:** HIGH — already have Python scripts in CAST, trivial to add.

**Concrete steps:**
```python
# cast-backup.py
import sqlite3, shutil, datetime
src = sqlite3.connect(os.path.expanduser("~/.claude/cast.db"))
dst_path = f"~/.claude/backups/cast-db-{datetime.date.today()}.db"
dst = sqlite3.connect(os.path.expanduser(dst_path))
src.backup(dst)
```

### 7b. Git-based config versioning

- **What:** The `~/.claude/` directory (agents/, rules/, scripts/, plans/) is plain text and is already in `claude-agent-team` git repo. Extending this to auto-commit config changes provides a full history.
- **Approach:** Add a post-write hook or a `cast config-sync` command that runs `git add -u && git commit -m "auto: config snapshot $(date)"` in the `~/.claude/` directory (or a symlinked config repo).
- **Time Machine compatibility:** Keep `~/.claude/` layout flat (no deeply nested symlinks) so macOS Time Machine indexes it cleanly.
- **Feasibility:** HIGH — fits perfectly with CAST's existing git-centric workflow.

### 7c. SQLite WAL snapshot pitfalls to avoid

- **Warning:** Naive `cp ~/.claude/cast.db` during active use can produce an inconsistent backup because the WAL file (`cast.db-wal`) contains in-flight data not yet checkpointed to the main file.
- **Rule:** Always use `sqlite3_backup` API or `VACUUM INTO <dest>` for consistent snapshots. Never raw `cp` a live SQLite database.

---

## 8. Privacy-Preserving Telemetry

**Goal:** If CAST ever adds opt-in usage telemetry, do it in a way that protects developer privacy.

### 8a. Local Aggregation + Opt-in Export — RECOMMENDED

- **What:** Aggregate stats locally in `cast.db` (already done for observability). If a user opts in, export only aggregate counts — never raw event logs or file paths.
- **Example export payload:**
  ```json
  { "agent_invocations_7d": 142, "most_used_agent": "code-writer",
    "avg_session_minutes": 23, "cast_version": "4.4" }
  ```
- **No user identifiers** in the payload. No file paths. No prompt content.
- **Implementation:** `cast telemetry --export` writes to a JSON file the user can review before sharing.
- **Feasibility:** HIGH — cast.db already has the raw data; aggregation is a SQL query.

### 8b. Differential Privacy via OpenDP

- **What:** OpenDP is an open-source library (Python/Rust) for adding calibrated noise to statistics so individual records cannot be inferred.
- **Fit:** Overkill for a single-developer tool. More relevant if CAST becomes a multi-user product.
- **Stars:** 500+ on GitHub. Backed by Harvard Privacy Tools Project.
- **Feasibility:** LOW now (no multi-user data pool to protect), MEDIUM for a future SaaS/hosted version.

### 8c. What to never collect (even with consent)

- File paths containing user data
- Prompt content or agent outputs
- API keys or environment variables
- IP addresses or machine identifiers beyond a random UUID
- Git remote URLs (may expose internal org names)

---

## Cross-Cutting Recommendations

### Immediate Wins (Low Effort, High Impact — do these first)

1. **SQLite FTS5 for memory search** — zero new dependencies, already in `cast.db`
2. **`age` file encryption for agent memory** — `brew install age`, one script
3. **`cast-backup.py`** — 10 lines of Python using stdlib `sqlite3.backup()`
4. **`prefer-offline=true` in `.npmrc`** for the dashboard
5. **Keychain for `ANTHROPIC_API_KEY`** — move from `.env` to `security` CLI

### Medium Term (Requires planning)

6. **Ollama integration** — `cast-offline-llm.sh` + fallback routing in cast-events.sh
7. **Connectivity gate + offline queue** — Bash FIFO queue + cron replay
8. **Git config versioning** — auto-commit hook for `~/.claude/` changes

### Long Term (If product scales)

9. **SQLCipher for cast.db** — when the dashboard becomes a shared/team tool
10. **cr-sqlite** — if CAST is used across multiple machines by one developer
11. **OpenDP telemetry** — if a cloud version of CAST observability is built

---

## Sources

- [Ollama MLX blog](https://ollama.com/blog/mlx) — official Ollama MLX integration announcement
- [Ollama 0.19 MLX Review](https://andrew.ooo/posts/ollama-mlx-apple-silicon-review/) — performance benchmarks
- [9to5Mac: Ollama adopts MLX](https://9to5mac.com/2026/03/31/ollama-adopts-mlx-for-faster-ai-performance-on-apple-silicon-macs/) — 2026 coverage
- [vlcn.io cr-sqlite](https://vlcn.io/docs/cr-sqlite/intro) — CRDTs for SQLite
- [cr-sqlite GitHub](https://github.com/vlcn-io/cr-sqlite) — source and npm package
- [Best CRDT Libraries 2025](https://velt.dev/blog/best-crdt-libraries-real-time-data-sync) — comparison
- [Automerge 3.0 memory improvements](https://biggo.com/news/202508071934_Automerge_3.0_Memory_Improvements) — v3.0 release
- [SQLCipher GitHub](https://github.com/sqlcipher/sqlcipher) — encrypted SQLite
- [How to Implement Encryption with SQLCipher](https://oneuptime.com/blog/post/2026-02-02-sqlcipher-encryption/view)
- [age encryption GitHub](https://github.com/FiloSottile/age) — modern file encryption
- [age-plugin-se: Apple Secure Enclave](https://mko.re/blog/age-plugin-se/) — Touch ID bound keys
- [pnpm offline mode](https://pnpm.io/cli/install) — official docs
- [Homebrew offline install guide](https://www.slingacademy.com/article/homebrew-install-package-offline/)
- [SQLite FTS5 in practice](https://thelinuxcode.com/sqlite-full-text-search-fts5-in-practice-fast-search-ranking-and-real-world-patterns/)
- [SQLite WAL backup consistency](https://sqlite.work/ensuring-consistent-backups-in-sqlite-wal-mode-without-disrupting-writers/)
- [Offline-first frontend apps 2025](https://blog.logrocket.com/offline-first-frontend-apps-2025-indexeddb-sqlite/)
- [Background Sync with Service Workers](https://davidwalsh.name/background-sync)
- [OpenDP tools](https://opendp.org/tools/) — differential privacy
- [Privacy Guides: Differential Privacy](https://www.privacyguides.org/articles/2025/09/30/differential-privacy/)
- [Ollama tool calling docs](https://docs.ollama.com/capabilities/tool-calling)
- [llama.cpp offline agentic coding discussion](https://github.com/ggml-org/llama.cpp/discussions/14758)
- [Small Language Models 2026](https://www.intuz.com/blog/best-small-language-models)
