#!/bin/bash
# CAST Installer (v4 rebuild)
# Copies agents, commands, skills, scripts, and rules to ~/.claude/
set -euo pipefail

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

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
for rule_file in "$SCRIPT_DIR"/rules/*; do
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

# --- Install scripts (chmod +x) ---
info "Installing scripts..."
for script_file in "$SCRIPT_DIR"/scripts/*; do
    [ -d "$script_file" ] && continue
    base="$(basename "$script_file")"
    dest_name="${base%.template}"
    cp "$script_file" "$CLAUDE_DIR/scripts/$dest_name"
    chmod +x "$CLAUDE_DIR/scripts/$dest_name"
done
success "  Scripts installed (including cast_db.py)"

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
