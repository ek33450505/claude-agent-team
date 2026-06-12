#!/usr/bin/env python3
"""
Backfill historical incidents into cast.db from journal + feedback memory sources.
Idempotent: INSERT OR IGNORE on primary key.
Run once: python3 scripts/cast-incidents-backfill.py
"""
import os
from pathlib import Path

# Resolve cast_db.py from script directory or ~/.claude/scripts fallback
_script_dir = Path(__file__).resolve().parent
_db_mod = _script_dir / "cast_db.py"
if not _db_mod.exists():
    _db_mod = Path.home() / ".claude" / "scripts" / "cast_db.py"

import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("cast_db", str(_db_mod))
_mod = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
db_execute = _mod.db_execute
db_query = _mod.db_query


INCIDENTS = [
    {
        "id": "python-heredoc-file-stdin-20260503",
        "occurred_at": "2026-05-03",
        "problem_summary": "Inside `python3 - <<'PYEOF'` heredocs, __file__ == '<stdin>'; abspath(__file__) resolves to CWD",
        "fix_summary": "Set CAST_HOOK_DIR from BASH_SOURCE[0] in bash before heredoc; read via os.environ in Python",
        "related_files": '["scripts/cast-truncation-check.sh","scripts/cast-agent-protocol-check.sh"]',
        "related_commit": "4f0629728",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "bats-ci-missing-py-copy-20260503",
        "occurred_at": "2026-05-03",
        "problem_summary": "bats-ci.yml runtime setup copied *.sh but not *.py; cast_db.py not findable on Ubuntu CI",
        "fix_summary": "Added *.py glob to cp step in both bats-ci.yml and test-installer.yml",
        "related_files": '[".github/workflows/bats-ci.yml",".github/workflows/test-installer.yml"]',
        "related_commit": "2e5822ed",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "bats-count-find-inflated-38x-20260426",
        "occurred_at": "2026-04-26",
        "problem_summary": "`find tests/ -name '*.bats'` included 307 vendored bats-framework fixtures; badge showed 1726 tests (38× real count)",
        "fix_summary": "Switched to `git ls-files 'tests/**/*.bats'`; corrected badge in v6.0.1 release",
        "related_files": '["scripts/gen-stats.sh","README.md"]',
        "related_commit": None,
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "python-heredoc-injection-cwdchanged-20260426",
        "occurred_at": "2026-04-26",
        "problem_summary": "Unquoted `python3 << EOF` heredoc interpolated $SHELL_VAR into Python source; CWD path with spaces broke JSON",
        "fix_summary": "Single-quoted heredoc delimiter + export env var + os.environ read in Python (fixes cast-cwdchanged-hook.sh)",
        "related_files": '["scripts/cast-cwdchanged-hook.sh"]',
        "related_commit": None,
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "parry-guard-false-positive-apikey-20260426",
        "occurred_at": "2026-04-26",
        "problem_summary": "Parry-guard ML model flagged cast-rate-check.py for ANTHROPIC_API_KEY mentions (all legitimate API client code)",
        "fix_summary": "Split commit to isolate trigger file; used `parry-guard ignore` → commit → `parry-guard reset` around single file",
        "related_files": '["scripts/cast-rate-check.py"]',
        "related_commit": None,
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "agent-truncations-missing-bats-env-20260511",
        "occurred_at": "2026-05-11",
        "problem_summary": "agent_truncations table absent from BATS test envs; caused 1917-line db-write-errors.log flood",
        "fix_summary": "Added agent_truncations to cast-db-init self-healing block with idempotent CREATE TABLE IF NOT EXISTS",
        "related_files": '["scripts/cast-db-init.sh","tests/cast-db-init.bats"]',
        "related_commit": "eb9cb47",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "test-runner-hallucinated-failures-20260511",
        "occurred_at": "2026-05-11",
        "problem_summary": "test-runner agent hallucinated 3 failures on a green 958-test suite and claimed it dispatched the debugger",
        "fix_summary": "Added truncation-resilient test gate and gen-stats BATS guard; test-runner no longer dispatches sub-agents",
        "related_files": '["agents/core/test-runner.md","scripts/gen-stats.sh"]',
        "related_commit": "4ae8f7f",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "readme-sentinel-leak-20260511",
        "occurred_at": "2026-05-11",
        "problem_summary": "gen-stats.sh wrote README sentinel markers into the live file, leaking <!-- BEGIN STATS -->...<!-- END STATS --> on force-push",
        "fix_summary": "Wrapped gen-stats BATS guard to detect sentinel leak and abort before commit; added Phase 4.11 BATS coverage",
        "related_files": '["scripts/gen-stats.sh","tests/cast-agent-stats.bats"]',
        "related_commit": "4ae8f7f",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "hookspecificoutput-string-cli-crash-20260507",
        "occurred_at": "2026-05-07",
        "problem_summary": "Hook returning hookSpecificOutput as string instead of JSON object triggered `in` operator crash in Claude Code CLI",
        "fix_summary": "Added hookSpecificOutput schema validation + recovery guardrails; all CAST hooks now return structured JSON",
        "related_files": '["scripts/cast-validate-hook-output.sh",".github/workflows/bats-ci.yml"]',
        "related_commit": "4f62abf",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "bash32-heredoc-parameter-expansion-20260503",
        "occurred_at": "2026-05-03",
        "problem_summary": "macOS bash 3.2 ${var//\\'/\\'\\'} parameter expansion is buggy; cast-doctor sync-check failed on macOS CI runners",
        "fix_summary": "Replaced parameter expansion with python3 string replacement for quote escaping; added bash 3.2 compat notes",
        "related_files": '["scripts/cast-doctor.sh","scripts/cast-db-init.sh"]',
        "related_commit": "4f06297",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "completeness-hook-false-truncation-20260426",
        "occurred_at": "2026-04-26",
        "problem_summary": "Response completeness hook had 200-line tail window; Status blocks pushed up by long files-changed JSON arrays were missed",
        "fix_summary": "Widened tail window + added JSON-form Status regex; false positive rate dropped to ~0",
        "related_files": '["scripts/cast-response-completeness-hook.sh"]',
        "related_commit": "841dddb",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "install-dual-policy-stale-fragment-20260505",
        "occurred_at": "2026-05-05",
        "problem_summary": "install.sh skip-if-exists policy applied to hook fragments; stale 30-hooks-session.json from prior deploy was never refreshed",
        "fix_summary": "Dual policy: *-hooks-*.json fragments always overwrite (CAST-owned); other fragments skip-if-exists (user-owned)",
        "related_files": '["install.sh","managed-settings.d/30-hooks-session.json"]',
        "related_commit": "7529a30",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "ci-bats-only-top-level-local-20260505",
        "occurred_at": "2026-05-05",
        "problem_summary": "Local `bats tests/` ran 610 tests; CI `bats tests/*.bats tests/**/*.bats` ran 684 — subdirectory tests invisible locally",
        "fix_summary": "Canonicalized BATS invocation to match exact CI command; added note to working-conventions.md",
        "related_files": '["tests/cast-settings-hook-wiring.bats","tests/cast-time-context-hook.bats"]',
        "related_commit": "c5183c9",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "ubuntu-ci-specific-bats-failure-20260416",
        "occurred_at": "2026-04-16",
        "problem_summary": "BATS tests passed on macOS but failed on Ubuntu CI due to BSD vs GNU stat and bash 3.2 vs 5.x differences",
        "fix_summary": "Added platform-conditional stat calls and replaced bash 5.x-only syntax; CI green across both platforms",
        "related_files": '["scripts/cast-compat.sh"]',
        "related_commit": "82c568f2",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "cast-claudes-journal-ci-yaml-parse-20260503",
        "occurred_at": "2026-05-03",
        "problem_summary": "cast-claudes_journal CI broken for 5 days: double-quoted Python one-liner inside single-quoted YAML scalar caused parse error",
        "fix_summary": "Rewrote YAML workflow step to use multiline block scalar; debugger fixed in same arc as CAST CI tour",
        "related_files": '[".github/workflows/ci.yml"]',
        "related_commit": None,
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "cellar-door-hookspecificoutput-missing-hookEventName-20260503",
        "occurred_at": "2026-05-03",
        "problem_summary": "cast-memory-inject.py hookSpecificOutput emit sites missing required hookEventName field; every Claude prompt showed validation error",
        "fix_summary": "Added hookEventName field to both emit sites in source + runtime; smoke-tested + shipped as 0bc5dee",
        "related_files": '["scripts/cast-memory-inject.py"]',
        "related_commit": "0bc5dee",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
    {
        "id": "precompact-guard-manual-compact-blocked-20260507",
        "occurred_at": "2026-05-07",
        "problem_summary": "precompact-guard.sh blocked manual /compact commands because it checked git dirty state unconditionally",
        "fix_summary": "Added CAST_ALLOW_MANUAL_COMPACT bypass flag; manual /compact no longer fails on dirty working tree",
        "related_files": '["scripts/cast-precompact-guard.sh"]',
        "related_commit": "cf65842",
        "resolution_status": "fixed",
        "surfaced_by": "manual-backfill-20260511",
    },
]


def main() -> None:
    db_path = os.environ.get("CAST_DB_PATH", str(Path.home() / ".claude" / "cast.db"))

    added = 0
    skipped = 0

    for inc in INCIDENTS:
        # Check existence first so we can report accurately
        existing = db_query(
            "SELECT id FROM incidents WHERE id = ?",
            (inc["id"],),
        )
        if existing:
            skipped += 1
            continue

        db_execute(
            """INSERT OR IGNORE INTO incidents
               (id, occurred_at, problem_summary, fix_summary,
                related_files, related_commit, resolution_status, surfaced_by)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                inc["id"],
                inc["occurred_at"],
                inc["problem_summary"],
                inc["fix_summary"],
                inc["related_files"],
                inc.get("related_commit"),
                inc["resolution_status"],
                inc["surfaced_by"],
            ),
        )
        added += 1

    rows = db_query("SELECT COUNT(*) AS n FROM incidents")
    total = rows[0]["n"] if rows else 0
    print(f"Backfill complete: {added} added, {skipped} skipped (already present).")
    print(f"Total rows in incidents table: {total}")


if __name__ == "__main__":
    main()
