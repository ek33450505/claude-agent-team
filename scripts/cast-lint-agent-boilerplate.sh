#!/usr/bin/env bash
# cast-lint-agent-boilerplate.sh
#
# CAST Agent Boilerplate Detector (Gate 4)
#
# Fails if any agent definition (agents/core/*.md) re-inlines a verbatim prose
# line that already lives canonically in skills/cast-conventions/SKILL.md.
# A definition that *references* the skill by name is fine — only verbatim
# copy-pasted lines are flagged.
#
# Sentinel lines are distinctive full prose sentences from the skill. JSON
# template blocks are intentionally excluded: agents legitimately instantiate
# those with their own agent names and examples (they are not verbatim copies).
#
# Override dirs via environment:
#   CAST_AGENTS_DIR — directory of agent definitions (default: <repo>/agents/core)
#   CAST_REPO_ROOT  — repo root (default: git rev-parse --show-toplevel)
#
# Exit codes:
#   0 — no verbatim skill lines found in agent definitions
#   1 — one or more agents contain a verbatim sentinel line

set -euo pipefail

# ---------------------------------------------------------------------------
# Sentinel lines — verbatim full prose lines from skills/cast-conventions/SKILL.md
# Each comment maps the sentinel to its section in the skill.
#
# NOTE: These are PROSE rule lines. JSON example blocks are excluded because
# agents legitimately instantiate the skill's JSON template with their own
# agent name and field values — those are not copy-paste violations.
#
# Two sentinels currently match real agent files (known findings):
#   S1 — matches agents/core/test-runner.md   (infra boilerplate inlined)
#   S2 — matches agents/core/code-writer.md   (Key Principles inlined)
# ---------------------------------------------------------------------------
SENTINELS=(
  # S1 — Status File section: verbatim infrastructure call template
  # Skill section: "## Status File"
  "source ~/.claude/scripts/status-writer.sh 2>/dev/null || true"

  # S2 — Key Principles section: YAGNI rule verbatim
  # Skill section: "## Key Principles"
  "- **YAGNI:** Build only what was asked. No extra features or nice-to-haves."

  # S3 — Status File section: cast_write_status invocation with literal placeholders
  # Skill section: "## Status File"
  "cast_write_status \"<STATUS>\" \"<one-line summary>\" \"<your-agent-name>\" \"<concerns or empty>\" 2>/dev/null || true"

  # S4 — Status File section: prose instruction opening line
  # Skill section: "## Status File"
  "Before emitting your prose Status line, write a machine-readable status file at"
)

# ---------------------------------------------------------------------------

get_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

REPO_ROOT="${CAST_REPO_ROOT:-$(get_repo_root)}"
AGENTS_DIR="${CAST_AGENTS_DIR:-${REPO_ROOT}/agents/core}"

if [[ ! -d "$AGENTS_DIR" ]]; then
  echo "ERROR [lint-agent-boilerplate]: agents dir not found: ${AGENTS_DIR}" >&2
  exit 1
fi

findings=()

for agent_file in "${AGENTS_DIR}"/*.md; do
  [[ -f "$agent_file" ]] || continue
  for sentinel in "${SENTINELS[@]}"; do
    # grep -F: fixed string (no regex), -q: quiet for the check, then get line number
    # Use -- to prevent sentinels starting with "-" from being parsed as grep flags.
    if grep -qF -- "$sentinel" "$agent_file" 2>/dev/null; then
      lineno=$(grep -nF -- "$sentinel" "$agent_file" | head -1 | cut -d: -f1)
      findings+=("$(basename "$agent_file"):${lineno}: matched sentinel: ${sentinel:0:60}...")
    fi
  done
done

if [[ ${#findings[@]} -eq 0 ]]; then
  exit 0
fi

echo "ERROR [lint-agent-boilerplate]: ${#findings[@]} verbatim skill line(s) found in agent definitions." >&2
echo "These lines belong in skills/cast-conventions/SKILL.md only — remove them from agent defs" >&2
echo "and reference the skill by name instead." >&2
echo "" >&2
for finding in "${findings[@]}"; do
  echo "  ${finding}" >&2
done
exit 1
