#!/bin/bash
# cast-memory-escalation.sh — Auto-escalation rule engine
#
# Detects recurring BLOCKED patterns and recurring code-reviewer concerns,
# writes auto-rules to cast.db and human-readable auto-rules.md files.
#
# Designed to be called from stop-hook.sh after session end (background, non-blocking).
#
# Usage:
#   cast-memory-escalation.sh [--project <name>] [--db /path/to/cast.db]
#
# Detection rules:
#   1. code-reviewer flags same concern keyword 3+ times in same project
#
# Output: writes memories via cast-memory-write.sh + human-readable auto-rules.md

set -uo pipefail

DB_PATH="${CAST_DB_PATH:-${HOME}/.claude/cast.db}"
SCRIPTS_DIR="$(dirname "$0")"
AGENT_MEMORY_DIR="${HOME}/.claude/agent-memory-local"

PROJECT_FILTER=""

while [ "${#}" -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT_FILTER="${2:-}"
      shift 2
      ;;
    --db)
      DB_PATH="${2:-$DB_PATH}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if ! command -v sqlite3 >/dev/null 2>&1; then
  exit 0
fi

if ! sqlite3 "$DB_PATH" "SELECT 1 FROM agent_runs LIMIT 1;" >/dev/null 2>&1; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Pattern detection via Python
# ---------------------------------------------------------------------------
AUTO_RULES="$(python3 - "$DB_PATH" "$PROJECT_FILTER" <<'PYEOF' 2>/dev/null || echo "[]"
import sys, sqlite3, json
from collections import defaultdict

db_path = sys.argv[1]
project_filter = sys.argv[2]

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

rules = []

# -------------------------------------------------------------------------
# Rule 1: code-reviewer flags same concern keyword 3+ times
# agent_runs.project was dropped in migration 022 (wave-3); recover via sessions JOIN
# -------------------------------------------------------------------------
reviewer_params = []
reviewer_where = "ar.agent = 'code-reviewer' AND ar.response IS NOT NULL AND ar.response != ''"
if project_filter:
    reviewer_where += " AND COALESCE(s.project, '') = ?"
    reviewer_params.append(project_filter)

cur.execute(
    f"SELECT COALESCE(s.project, '') AS project, ar.response "
    f"FROM agent_runs ar LEFT JOIN sessions s ON ar.session_id = s.id "
    f"WHERE {reviewer_where}",
    reviewer_params
)
reviewer_rows = cur.fetchall()
conn.close()

# Extract recurring concern keywords per project
# Focus on actionable concern words that appear in reviewer output
CONCERN_KEYWORDS = [
    "missing error handling", "no error handling",
    "sql injection", "hardcoded",
    "missing tests", "no tests",
    "missing validation", "input validation",
    "console.log", "debug statement",
    "unused import", "dead code",
    "race condition", "memory leak",
    "missing auth", "authentication",
    "missing null check", "null check",
    "type error", "typescript error",
]

project_keyword_counts = defaultdict(lambda: defaultdict(int))
for row in reviewer_rows:
    proj = row["project"] or "unknown"
    summary_lower = (row["response"] or "").lower()
    for kw in CONCERN_KEYWORDS:
        if kw in summary_lower:
            project_keyword_counts[proj][kw] += 1

for proj, kw_counts in project_keyword_counts.items():
    for kw, count in kw_counts.items():
        if count >= 3:
            rules.append({
                "type": "project",
                "agent": "code-reviewer",
                "project": proj,
                "name": f"auto-rule: recurring concern '{kw}' in {proj}",
                "content": (
                    f"code-reviewer has flagged '{kw}' {count} times in project '{proj}'. "
                    f"This is a recurring pattern. Consider: adding a linting rule, updating CLAUDE.md conventions, "
                    f"or adding a pre-commit check for this class of issue."
                ),
                "pattern": "recurring_concern"
            })

print(json.dumps(rules, indent=2))
PYEOF
)"

if [ -z "$AUTO_RULES" ] || [ "$AUTO_RULES" = "[]" ]; then
  echo "0 auto-rules generated"
  exit 0
fi

# ---------------------------------------------------------------------------
# Write each rule via cast-memory-write.sh and to human-readable auto-rules.md
# ---------------------------------------------------------------------------
RULE_COUNT="$(echo "$AUTO_RULES" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"

CAST_AUTO_RULES="$AUTO_RULES" python3 - "$SCRIPTS_DIR" "$AGENT_MEMORY_DIR" <<'PYEOF' 2>/dev/null || true
import json, sys, os, subprocess, datetime

scripts_dir = sys.argv[1]
memory_dir = sys.argv[2]
rules = json.loads(os.environ.get("CAST_AUTO_RULES", "[]"))
write_script = os.path.join(scripts_dir, "cast-memory-write.sh")

for rule in rules:
    agent = rule.get("agent", "cast")
    mem_type = rule.get("type", "project")
    name = rule.get("name", "auto-rule")
    content = rule.get("content", "")
    project = rule.get("project", "")

    # Write to cast.db via cast-memory-write.sh
    cmd = ["bash", write_script, agent, mem_type, name, content]
    if project:
        cmd += ["--project", project]
    subprocess.run(cmd, capture_output=True, timeout=10)

    # Write human-readable auto-rules.md
    if project:
        proj_dir = os.path.join(memory_dir, project)
        os.makedirs(proj_dir, exist_ok=True)
        auto_rules_path = os.path.join(proj_dir, "auto-rules.md")

        today = datetime.date.today().isoformat()
        entry = f"\n## {name}\n\n{content}\n\n_Auto-generated: {today}_\n"

        # Read existing to avoid duplicate rule names
        existing = ""
        if os.path.exists(auto_rules_path):
            with open(auto_rules_path) as f:
                existing = f.read()

        if name not in existing:
            with open(auto_rules_path, "a") as f:
                if not existing:
                    f.write(f"# Auto-Escalation Rules — {project}\n\n")
                    f.write("Rules generated by `cast-memory-escalation.sh` based on recurring patterns.\n")
                f.write(entry)

print("done")
PYEOF

echo "$RULE_COUNT auto-rules generated$([ -n "$PROJECT_FILTER" ] && echo " for project $PROJECT_FILTER" || echo "")"
exit 0
