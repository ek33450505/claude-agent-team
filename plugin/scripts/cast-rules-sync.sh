#!/usr/bin/env bash
# cast-rules-sync.sh — human-in-the-loop delivery path for rules-core -> live rules.
#
# install.sh copies rules-core/* -> ~/.claude/rules/ SKIP-IF-EXISTS, so a merged
# rules-core fix never reaches an existing live file. This script closes that
# delivery gap WITHOUT making install.sh (an unattended, auto-chained script)
# overwrite hand-tuned live rules — that would be a destructive op with no
# fail-closed gate. Instead this is an explicit, interactive, backed-up sync.
#
# Bucket semantics (mirrors scripts/cast-rules-drift.sh, which stays READ-ONLY):
#   CORE     = rules-core/*.md (no .template suffix). The ONLY files this tool
#              ever writes. Live counterpart: ~/.claude/rules/<same-basename>.
#   TEMPLATE = rules-core/*.md.template -> live drops the suffix. User-specialized
#              by design; content is NEVER compared and NEVER synced.
#   LIVE-ONLY = a live file with no rules-core source. NEVER touched.
#
# Modes:
#   (default)  report-only dry run — prints IN-SYNC / WOULD-UPDATE / WOULD-CREATE
#              per CORE file, with a unified diff for anything that differs.
#              Never writes. Exits 0.
#   --apply    performs the sync: backs up affected live files (fail-closed),
#              confirms interactively, then copies. Refuses to run
#              non-interactively unless CAST_RULES_SYNC_ACK="<reason>" is set
#              (mirrors the CAST_RECONCILE_ACK idiom in
#              scripts/cast-commit-reconcile.py / .githooks/pre-push).
#   --help/-h  usage, exit 0.
#
# Env overrides (for testability — never point tests at the real ~/.claude):
#   CAST_RULES_CORE_DIR         default: <repo-root>/rules-core
#   CAST_LIVE_RULES_DIR         default: $HOME/.claude/rules
#   CAST_RULES_SYNC_BACKUP_DIR  default: $HOME/.claude/backups

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: cast-rules-sync.sh [--apply] [--help]

Default (no args): report-only dry run. Prints IN-SYNC / WOULD-UPDATE /
WOULD-CREATE for every rules-core/*.md CORE file, with a unified diff for
anything that differs. Never writes. Exits 0.

  --apply     Perform the sync: back up affected live files (fail-closed),
              confirm interactively, then copy. Non-interactive callers must
              set CAST_RULES_SYNC_ACK="<reason>" or the run is refused.
  --help, -h  Show this help and exit 0.

Env overrides:
  CAST_RULES_CORE_DIR         default: <repo-root>/rules-core
  CAST_LIVE_RULES_DIR         default: $HOME/.claude/rules
  CAST_RULES_SYNC_BACKUP_DIR  default: $HOME/.claude/backups
EOF
}

# --- repo root resolution --------------------------------------------------
resolve_repo_root() {
	local root
	root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	if [[ -n "$root" && -f "$root/rules-core/working-conventions.md" ]]; then
		printf '%s\n' "$root"
		return 0
	fi

	local fallback="${HOME}/Projects/personal/claude-agent-team"
	if [[ -f "$fallback/rules-core/working-conventions.md" ]]; then
		printf '%s\n' "$fallback"
		return 0
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	printf '%s\n' "$(dirname "$script_dir")"
}

# --- arg parsing -------------------------------------------------------------
MODE="dry-run"
for arg in "$@"; do
	case "$arg" in
	--apply)
		MODE="apply"
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "ERROR: unknown flag: $arg" >&2
		exit 2
		;;
	esac
done

REPO_ROOT="$(resolve_repo_root)"
CORE_DIR="${CAST_RULES_CORE_DIR:-$REPO_ROOT/rules-core}"
LIVE_DIR="${CAST_LIVE_RULES_DIR:-$HOME/.claude/rules}"
BACKUP_ROOT="${CAST_RULES_SYNC_BACKUP_DIR:-$HOME/.claude/backups}"

# --- scan CORE files (rules-core/*.md, never *.md.template) -----------------
core_files=()
while IFS= read -r f; do
	[[ -f "$f" ]] || continue
	core_files+=("$f")
done < <(printf '%s\n' "$CORE_DIR"/*.md 2>/dev/null | sort)

template_count=0
for f in "$CORE_DIR"/*.md.template; do
	[[ -f "$f" ]] || continue
	template_count=$((template_count + 1))
done

if [[ "$template_count" -gt 0 ]]; then
	echo "Skipped $template_count TEMPLATE file(s) (*.md.template) — user-specialized, never synced."
fi

# Hermetic zero-file guard: a scanner that finds nothing must never report clean.
if [[ "${#core_files[@]}" -eq 0 ]]; then
	echo "ERROR: no CORE files (*.md) found under $CORE_DIR — refusing to report clean." >&2
	exit 1
fi

# --- dry run -----------------------------------------------------------------
run_dry_run() {
	local total=0 insync=0 update=0 create=0
	local base live f
	for f in "${core_files[@]}"; do
		base="$(basename "$f")"
		live="$LIVE_DIR/$base"
		total=$((total + 1))
		if [[ ! -f "$live" ]]; then
			echo "WOULD-CREATE: $base"
			create=$((create + 1))
		elif ! diff -q "$live" "$f" >/dev/null 2>&1; then
			echo "WOULD-UPDATE: $base"
			diff -u "$live" "$f" || true
			update=$((update + 1))
		else
			echo "IN-SYNC: $base"
			insync=$((insync + 1))
		fi
	done
	echo ""
	echo "Summary: $total CORE file(s) — $insync in-sync, $update would-update, $create would-create."
	if [[ "$update" -gt 0 || "$create" -gt 0 ]]; then
		echo "To apply: $0 --apply"
	fi
}

# --- apply ---------------------------------------------------------------
run_apply() {
	local to_sync=()
	local base live f
	for f in "${core_files[@]}"; do
		base="$(basename "$f")"
		live="$LIVE_DIR/$base"
		if [[ ! -f "$live" ]] || ! diff -q "$live" "$f" >/dev/null 2>&1; then
			to_sync+=("$base")
		fi
	done

	# 1. Nothing to do -> say so and exit 0 without prompting or backing up.
	if [[ "${#to_sync[@]}" -eq 0 ]]; then
		echo "Nothing to do — all CORE files already in sync."
		exit 0
	fi

	echo "The following CORE file(s) will be synced:"
	for base in "${to_sync[@]}"; do
		echo "  - $base"
	done

	# 2. Back up or abort (fail-closed). Before writing anything.
	local ts backup_dir backed_up=0
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	backup_dir="$BACKUP_ROOT/rules-sync-$ts"
	if ! mkdir -p "$backup_dir"; then
		echo "ERROR: failed to create backup dir $backup_dir — aborting, nothing written." >&2
		exit 1
	fi
	for base in "${to_sync[@]}"; do
		live="$LIVE_DIR/$base"
		if [[ -f "$live" ]]; then
			if ! cp "$live" "$backup_dir/$base"; then
				echo "ERROR: failed to back up $live — aborting, nothing written." >&2
				exit 1
			fi
			backed_up=$((backed_up + 1))
		fi
	done
	if [[ "$backed_up" -gt 0 ]] && [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
		echo "ERROR: backup dir $backup_dir is empty after backing up $backed_up file(s) — aborting, nothing written." >&2
		exit 1
	fi
	echo "Backup written to: $backup_dir"

	# 3 + 4. Confirm interactively, or refuse non-interactive runs without an ack.
	local ack="${CAST_RULES_SYNC_ACK:-}"
	if [[ ! -t 0 ]]; then
		if [[ -z "$ack" ]]; then
			echo "ERROR: --apply requires an interactive TTY to confirm." >&2
			echo "Non-interactive callers must set CAST_RULES_SYNC_ACK=\"<reason>\" to proceed unattended." >&2
			exit 1
		fi
		echo "Non-interactive apply acknowledged via CAST_RULES_SYNC_ACK: $ack"
	else
		local reply
		read -r -p "Apply the above sync? [y/N] " reply
		case "$reply" in
		y | Y | yes | YES | Yes) : ;;
		*)
			echo "Aborted — nothing written."
			exit 0
			;;
		esac
	fi

	# Perform the copy.
	mkdir -p "$LIVE_DIR"
	for base in "${to_sync[@]}"; do
		cp "$CORE_DIR/$base" "$LIVE_DIR/$base"
		echo "Synced: $base"
	done
	echo "Done — ${#to_sync[@]} file(s) synced."
}

case "$MODE" in
dry-run) run_dry_run ;;
apply) run_apply ;;
esac
