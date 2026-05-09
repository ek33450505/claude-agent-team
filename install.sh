#!/bin/bash
# CAST Installer (v5.0)
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

# --- Install rules-core (haiku-tier subset) ---
info "Installing rules-core (haiku-tier subset)..."
mkdir -p "$CLAUDE_DIR/rules-core"
if [ -d "$SCRIPT_DIR/rules/core" ]; then
    for rule_file in "$SCRIPT_DIR"/rules/core/*; do
        [ -f "$rule_file" ] || continue
        base="$(basename "$rule_file")"
        dest="$CLAUDE_DIR/rules-core/$base"
        cp "$rule_file" "$dest"
        success "  Synced: rules-core/$base"
    done
else
    info "  rules/core/ directory not found (non-fatal)"
fi

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
rm -f "$CLAUDE_DIR/scripts/cast-route-review.sh"
rm -f "$CLAUDE_DIR/scripts/cast-routing-feedback.sh"
rm -f "$CLAUDE_DIR/scripts/cast-mismatch-analyzer.sh"
rm -f "$CLAUDE_DIR/scripts/cast-security-guard.sh"
rm -f "$CLAUDE_DIR/scripts/cast-cost-tracker.sh"
success "  Scripts installed (including cast_db.py)"

# --- Install managed-settings.d fragments ---
# Policy: CAST-owned hook fragments (*-hooks-*.json) overwrite — they ship behavior changes
# that must reach the deployed copy. User-customizable fragments (env, permissions, MCP, etc.)
# skip-if-exists. Downstream-only fragments (filenames not in source) are preserved by
# virtue of never being touched. Backup of the prior CAST-owned copy goes to backups/.
info "Installing settings fragments..."
mkdir -p "$CLAUDE_DIR/managed-settings.d"
for fragment in "$SCRIPT_DIR"/managed-settings.d/*.json; do
    [ -f "$fragment" ] || continue
    base="$(basename "$fragment")"
    dest="$CLAUDE_DIR/managed-settings.d/$base"
    case "$base" in
        *-hooks-*.json)
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

# --- Seed permission-rules.json ---
if [ -f "$SCRIPT_DIR/cast/permission-rules.json" ]; then
    mkdir -p "$CLAUDE_DIR/cast"
    if [ ! -f "$CLAUDE_DIR/cast/permission-rules.json" ]; then
        cp "$SCRIPT_DIR/cast/permission-rules.json" "$CLAUDE_DIR/cast/permission-rules.json"
        success "  Installed: cast/permission-rules.json"
    fi
fi

# --- Install swarm-configs (skip if destination exists — don't overwrite user customizations) ---
if [ -d "$SCRIPT_DIR/swarm-configs" ]; then
    info "Installing swarm configs..."
    mkdir -p "$CLAUDE_DIR/swarm-configs"
    mkdir -p "$CLAUDE_DIR/cast/swarms"
    for config_file in "$SCRIPT_DIR"/swarm-configs/*.yml; do
        [ -f "$config_file" ] || continue
        base="$(basename "$config_file")"
        dest="$CLAUDE_DIR/swarm-configs/$base"
        if [ -f "$dest" ]; then
            info "  Skipped (exists): swarm-configs/$base"
        else
            cp "$config_file" "$dest"
            success "  Installed: swarm-configs/$base"
        fi
    done
fi

# --- Install swarm skill (skip if destination exists) ---
if [ -f "$SCRIPT_DIR/skills/swarm/SKILL.md" ]; then
    info "Installing swarm skill..."
    mkdir -p "$CLAUDE_DIR/skills/swarm"
    dest="$CLAUDE_DIR/skills/swarm/SKILL.md"
    if [ -f "$dest" ]; then
        info "  Skipped (exists): skills/swarm/SKILL.md"
    else
        cp "$SCRIPT_DIR/skills/swarm/SKILL.md" "$dest"
        success "  Installed: skills/swarm/SKILL.md"
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

# --- Wire pre-commit hook ---
git -C "$SCRIPT_DIR" config core.hooksPath .githooks 2>/dev/null || true

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
    printf "  Tip: Run ${BOLD}bash install.sh --personal${NC} to also install personal overlay files (portfolio-sync, personal rules).\n\n"
fi
