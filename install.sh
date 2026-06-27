#!/bin/bash
# CAST Installer
# Copies agents, commands, skills, scripts, and rules to ~/.claude/
set -euo pipefail

# Resolve script directory early — needed by dirty-tree guard and path setup below.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Dirty-tree guard: refuse to overwrite uncommitted edits in paths install.sh touches.
# Set CAST_INSTALL_FORCE=1 to bypass (for CI / test harnesses that manage their own git state).
if [[ "${CAST_INSTALL_FORCE:-0}" != "1" ]]; then
  DIRTY=false
  if ! git -C "$SCRIPT_DIR" diff --quiet HEAD -- agents/ scripts/ bin/ rules-core/ 2>/dev/null; then
    DIRTY=true
  elif git -C "$SCRIPT_DIR" status --porcelain -- agents/ scripts/ bin/ rules-core/ 2>/dev/null | grep -q '^??'; then
    DIRTY=true
  fi
  if [[ "$DIRTY" == "true" ]]; then
    DIRTY_FILES="$(git -C "$SCRIPT_DIR" diff --name-only HEAD -- agents/ scripts/ bin/ rules-core/ 2>/dev/null)"
    echo "ERROR: install.sh aborted — uncommitted changes in install-managed paths:" >&2
    echo "$DIRTY_FILES" >&2
    echo "Commit or stash these changes before running install.sh (or set CAST_INSTALL_FORCE=1 to bypass)." >&2
    exit 1
  fi
fi

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${CYAN}%s${NC}\n" "$1"; }
success() { printf "${GREEN}%s${NC}\n" "$1"; }
warn()    { printf "${YELLOW}%s${NC}\n" "$1"; }
error()   { printf "${RED}%s${NC}\n" "$1"; }

# --- Flags ---
INSTALL_PERSONAL=false
for arg in "$@"; do
    case "$arg" in
        --personal) INSTALL_PERSONAL=true ;;
    esac
done

# --- Paths ---
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/backups/$(date +%Y%m%d-%H%M%S)"

# Counters
AGENT_COUNT=0
CMD_COUNT=0
SKILL_COUNT=0

# --- Pre-flight ---
if ! command -v claude >/dev/null 2>&1; then
    warn "Warning: 'claude' CLI not found in PATH."
fi

if ! command -v bats >/dev/null 2>&1; then
    warn "Warning: 'bats' test framework not found in PATH."
    warn "  Install with: brew install bats-core (macOS) or apt-get install bats (Ubuntu/Debian)"
fi

CAST_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"
printf "\n${BOLD}CAST Installer (v${CAST_VERSION})${NC}\n\n"

# --- Backup existing dirs ---
backup_if_needed() {
    local dir="$1"
    local name="$2"
    if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -R "$dir" "$BACKUP_DIR/$name"
        info "  Backed up $dir -> $BACKUP_DIR/$name"
    fi
}

backup_if_needed "$CLAUDE_DIR/agents" "agents"
backup_if_needed "$CLAUDE_DIR/commands" "commands"
backup_if_needed "$CLAUDE_DIR/skills" "skills"

# --- Create directories ---
mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/skills"
mkdir -p "$CLAUDE_DIR/briefings" "$CLAUDE_DIR/reports" "$CLAUDE_DIR/plans"
mkdir -p "$CLAUDE_DIR/agent-memory-local"
mkdir -p "$CLAUDE_DIR/rules"
mkdir -p "$CLAUDE_DIR/cast/events" "$CLAUDE_DIR/cast/state"
mkdir -p "$CLAUDE_DIR/cast/offline-queue"
mkdir -p "$CLAUDE_DIR/cast/reviews" "$CLAUDE_DIR/cast/artifacts"
mkdir -p "$CLAUDE_DIR/backups"
mkdir -p "$CLAUDE_DIR/agent-status"
mkdir -p "$CLAUDE_DIR/config"
mkdir -p "$CLAUDE_DIR/logs"
mkdir -p "$CLAUDE_DIR/scripts"

# Hook-ownership sentinel: when present, the CAST plugin's hooks defer to install.sh
# (prevents double-firing when both install.sh and the plugin are active on one machine).
printf 'install.sh\n' > "$CLAUDE_DIR/config/cast-hook-owner"

# --- Install agents ---
info "Installing agents..."
for agent_file in "$SCRIPT_DIR"/agents/core/*.md; do
    [ -f "$agent_file" ] || continue
    base="$(basename "$agent_file")"
    cp "$agent_file" "$CLAUDE_DIR/agents/$base"
    AGENT_COUNT=$((AGENT_COUNT + 1))
done

# Personal agent overlay (non-destructive — only adds files)
if [ "$INSTALL_PERSONAL" = true ] && [ -d "$SCRIPT_DIR/agents/personal" ]; then
    for agent_file in "$SCRIPT_DIR"/agents/personal/*.md; do
        [ -f "$agent_file" ] || continue
        base="$(basename "$agent_file")"
        cp "$agent_file" "$CLAUDE_DIR/agents/$base"
        AGENT_COUNT=$((AGENT_COUNT + 1))
    done
fi
success "  $AGENT_COUNT agents installed"

# --- Install commands ---
info "Installing commands..."
for cmd_file in "$SCRIPT_DIR"/commands/*.md; do
    [ -f "$cmd_file" ] || continue
    base="$(basename "$cmd_file")"
    cp "$cmd_file" "$CLAUDE_DIR/commands/$base"
    CMD_COUNT=$((CMD_COUNT + 1))
done
success "  $CMD_COUNT commands installed"

# --- Install skills ---
info "Installing skills..."
for skill_dir in "$SCRIPT_DIR"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$CLAUDE_DIR/skills/$skill_name"
    cp -R "$skill_dir"* "$CLAUDE_DIR/skills/$skill_name/"
    SKILL_COUNT=$((SKILL_COUNT + 1))
done
success "  $SKILL_COUNT skills installed"

# Personal skills overlay (non-destructive — only adds files not already present)
if [ "$INSTALL_PERSONAL" = true ] && [ -d "$SCRIPT_DIR/skills-personal" ]; then
    for skill_dir in "$SCRIPT_DIR"/skills-personal/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name="$(basename "$skill_dir")"
        mkdir -p "$CLAUDE_DIR/skills/$skill_name"
        if [ -f "$CLAUDE_DIR/skills/$skill_name/SKILL.md" ]; then
            info "  Skipped (exists, personal): skills-personal/$skill_name"
        else
            cp -R "$skill_dir"* "$CLAUDE_DIR/skills/$skill_name/"
            success "  Installed (personal): skills-personal/$skill_name"
            SKILL_COUNT=$((SKILL_COUNT + 1))
        fi
    done
fi

# --- Install rules (skip if destination exists) ---
info "Installing rules..."
for rule_file in "$SCRIPT_DIR"/rules-core/*; do
    [ -f "$rule_file" ] || continue
    base="$(basename "$rule_file")"
    dest_name="${base%.template}"
    dest="$CLAUDE_DIR/rules/$dest_name"
    if [ -f "$dest" ]; then
        info "  Skipped (exists): $dest_name"
    else
        cp "$rule_file" "$dest"
        success "  Installed: $dest_name"
    fi
done

# Personal rules overlay (non-destructive — only adds files not already present)
if [ "$INSTALL_PERSONAL" = true ] && [ -d "$SCRIPT_DIR/rules-personal" ]; then
    for rule_file in "$SCRIPT_DIR"/rules-personal/*; do
        [ -f "$rule_file" ] || continue
        base="$(basename "$rule_file")"
        dest_name="${base%.template}"
        dest="$CLAUDE_DIR/rules/$dest_name"
        if [ -f "$dest" ]; then
            info "  Skipped (exists): $dest_name"
        else
            cp "$rule_file" "$dest"
            success "  Installed (personal): $dest_name"
        fi
    done
fi

# Personal managed-settings overlay (non-destructive — only adds files not already present)
# Contains maintainer-specific fragments (e.g. 12-otel.json for the local OTLP feed).
# Other users do NOT get these keys on a plain install.sh run.
if [ "$INSTALL_PERSONAL" = true ] && [ -d "$SCRIPT_DIR/managed-settings-personal" ]; then
    mkdir -p "$CLAUDE_DIR/managed-settings.d"
    for overlay_file in "$SCRIPT_DIR"/managed-settings-personal/*.json; do
        [ -f "$overlay_file" ] || continue
        base="$(basename "$overlay_file")"
        # Validate naming convention: NN-name.json (prevents unrelated files landing in managed-settings.d/)
        if ! [[ "$base" =~ ^[0-9][0-9]-.*\.json$ ]]; then
            warn "  Skipped non-conforming overlay: $base"
            continue
        fi
        dest="$CLAUDE_DIR/managed-settings.d/$base"
        if [ -f "$dest" ]; then
            info "  Skipped (exists): managed-settings-personal/$base"
        else
            cp "$overlay_file" "$dest"
            chmod 600 "$dest"
            success "  Installed (personal): managed-settings-personal/$base"
        fi
    done
fi

# --- Install rules-core (haiku-tier subset) ---
info "Installing rules-core (haiku-tier subset)..."
mkdir -p "$CLAUDE_DIR/rules-core"
# Curated slim subset loaded by haiku-tier agents (code-reviewer, commit, push, merge).
# Source: authoritative rules-core/ at repo root (stale nested rules/core/ removed in v7.5 Phase 6b).
for base in working-conventions.md shell.md agents.md; do
    src="$SCRIPT_DIR/rules-core/$base"
    if [ -f "$src" ]; then
        cp "$src" "$CLAUDE_DIR/rules-core/$base"
        success "  Synced: rules-core/$base"
    else
        info "  Missing source: rules-core/$base (skipped)"
    fi
done

# --- Install scripts (chmod +x) ---
info "Installing scripts..."
for script_file in "$SCRIPT_DIR"/scripts/*; do
    [ -d "$script_file" ] && continue
    base="$(basename "$script_file")"
    dest_name="${base%.template}"
    cp "$script_file" "$CLAUDE_DIR/scripts/$dest_name"
    chmod +x "$CLAUDE_DIR/scripts/$dest_name"
done
# Install migrations/ subdirectory (required by cast-migrate.py at runtime)
if [ -d "$SCRIPT_DIR/scripts/migrations" ]; then
    mkdir -p "$CLAUDE_DIR/scripts/migrations"
    for sql_file in "$SCRIPT_DIR"/scripts/migrations/*.sql; do
        [ -f "$sql_file" ] || continue
        cp "$sql_file" "$CLAUDE_DIR/scripts/migrations/"
    done
    success "  Migrations installed"
fi
# Remove scripts deleted in v4.1 (native feature adoption)
rm -f "$CLAUDE_DIR/scripts/cast-route-install.sh"
# Remove scripts consolidated into write-guards.sh in v7.5 Phase 4
rm -f "$CLAUDE_DIR/scripts/cast-stat-claim-guard.sh" "$CLAUDE_DIR/scripts/cast-tilde-write-guard.sh" "$CLAUDE_DIR/scripts/cast-no-fake-success-guard.sh"
rm -f "$CLAUDE_DIR/scripts/cast-route-review.sh"
rm -f "$CLAUDE_DIR/scripts/cast-routing-feedback.sh"
rm -f "$CLAUDE_DIR/scripts/cast-mismatch-analyzer.sh"
rm -f "$CLAUDE_DIR/scripts/cast-security-guard.sh"
rm -f "$CLAUDE_DIR/scripts/cast-cost-tracker.sh"
# Remove dead scripts + settings-canonical retired in v7.5 Phase 6 (dead-surface sweep)
rm -f "$CLAUDE_DIR/scripts/cast-memory-backup.sh" "$CLAUDE_DIR/scripts/cast-db-migrate-v32.sh" "$CLAUDE_DIR/scripts/cast-ollama.sh"
rm -f "$CLAUDE_DIR/scripts/cast-proactive-intel.sh" "$CLAUDE_DIR/scripts/cast-weekly-tuner.sh" "$CLAUDE_DIR/scripts/cast-weekly-report.sh"
rm -f "$CLAUDE_DIR/scripts/cast-resume-watcher.sh" "$CLAUDE_DIR/scripts/cast-output-adapter.py" "$CLAUDE_DIR/scripts/cast-sync-check.sh"
rm -f "$CLAUDE_DIR/scripts/cast-session-status-cleanup.py" "$CLAUDE_DIR/scripts/cast-pre-compact-hook.sh" "$CLAUDE_DIR/scripts/pa-weather-prefetch.sh"
rm -f "$CLAUDE_DIR/config/settings-canonical.json"
# Remove dead scripts retired in v9 S5 dead-code purge (probe-confirmed unreferenced)
rm -f "$CLAUDE_DIR/scripts/cast-agent-stats.sh" "$CLAUDE_DIR/scripts/cast-backfill-schema-migrations.py" "$CLAUDE_DIR/scripts/cast-batch-status.sh"
rm -f "$CLAUDE_DIR/scripts/cast-ci-monitor.sh" "$CLAUDE_DIR/scripts/cast-code-ref-guard.sh" "$CLAUDE_DIR/scripts/cast-db-verify.py"
rm -f "$CLAUDE_DIR/scripts/cast-egress-hook.sh" "$CLAUDE_DIR/scripts/cast-fswatcher.sh" "$CLAUDE_DIR/scripts/cast-memory-backfill-verified.sh"
rm -f "$CLAUDE_DIR/scripts/cast-memory-dream-migration.py" "$CLAUDE_DIR/scripts/cast-memory-seed-procedural.py" "$CLAUDE_DIR/scripts/cast-rtk-install.sh"
rm -f "$CLAUDE_DIR/scripts/cast-seed-user-profile.sh" "$CLAUDE_DIR/scripts/cast-stack-inject.sh" "$CLAUDE_DIR/scripts/cast-sync.sh"
rm -f "$CLAUDE_DIR/config/fs-watchers.json.template"
# Remove dead scripts retired in v9 §5.1 dead-surface sweep
rm -f "$CLAUDE_DIR/scripts/cast-cron-summary.py" "$CLAUDE_DIR/scripts/cast-integrity-check.sh"
rm -f "$CLAUDE_DIR/scripts/cast-agent-run-log.py" "$CLAUDE_DIR/scripts/cast-parry-guard-monitor.sh"
# Remove dead scripts retired in v9 §5.1 Unit D (zero-live-use helpers)
rm -f "$CLAUDE_DIR/scripts/cast-plugin-install.sh" "$CLAUDE_DIR/scripts/cast-tmux-session.sh"
rm -f "$CLAUDE_DIR/scripts/sync-ecosystem-readme.sh" "$CLAUDE_DIR/scripts/cast-morning-briefing-sdk.py"
# v7.5 Phase 7: removed dead reference skills
rm -rf "$CLAUDE_DIR/skills/compact-discipline" "$CLAUDE_DIR/skills/thinking-budget"
success "  Scripts installed (including cast_db.py)"

# --- Install managed-settings.d fragments ---
# Policy: CAST-owned fragments overwrite — they ship behavior changes that must reach the
# deployed copy. CAST-owned set: *-hooks-*.json (hook wiring), 50-mcp.json (MCP server
# list; managed to propagate removals such as the github-MCP drop), and 11-deny.json
# (categorical security-enforcement deny rules for model cap + destructive Bash patterns;
# must reach existing installs on reinstall). User MCP servers belong in ~/.claude.json
# (user/project scope), NOT in the managed fragment.
# User-customizable fragments (env, permissions, etc.) skip-if-exists.
# Downstream-only fragments (filenames not in source) are preserved by virtue of never being
# touched. Backup of the prior CAST-owned copy goes to backups/.
info "Installing settings fragments..."
mkdir -p "$CLAUDE_DIR/managed-settings.d"
for fragment in "$SCRIPT_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$CLAUDE_DIR/managed-settings.d/$base"
    case "$base" in
        *-hooks-*.json|50-mcp.json|11-deny.json)
            # CAST-owned: overwrite to propagate source updates
            if [ -f "$dest" ] && ! cmp -s "$fragment" "$dest"; then
                mkdir -p "$BACKUP_DIR/managed-settings.d"
                cp "$dest" "$BACKUP_DIR/managed-settings.d/$base"
            fi
            cp "$fragment" "$dest"
            success "  Synced: managed-settings.d/$base"
            ;;
        *)
            # User-customizable: skip if present
            if [ -f "$dest" ]; then
                info "  Skipped (exists): managed-settings.d/$base"
            else
                cp "$fragment" "$dest"
                success "  Installed: managed-settings.d/$base"
            fi
            ;;
    esac
done

# Harden fragment permissions — fragments may contain tokens/paths; 644 is too open
chmod 600 "$CLAUDE_DIR"/managed-settings.d/*.json 2>/dev/null || true
# settings.local.json holds per-install secrets/overrides; tighten if present
[ -f "$CLAUDE_DIR/settings.local.json" ] && chmod 600 "$CLAUDE_DIR/settings.local.json" || true

# --- Regenerate ~/.claude/settings.json from fragments ---
if [ -x "$CLAUDE_DIR/scripts/cast-merge-settings.sh" ]; then
    if bash "$CLAUDE_DIR/scripts/cast-merge-settings.sh" "$CLAUDE_DIR/settings.json" 2>&1 | tail -1; then
        success "  Settings merged from fragments → ~/.claude/settings.json"
    else
        warn "  Settings merge failed — settings.json may be stale. Run: bash ~/.claude/scripts/cast-merge-settings.sh"
    fi
fi

# --- Optional RTK check ---
info "Checking for RTK (optional token compression)..."
if command -v rtk >/dev/null 2>&1; then
    success "  rtk found: $(rtk --version 2>/dev/null || echo 'version unknown')"
else
    info "  rtk not installed (optional — install Rust and run: cargo install --git https://github.com/rtk-ai/rtk)"
fi

# --- Initialize cast.db ---
DB_INIT_SCRIPT="$CLAUDE_DIR/scripts/cast-db-init.sh"
if [ -f "$DB_INIT_SCRIPT" ]; then
    if bash "$DB_INIT_SCRIPT" 2>/dev/null; then
        success "  cast.db initialized"
    else
        warn "  cast.db initialization failed — run cast-db-init.sh manually"
    fi
fi

# --- Run migrations ---
MIGRATE_SCRIPT="$CLAUDE_DIR/scripts/cast-migrate.py"
if [ -f "$MIGRATE_SCRIPT" ]; then
    if python3 "$MIGRATE_SCRIPT" --confirm 2>/dev/null; then
        success "  Database migrations applied"
    else
        warn "  Database migrations failed — run: python3 ~/.claude/scripts/cast-migrate.py"
    fi
fi

# --- Install config/ (only if not present) ---
if [ -d "$SCRIPT_DIR/config" ]; then
    info "Installing config files..."
    for config_file in "$SCRIPT_DIR"/config/*; do
        [ -f "$config_file" ] || continue
        base="$(basename "$config_file")"
        dest="$CLAUDE_DIR/config/$base"
        if [ -f "$dest" ]; then
            info "  Skipped (exists): $base"
        else
            cp "$config_file" "$dest"
            success "  Installed: $base"
        fi
    done
fi

# --- Install ccr (claude-code-router) local-routing config (skip-if-exists) ---
# First-class local cheap-mode (cast cheap) routes via ccr -> Ollama. Deploy a
# working CAST template only if the user has no ccr config yet; never clobber a
# user-customized router config (repair with: cast cheap config).
if [ -f "$SCRIPT_DIR/config/cast-ccr-config.json" ]; then
    CCR_DIR="$HOME/.claude-code-router"
    CCR_DEST="$CCR_DIR/config.json"
    if [ -f "$CCR_DEST" ]; then
        info "  Skipped (exists): ccr config ($CCR_DEST) — repair with: cast cheap config"
    else
        mkdir -p "$CCR_DIR"
        cp "$SCRIPT_DIR/config/cast-ccr-config.json" "$CCR_DEST"
        success "  Installed: ccr local-routing config -> $CCR_DEST"
    fi
fi

# --- Seed permission-rules.json ---
if [ -f "$SCRIPT_DIR/cast/permission-rules.json" ]; then
    mkdir -p "$CLAUDE_DIR/cast"
    if [ ! -f "$CLAUDE_DIR/cast/permission-rules.json" ]; then
        cp "$SCRIPT_DIR/cast/permission-rules.json" "$CLAUDE_DIR/cast/permission-rules.json"
        success "  Installed: cast/permission-rules.json"
    fi
fi

# --- Setup Python venv for TUI dashboard ---
info "Setting up Python venv..."
VENV_DIR="$CLAUDE_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    if python3 -m venv "$VENV_DIR" 2>/dev/null; then
        success "  Created venv at $VENV_DIR"
    else
        warn "  Could not create venv — cast dash will use system Python"
    fi
fi
if [ -x "$VENV_DIR/bin/pip" ]; then
    if "$VENV_DIR/bin/pip" install textual --quiet 2>/dev/null; then
        success "  textual installed in venv"
    else
        warn "  Could not install textual — cast dash may not work"
    fi
fi

# --- Install cast CLI (symlink) ---
info "Installing cast CLI..."
LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "$LOCAL_BIN"
CAST_BIN_SRC="$SCRIPT_DIR/bin/cast"
CAST_BIN_DEST="$LOCAL_BIN/cast"
if [ -f "$CAST_BIN_SRC" ]; then
    chmod +x "$CAST_BIN_SRC"
    rm -f "$CAST_BIN_DEST"
    ln -s "$CAST_BIN_SRC" "$CAST_BIN_DEST"
    success "  Symlinked bin/cast -> $CAST_BIN_DEST"
    if ! echo "$PATH" | tr ':' '\n' | grep -q "$LOCAL_BIN"; then
        warn "  Note: $LOCAL_BIN is not in your PATH"
    fi
fi

# --- Copy VERSION ---
cp "$SCRIPT_DIR/VERSION" "$CLAUDE_DIR/cast-version" 2>/dev/null || true

# --- Shell completions ---
if [ -f "$CAST_BIN_SRC" ]; then
    if bash "$CAST_BIN_SRC" install-completions 2>/dev/null; then
        success "  Shell completions installed"
    fi
fi

# --- Install launchd plist (macOS only) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
    info "Installing launchd scheduler (macOS)..."
    LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$LAUNCH_AGENTS_DIR"

    # launchd registers jobs into the per-USER gui/$uid domain — which $HOME does
    # NOT isolate. A `launchctl load` run under a BATS temp HOME (or any install
    # against a non-real HOME) leaks com.cast.* jobs into the REAL user's launchd,
    # where they outlive the temp dir and hijack the real daemon labels (2026-06-26:
    # one leaked test run displaced 11 live daemons). Guard: skip launchctl
    # registration under a test/CI/temp HOME. Plists are still written below, so the
    # install is otherwise complete.
    _cast_skip_launchctl() {
        [ -n "${CAST_INSTALL_NO_LAUNCHCTL:-}" ] && return 0
        [ -n "${CI:-}" ] && return 0
        [ -n "${CLAUDE_SUBPROCESS:-}" ] && return 0
        [ -f "$HOME/.cast-test-home" ] && return 0   # BATS temp-HOME sentinel
        case "$HOME" in
            /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
        esac
        return 1
    }

    # (Re)load a plist into the user launchd domain, honoring the test/CI guard.
    cast_launchctl_reload() {
        local plist="$1" label="$2"
        if _cast_skip_launchctl; then
            warn "  launchd registration skipped for $label (test/CI/temp HOME — plist written, not loaded)"
            return 0
        fi
        launchctl unload "$plist" 2>/dev/null || true
        if launchctl load "$plist" 2>/dev/null; then
            success "  Installed: $plist ($label)"
        else
            warn "  launchctl load failed for $plist — verify manually"
        fi
    }

    # Evict a plist from the user launchd domain, honoring the test/CI guard.
    cast_launchctl_unload() {
        _cast_skip_launchctl && return 0
        launchctl unload "$1" 2>/dev/null || true
    }

    # Install cast-backup.plist for daily snapshot
    if [ -f "$SCRIPT_DIR/macos/cast-backup.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.backup.plist"
        # Substitute the __HOME__ template token (launchd does not expand ${HOME} in plists).
        # Matches the convention in scripts/com.cast.daemon.plist.
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-backup.plist" > "$PLIST_DEST"

        cast_launchctl_reload "$PLIST_DEST" "com.cast.backup"
    fi

    # Install cast-memory-embed.plist for nightly embedding generation
    if [ -f "$SCRIPT_DIR/macos/cast-memory-embed.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.memory-embed.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-memory-embed.plist" > "$PLIST_DEST"

        cast_launchctl_reload "$PLIST_DEST" "com.cast.memory-embed"
    fi

    # Install cast-wipe-canary.plist — WatchPaths canary that captures forensic
    # evidence outside ~/.claude the instant the directory disappears.
    if [ -f "$SCRIPT_DIR/macos/cast-wipe-canary.plist" ]; then
        # Pillar-2: the invoked script must live OUTSIDE ~/.claude so it survives
        # the very wipe it is meant to detect.  Copy to the off-blast-radius bin
        # dir before registering the plist (script must exist when launchd fires).
        CANARY_BIN_DIR="$HOME/Library/Application Support/cast/bin"
        mkdir -p "$CANARY_BIN_DIR"
        cp "$CLAUDE_DIR/scripts/cast-wipe-canary.sh" "$CANARY_BIN_DIR/cast-wipe-canary.sh"
        chmod +x "$CANARY_BIN_DIR/cast-wipe-canary.sh"
        success "  Installed: $CANARY_BIN_DIR/cast-wipe-canary.sh (off-blast-radius canary script)"

        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.wipe-canary.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-wipe-canary.plist" > "$PLIST_DEST"

        cast_launchctl_reload "$PLIST_DEST" "com.cast.wipe-canary"
    fi

    # Install cast-log-compress.plist — daily runtime rotation (events/logs/legacy
    # backups) at 03:45. Replaces the orphaned, broken hand-installed log-compress.
    if [ -f "$SCRIPT_DIR/macos/cast-log-compress.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.log-compress.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-log-compress.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.log-compress"
    fi

    # Install cast-branch-groomer.plist — weekly (Sun 06:00) multi-repo grooming with
    # live auto-apply on LIVE repos (CAST_GROOM_AUTO_APPLY=1 set in the plist env).
    if [ -f "$SCRIPT_DIR/macos/cast-branch-groomer.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.branch-groomer.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-branch-groomer.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.branch-groomer"
    fi

    # Install cast-abandon-stale-runs.plist — nightly stale agent_runs cleanup (04:00)
    if [ -f "$SCRIPT_DIR/macos/cast-abandon-stale-runs.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.abandon-stale-runs.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-abandon-stale-runs.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.abandon-stale-runs"
    fi

    # Install cast-maintenance.plist — daily maintenance sweep (03:47)
    if [ -f "$SCRIPT_DIR/macos/cast-maintenance.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.cast-maintenance.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-maintenance.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.cast-maintenance"
    fi

    # Install cast-db-backup.plist — daily cast.db backup to off-radius dir (02:00)
    if [ -f "$SCRIPT_DIR/macos/cast-db-backup.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.db-backup.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-db-backup.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.db-backup"
    fi

    # Install cast-db-prune.plist — daily cast.db retention prune (03:30)
    if [ -f "$SCRIPT_DIR/macos/cast-db-prune.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.db-prune.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-db-prune.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.db-prune"
    fi

    # Install cast-tidy.plist — daily cast tidy housekeeping (03:00)
    if [ -f "$SCRIPT_DIR/macos/cast-tidy.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.tidy.plist"
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-tidy.plist" > "$PLIST_DEST"
        cast_launchctl_reload "$PLIST_DEST" "com.cast.tidy"
    fi

    # Retire com.cast.mlx-server (dead local-model-routing daemon, removed v9 A6).
    # Idempotently remove any stale plist left by the pre-retirement setup; ccr now
    # routes to Ollama directly (see config/cast-ccr-config.json).
    _mlx_plist_dest="$LAUNCH_AGENTS_DIR/com.cast.mlx-server.plist"
    if [ -f "$_mlx_plist_dest" ]; then
        cast_launchctl_unload "$_mlx_plist_dest"
        rm -f "$_mlx_plist_dest"
        info "  Removed retired daemon plist: $_mlx_plist_dest (com.cast.mlx-server)"
    fi

    # Install cast-litestream.plist — continuous DB replication daemon (opt-in).
    # Gated on litestream being installed; idempotently removes the plist when absent.
    PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.litestream.plist"
    if command -v litestream >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/macos/cast-litestream.plist" ]; then
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-litestream.plist" > "$PLIST_DEST"

        cast_launchctl_reload "$PLIST_DEST" "com.cast.litestream"
    else
        info "  litestream not installed — replication daemon not registered (opt-in: brew install benbjohnson/litestream/litestream)"
        # Idempotent cleanup: remove any previously installed plist so the daemon
        # does not run on a machine that no longer has litestream.
        cast_launchctl_unload "$PLIST_DEST"
        rm -f "$PLIST_DEST"
    fi

    # Best-effort: run litestream setup (advisory — non-fatal if litestream not installed).
    if [ -f "$CLAUDE_DIR/scripts/cast-litestream-setup.sh" ]; then
        bash "$CLAUDE_DIR/scripts/cast-litestream-setup.sh" || true
    fi

    # Install cast-otel-collector.plist (dormant) — native OTLP→cast.db collector daemon.
    # Telemetry is OFF BY DEFAULT. The plist is written with RunAtLoad=false so it does
    # NOT auto-start at login. Activate explicitly with: bash scripts/cast-otel.sh enable
    # Maintainer: run install.sh --personal to deploy managed-settings-personal/12-otel.json
    # which sets the env keys; then run cast-otel.sh enable to start the daemon.
    if [ -f "$SCRIPT_DIR/macos/cast-otel-collector.plist" ]; then
        PLIST_DEST="$LAUNCH_AGENTS_DIR/com.cast.otel-collector.plist"
        # Preserve an already opt-in-enabled collector (§10.12): cast-otel.sh enable sets
        # RunAtLoad=true via PlistBuddy. A plain reinstall must NOT silently regress an enabled
        # collector back to dormant. Fresh / non-maintainer installs have no prior plist (or
        # RunAtLoad=false) so they stay dormant — telemetry is opt-in OFF by default (§4.1).
        _otel_was_enabled=false
        if [ -f "$PLIST_DEST" ] && /usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$PLIST_DEST" 2>/dev/null | grep -q "true"; then
            _otel_was_enabled=true
        fi
        sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/macos/cast-otel-collector.plist" > "$PLIST_DEST"
        if [ "$_otel_was_enabled" = "true" ]; then
            /usr/libexec/PlistBuddy -c "Set :RunAtLoad true" "$PLIST_DEST" 2>/dev/null || true
            info "  Reinstalled (enabled): $PLIST_DEST — RunAtLoad preserved (was opt-in enabled)"
        else
            info "  Installed (dormant): $PLIST_DEST — activate with: bash scripts/cast-otel.sh enable"
        fi
    fi
fi

# --- Wire git hooks (pre-commit, pre-push, post-merge auto-install) ---
git -C "$SCRIPT_DIR" config core.hooksPath .githooks 2>/dev/null || true

# --- Prune old install-snapshot backups (keep last 5) ---
# Matches only timestamped dirs created by this script: YYYYMMDD-HHMMSS
# Never touches cast-db-*.db files, _*backup* ad-hoc snapshots, or any
# non-timestamp entry — safety guard validated before each rm -rf.
_prune_install_snapshots() {
  local backup_base="$CLAUDE_DIR/backups"
  [ -d "$backup_base" ] || return 0
  local keep_n=5
  # Collect only dirs matching the timestamp pattern (install.sh creates these)
  local snapshot_dirs=()
  while IFS= read -r -d '' d; do
    local dname
    dname="$(basename "$d")"
    if [[ "$dname" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
      snapshot_dirs+=("$d")
    fi
  done < <(find "$backup_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

  local total="${#snapshot_dirs[@]}"
  if [[ "$total" -le "$keep_n" ]]; then
    return 0
  fi

  # Delete oldest dirs beyond keep_n (array is sorted ascending by name = chronological)
  local delete_count=$(( total - keep_n ))
  local pruned=0
  for (( i=0; i<delete_count; i++ )); do
    local target="${snapshot_dirs[$i]}"
    local tname
    tname="$(basename "$target")"
    # Final safety: re-validate pattern + ensure strictly inside backup_base
    if [[ ! "$tname" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
      warn "  Skipping prune — unexpected dir name: $tname"
      continue
    fi
    local real_target real_base
    real_target="$(cd "$target" && pwd)"
    real_base="$(cd "$backup_base" && pwd)"
    if [[ "$real_target" != "$real_base"/* ]]; then
      warn "  Skipping prune — $tname is not inside backup base"
      continue
    fi
    rm -rf "$target"
    pruned=$(( pruned + 1 ))
  done
  if [[ "$pruned" -gt 0 ]]; then
    info "  Pruned $pruned old install snapshot(s) (keeping $keep_n most recent)"
  fi
}
_prune_install_snapshots

# --- Update README stats ---
bash "$SCRIPT_DIR/scripts/gen-stats.sh" 2>/dev/null || true

# --- Summary ---
printf "\n${GREEN}${BOLD}Installation complete! (CAST v${CAST_VERSION})${NC}\n\n"
printf "  Installed: $AGENT_COUNT agents, $CMD_COUNT commands, $SKILL_COUNT skills\n\n"
printf "Next steps:\n"
printf "  1. Run ${BOLD}cast status${NC} to verify\n"
printf "  2. Run ${BOLD}cast doctor${NC} for health check\n"
printf "  3. Run ${BOLD}cast agents${NC} to see installed agents\n\n"
if [ "$INSTALL_PERSONAL" = false ]; then
    printf "  Tip: Run ${BOLD}bash install.sh --personal${NC} to also install personal-overlay files from agents/personal/, rules-personal/, skills-personal/, and managed-settings-personal/ (for clones that populate them).\n\n"
fi
