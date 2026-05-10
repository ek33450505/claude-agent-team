# Rules Drift Audit — Phase 5 Mirror Resolution
**Date:** 2026-05-10  
**Methodology:** Diff `rules-core/` vs `~/.claude/rules/` for canonical overlap  
**Decision:** Option A — keep two-copy + add CI drift check

## Findings

### Direct Drifts (Real Divergence)

**1. `agents.md` — line 13 fork**
- **Repo** (`rules-core/agents.md:13` before fix): `- ADM execution: the /orchestrate skill runs plans directly from the main session — no subagent dispatch needed for orchestration`
- **Runtime** (`~/.claude/rules/agents.md:13` before fix): `- Agent prompts in manifest dispatch: use subagent_type: 'general-purpose' for orchestrator dispatch workarounds`
- **Resolution:** Both lines are canonical; merged as sequential bullets. `/orchestrate` guidance is current ADM execution pattern; `general-purpose` is a documented workaround.
- **Status:** ✓ Fixed

**2. `working-conventions.md` — 3 missing sections + 1 extended section**
- **Repo version lacks:**
  1. `## Accessibility (UI projects)` — 10 lines (frontend-qa decision tree)
  2. `## Memory Verification` — 4 lines (2026-05-05 bug class context on auto-memory validation)
  3. `## Branch & Worktree Hygiene` — 14 lines (`cast clean` policy, grooming rules, worktree safety)
- **Repo version extends:** `## Phase 5b — Workflow Closures` — runtime adds 1 paragraph on Forked subagents + reference to cast-cost-optimization.md
- **Resolution:** Full sync — runtime is canonical. Repo source absorbs all 4 sections/extensions verbatim.
- **Status:** ✓ Fixed

### Template Variants (Expected — Not Touched)

- `rules-core/project-catalog.md.template` ↔ `~/.claude/rules/project-catalog.md` — template is source, runtime is user-rendered instance. **No sync needed.**
- `rules-core/stack-context.md.template` ↔ `~/.claude/rules/stack-context.md` — template is source, runtime is user-rendered instance. **No sync needed.**

### Runtime-Only Files

**Files in `~/.claude/rules/` missing from `rules-core/`:**

1. **`claudes_journal.md`** — General framework guidance about Claude's Journal feature (session-end hook, /reflect skill, SessionStart hook). Not user-specific.
   - **Decision:** Add to `rules-core/` verbatim. This is framework-level guidance.
   - **Status:** ✓ Added

2. **`managed-agents.md`** — General framework guidance about Managed Agents preference + adapter shim instructions (cast-managed-agent.sh, beta header, keychain setup).
   - **Decision:** Add to `rules-core/` verbatim. This is framework-level guidance.
   - **Status:** ✓ Added

3. **`work-projects.md`** — Ed-specific conventions (Bitbucket, Model B deploy, build artifact commits, work-project cast.json).
   - **Decision:** **Skip.** This is user-specific (META Solutions environment), not shared framework guidance. Keep only in runtime.
   - **Status:** Intentionally excluded

## Resolution Actions Completed

1. ✓ Merged both `agents.md` bullet points (ADM + general-purpose workaround)
2. ✓ Synced `working-conventions.md` → repo (Accessibility, Memory Verification, Branch & Worktree Hygiene sections + Phase 5b extension)
3. ✓ Added `rules-core/claudes_journal.md`
4. ✓ Added `rules-core/managed-agents.md`
5. ⏳ Create `.github/workflows/rules-drift.yml` CI job
6. ⏳ Create `scripts/gen-rules-manifest.sh` manifest generator
7. ⏳ Create `tests/rules-drift.bats` BATS coverage
8. ⏳ Generate initial `.github/rules-core.manifest` (post-sync)

## Future Safety: CI Drift Guard

**Mechanism:** `rules-drift.yml` CI workflow on push + pull_request to main
- Stores hash manifest of `rules-core/` files at `.github/rules-core.manifest`
- Re-computes manifest in CI, diffs against committed version
- Fails if drift detected with clear remediation: `bash scripts/gen-rules-manifest.sh`

**Why this works:**
- Blocks accidental divergence at merge time
- Single source of truth: the repo version (rules-core/) is canonical
- Runtime (`~/.claude/rules/`) is derived by `install.sh` at CAST setup
- CI enforces: if you change `rules-core/`, you must commit the manifest update
- Prevents historical drift pattern: improvements in runtime don't disappear on next install

## Files in Scope

- `rules-core/agents.md` (modified)
- `rules-core/working-conventions.md` (overwritten)
- `rules-core/claudes_journal.md` (new)
- `rules-core/managed-agents.md` (new)
- `.github/workflows/rules-drift.yml` (new CI job)
- `scripts/gen-rules-manifest.sh` (new manifest generator)
- `.github/rules-core.manifest` (generated post-sync)
- `tests/rules-drift.bats` (new BATS coverage)

## Verification Checklist

After all files land:
- [ ] `diff rules-core/working-conventions.md ~/.claude/rules/working-conventions.md` → clean
- [ ] `diff rules-core/claudes_journal.md ~/.claude/rules/claudes_journal.md` → clean
- [ ] `diff rules-core/managed-agents.md ~/.claude/rules/managed-agents.md` → clean
- [ ] `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/rules-drift.yml'))"` → exit 0
- [ ] `bash scripts/gen-rules-manifest.sh && cat .github/rules-core.manifest | wc -l` → ~9-11 lines
- [ ] `bats tests/rules-drift.bats 2>&1 | tail -10` → all green
- [ ] `bash tests/run.sh --tap 2>/dev/null | grep -c "^not ok"` → 0
