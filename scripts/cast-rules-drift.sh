#!/usr/bin/env bash
# cast-rules-drift.sh — detects drift between the repo's rules-core/ (the
# install source, and the RESTORE source after a ~/.claude wipe) and the
# LIVE ~/.claude/rules/ (what the main orchestrator session actually loads).
#
# WHY THIS EXISTS: install.sh:201-214 copies rules-core/* -> ~/.claude/rules/
# SKIP-IF-EXISTS. Once a live file exists, a merged rules-core fix NEVER
# reaches that machine via reinstall — e.g. the PR #313 launchd HARD RULE
# added to rules-core/tests.md + shell.md still hadn't reached live 7 weeks
# later, and nothing detected it. This script is READ-ONLY: it only reports
# drift, it NEVER copies or syncs either side. No sync mode by design.
#
# RELATED BUT DIFFERENT CHECK: `bin/cast doctor`'s "rules drift" section
# compares two LIVE dirs (~/.claude/rules-core/ vs ~/.claude/rules/) and is
# dormant until a Homebrew tap release ships bin/cast. This script instead
# compares the REPO's rules-core/ (source of truth) directly against LIVE
# ~/.claude/rules/, and runs today via cast-maintenance.sh (launchd-driven,
# propagates on every reinstall — see wiring there).
#
# BUCKETS:
#   1. CORE      — rules-core/*.md (no .template suffix). Must match the live
#                  counterpart byte-for-byte. Any difference is real drift.
#   2. TEMPLATE  — rules-core/*.md.template. Live counterpart drops the
#                  .template suffix. User-specialized BY DESIGN — content is
#                  NEVER compared, only presence.
#   3. LIVE-ONLY — a live rules/ file with no rules-core source.
#        - Allowlisted (see ALLOWLIST below): expected personal rule, INFO
#          only, never counted as drift. NOTE: an allowlisted live-only file
#          is NOT restored after a wipe — that's precisely why it's worth
#          surfacing here even though it's not "wrong".
#        - NOT allowlisted: DECISION — treated as drift (reported, and
#          contributes to exit 1). An unmanaged live file is exactly the kind
#          of silent-divergence this script exists to catch; staying silent
#          here would just relocate the blind spot. Review it and either
#          promote it into rules-core/ or add it to the allowlist.
#   4. MISSING-LIVE — a CORE rule with no live counterpart at all (reported
#                  inline within the CORE bucket, tagged MISSING-LIVE). Drift:
#                  install would deliver it, but it isn't there now.
#
# Exit 0: no drift. Exit 1: drift found in any bucket above (bucket 3
# allowlisted entries never count).
#
# Env overrides (both default to the real paths; used by BATS fixtures):
#   CAST_RULES_CORE_DIR  (default: <repo-root>/rules-core)
#   CAST_LIVE_RULES_DIR  (default: ${HOME}/.claude/rules)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
if [[ -z "$REPO_ROOT" ]]; then
  # No git context — this is the expected path when running from the LIVE
  # installed copy (~/.claude/scripts/cast-rules-drift.sh), which is exactly
  # how cast-maintenance.sh's launchd job (com.cast.cast-maintenance, no
  # WorkingDirectory set) invokes it. Try the canonical checkout location
  # first — the same REPO_PATH precedent cast-cookbook-drift.sh uses in this
  # same directory — before falling back to dirname "$0"/... Without this,
  # the fallback would resolve to ~/.claude and compare against
  # ~/.claude/rules-core/, which is only a PARTIAL/stale mirror (verified:
  # 3 of 9 CORE files present live), silently skipping the rest — defeating
  # the whole point of this detector for its primary (daemon-driven) caller.
  _known_repo="${HOME}/Projects/personal/claude-agent-team"
  if [[ -f "${_known_repo}/rules-core/working-conventions.md" ]]; then
    REPO_ROOT="$_known_repo"
  else
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  fi
fi
RULES_CORE_DIR="${CAST_RULES_CORE_DIR:-${REPO_ROOT}/rules-core}"
LIVE_RULES_DIR="${CAST_LIVE_RULES_DIR:-${HOME}/.claude/rules}"

# ── Allowlist: live-only files expected to exist with NO repo source ────────
# Add here ONLY for deliberately-personal rules kept out of the public repo
# (rules-personal/ does not exist in this repo today; work-projects.md is the
# current example). Allowlisted entries are reported as INFO, never as drift.
ALLOWLIST=(
  "work-projects.md"
)

_is_allowlisted() {
  local name="$1" item
  for item in "${ALLOWLIST[@]}"; do
    [[ "$name" == "$item" ]] && return 0
  done
  return 1
}

# Hermetic zero-file sanity check — a detector that scans nothing must never
# report clean (mirrors blast-radius-lint.sh / cast-lint-source-guard.sh).
scan_count=0
for _f in "$RULES_CORE_DIR"/*.md "$RULES_CORE_DIR"/*.md.template; do
  [[ -f "$_f" ]] && scan_count=$((scan_count + 1))
done
if [[ "$scan_count" -eq 0 ]]; then
  echo "ERROR [cast-rules-drift]: scanned 0 files in '${RULES_CORE_DIR}' — refusing to pass on empty input"
  exit 1
fi

drift=0

echo "=== CAST rules-core drift report ==="
echo "Repo rules-core: ${RULES_CORE_DIR}"
echo "Live rules:      ${LIVE_RULES_DIR}"
echo

# ── Bucket 1 + 4: CORE (+ MISSING-LIVE) ──────────────────────────────────────
echo "-- CORE (must match byte-for-byte) --"
core_total=0
core_drift_count=0
for _core in "$RULES_CORE_DIR"/*.md; do
  [[ -f "$_core" ]] || continue
  core_total=$((core_total + 1))
  _base="$(basename "$_core")"
  _live="${LIVE_RULES_DIR}/${_base}"
  if [[ ! -f "$_live" ]]; then
    core_drift_count=$((core_drift_count + 1))
    drift=1
    echo "[DRIFT] ${_base}  MISSING-LIVE — not present in ${LIVE_RULES_DIR}/ (install would deliver it, but it isn't there now)"
  elif ! diff -q "$_core" "$_live" >/dev/null 2>&1; then
    core_drift_count=$((core_drift_count + 1))
    drift=1
    _repo_n="$(wc -l < "$_core" | tr -d ' ')"
    _live_n="$(wc -l < "$_live" | tr -d ' ')"
    # NOTE: diff exits 1 whenever files differ (expected here — this branch
    # only runs after `diff -q` already confirmed a difference), and under
    # pipefail that nonzero status bubbles up even though grep succeeded.
    # `|| true` swallows that false failure WITHOUT touching the value already
    # captured from grep's real stdout — an `|| echo 0` fallback here would
    # instead APPEND a second line to the captured output (embedding a stray
    # newline into every drift row), since command substitution keeps
    # whatever was printed before the pipeline's exit status is even checked.
    _diff_n="$(diff "$_core" "$_live" 2>/dev/null | grep -c '^[<>]')" || true
    echo "[DRIFT] ${_base}  content differs (repo ${_repo_n}L / live ${_live_n}L, ${_diff_n} diff lines) — reinstall will NOT fix this, it must be copied deliberately: diff '${_core}' '${_live}'"
  else
    echo "[OK]    ${_base}  matches"
  fi
done
[[ "$core_total" -eq 0 ]] && echo "(none found)"
echo

# ── Bucket 2: TEMPLATE ────────────────────────────────────────────────────
echo "-- TEMPLATE (presence-only; content is user-specialized by design) --"
template_total=0
template_present=0
for _tmpl in "$RULES_CORE_DIR"/*.md.template; do
  [[ -f "$_tmpl" ]] || continue
  template_total=$((template_total + 1))
  _base="$(basename "$_tmpl")"
  _live_name="${_base%.template}"
  _live="${LIVE_RULES_DIR}/${_live_name}"
  if [[ -f "$_live" ]]; then
    template_present=$((template_present + 1))
    echo "[OK]    ${_base} -> ${_live_name}  present (content not compared)"
  else
    drift=1
    echo "[DRIFT] ${_base} -> ${_live_name}  MISSING in ${LIVE_RULES_DIR}/ (install would deliver it, but it isn't there now)"
  fi
done
[[ "$template_total" -eq 0 ]] && echo "(none found)"
echo

# ── Bucket 3: LIVE-ONLY ──────────────────────────────────────────────────
echo "-- LIVE-ONLY (no rules-core source) --"
liveonly_allowlisted=0
liveonly_unlisted=0
if [[ -d "$LIVE_RULES_DIR" ]]; then
  for _live_f in "$LIVE_RULES_DIR"/*.md; do
    [[ -f "$_live_f" ]] || continue
    _base="$(basename "$_live_f")"
    # Skip anything already classified above: a direct CORE counterpart, or
    # the de-suffixed counterpart of a TEMPLATE.
    [[ -f "${RULES_CORE_DIR}/${_base}" ]] && continue
    [[ -f "${RULES_CORE_DIR}/${_base}.template" ]] && continue
    if _is_allowlisted "$_base"; then
      liveonly_allowlisted=$((liveonly_allowlisted + 1))
      echo "[INFO]  ${_base}  allowlisted personal rule — no repo source BY DESIGN. NOT restored after a wipe."
    else
      liveonly_unlisted=$((liveonly_unlisted + 1))
      drift=1
      echo "[DRIFT] ${_base}  live file with no repo source and NOT on the allowlist — review: add to rules-core/ or to the ALLOWLIST array in this script"
    fi
  done
fi
[[ "$((liveonly_allowlisted + liveonly_unlisted))" -eq 0 ]] && echo "(none found)"
echo

# ── Summary ───────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "CORE:      ${core_drift_count} drift / ${core_total} total"
echo "TEMPLATE:  ${template_present} present / ${template_total} total"
echo "LIVE-ONLY: ${liveonly_allowlisted} allowlisted, ${liveonly_unlisted} unlisted"
if [[ "$drift" -eq 0 ]]; then
  echo "Result: no drift"
  exit 0
else
  echo "Result: DRIFT DETECTED — a skip-if-exists reinstall will NOT deliver these fixes to a machine that already has the file; affected files must be copied deliberately (see per-file diff commands above)."
  exit 1
fi
