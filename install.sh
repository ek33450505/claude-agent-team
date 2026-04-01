#!/bin/bash
# Claude Agent Team — Installer
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

# --- Platform Detection ---
PLATFORM="$(uname -s)"
IS_MACOS=false
if [ "$PLATFORM" = "Darwin" ]; then
  IS_MACOS=true
fi

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/backups/$(date +%Y%m%d-%H%M%S)"

# Counters
AGENT_COUNT=0
CMD_COUNT=0
SKILL_COUNT=0

# --- Agent / command / skill lists ---
CORE_AGENTS="planner debugger test-runner code-reviewer commit security push code-writer bash-specialist merge orchestrator morning-briefing devops researcher docs test-writer"

ALL_CMDS="bash cast commit debug devops docs doctor merge morning orchestrate plan push research review secure test"

GENERAL_SKILLS="briefing-writer careful-mode freeze-mode git-activity merge plan wizard"

# --- Pre-flight check ---
if ! command -v claude >/dev/null 2>&1; then
    warn "Warning: 'claude' CLI not found in PATH. Install it before using the framework."
fi

printf "\n${BOLD}Claude Agent Team — Installer (v3)${NC}\n\n"
printf "  Installing 16 agents, 16 commands, 7 skills\n\n"
info "Starting installation..."

# --- Backup existing dirs if non-empty ---
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
mkdir -p "$CLAUDE_DIR/briefings" "$CLAUDE_DIR/meetings" "$CLAUDE_DIR/reports" "$CLAUDE_DIR/plans"
mkdir -p "$CLAUDE_DIR/agent-memory-local"
mkdir -p "$CLAUDE_DIR/rules"
mkdir -p "$CLAUDE_DIR/cast/events"
mkdir -p "$CLAUDE_DIR/cast/state"
mkdir -p "$CLAUDE_DIR/cast/reviews"
mkdir -p "$CLAUDE_DIR/cast/artifacts"
mkdir -p "$CLAUDE_DIR/agent-status"
mkdir -p "$CLAUDE_DIR/config"
mkdir -p "$CLAUDE_DIR/logs"

# --- Initialize cast.db (Phase 7a: SQLite state foundation) ---
# Scripts are copied below; run init after they land in ~/.claude/scripts/
# Deferred — see "Initialize cast.db" block after script install step.

# --- Install agents (flat — all from agents/core/) ---
install_agents() {
    for agent in "$@"; do
        local src="$SCRIPT_DIR/agents/core/$agent.md"
        if [ -f "$src" ]; then
            cp "$src" "$CLAUDE_DIR/agents/$agent.md"
            AGENT_COUNT=$((AGENT_COUNT + 1))
        else
            warn "  Agent not found: $src"
        fi
    done
}

info "Installing agents..."
install_agents $CORE_AGENTS
success "  $AGENT_COUNT agents installed"

# --- Install commands ---
install_cmds() {
    for cmd in "$@"; do
        local src="$SCRIPT_DIR/commands/$cmd.md"
        if [ -f "$src" ]; then
            cp "$src" "$CLAUDE_DIR/commands/$cmd.md"
            CMD_COUNT=$((CMD_COUNT + 1))
        else
            warn "  Command not found: $src"
        fi
    done
}

info "Installing commands..."
install_cmds $ALL_CMDS
success "  $CMD_COUNT commands installed"

# --- Install skills (preserve subdirectory structure) ---
install_skill() {
    local skill="$1"
    local src_dir="$SCRIPT_DIR/skills/$skill"
    if [ -d "$src_dir" ]; then
        mkdir -p "$CLAUDE_DIR/skills/$skill"
        cp -R "$src_dir"/* "$CLAUDE_DIR/skills/$skill/"
        SKILL_COUNT=$((SKILL_COUNT + 1))
    else
        warn "  Skill not found: $src_dir"
    fi
}

info "Installing skills..."
for skill in $GENERAL_SKILLS; do
    install_skill "$skill"
done
success "  $SKILL_COUNT skills installed"

# --- Install rules (skip if destination exists, strip .template) ---
info "Installing rules..."
for rule_file in "$SCRIPT_DIR"/rules/*; do
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

# --- Install scripts (strip .template, chmod +x) ---
info "Installing scripts..."
mkdir -p "$CLAUDE_DIR/scripts"
for script_file in "$SCRIPT_DIR"/scripts/*; do
    [ -d "$script_file" ] && continue  # skip subdirectories (e.g. scripts/hooks/)
    base="$(basename "$script_file")"
    dest_name="${base%.template}"
    cp "$script_file" "$CLAUDE_DIR/scripts/$dest_name"
    chmod +x "$CLAUDE_DIR/scripts/$dest_name"
    success "  Installed: $dest_name"
done

# --- Initialize cast.db (SQLite state foundation — Phase 7a) ---
DB_INIT_SCRIPT="$CLAUDE_DIR/scripts/cast-db-init.sh"
if [ -f "$DB_INIT_SCRIPT" ]; then
  if bash "$DB_INIT_SCRIPT" 2>/dev/null; then
    success "  cast.db initialized"
  else
    warn "  cast.db initialization failed — run scripts/cast-db-init.sh manually if needed"
  fi
fi

# --- Install config/ (routing table and other configs) ---
if [ -d "$SCRIPT_DIR/config" ]; then
  info "Installing config files..."
  mkdir -p "$CLAUDE_DIR/config"
  for config_file in "$SCRIPT_DIR"/config/*; do
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

# --- Install config.sh (only if doesn't exist) ---
if [ ! -f "$CLAUDE_DIR/config.sh" ]; then
    cp "$SCRIPT_DIR/config.sh.template" "$CLAUDE_DIR/config.sh"
    success "  Installed: config.sh"
else
    info "  Skipped (exists): config.sh"
fi

# --- Copy VERSION file ---
cp "$SCRIPT_DIR/VERSION" "$CLAUDE_DIR/cast-version" 2>/dev/null || true

# --- Phase 7e: Install cast CLI (bin/cast symlink) ---
info "Installing cast CLI..."
LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "$LOCAL_BIN"
CAST_BIN_SRC="$SCRIPT_DIR/bin/cast"
CAST_BIN_DEST="$LOCAL_BIN/cast"
if [ -f "$CAST_BIN_SRC" ]; then
  chmod +x "$CAST_BIN_SRC"
  # Remove stale symlink or file if present
  rm -f "$CAST_BIN_DEST"
  ln -s "$CAST_BIN_SRC" "$CAST_BIN_DEST"
  success "  Symlinked bin/cast → $CAST_BIN_DEST"
  if ! echo "$PATH" | tr ':' '\n' | grep -q "$LOCAL_BIN"; then
    warn "  Note: $LOCAL_BIN is not in your PATH. Add to ~/.zshrc or ~/.bashrc:"
    warn "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
else
  warn "  bin/cast not found — skipping CLI symlink"
fi

# --- Phase 7e: Copy cast-cli.json config (only if not present) ---
CAST_CLI_CONFIG_SRC="$SCRIPT_DIR/config/cast-cli.json"
CAST_CLI_CONFIG_DEST="$CLAUDE_DIR/config/cast-cli.json"
if [ -f "$CAST_CLI_CONFIG_SRC" ]; then
  if [ ! -f "$CAST_CLI_CONFIG_DEST" ]; then
    cp "$CAST_CLI_CONFIG_SRC" "$CAST_CLI_CONFIG_DEST"
    success "  Installed: config/cast-cli.json"
  else
    info "  Skipped (exists): config/cast-cli.json"
  fi
fi

# --- Phase 7e: Install shell completions ---
if [ -f "$CAST_BIN_DEST" ] && command -v "$CAST_BIN_DEST" >/dev/null 2>&1; then
  if bash "$CAST_BIN_DEST" install-completions 2>/dev/null; then
    success "  Shell completions installed"
  else
    info "  Shell completions skipped (run: cast install-completions)"
  fi
elif [ -f "$CAST_BIN_SRC" ]; then
  if bash "$CAST_BIN_SRC" install-completions 2>/dev/null; then
    success "  Shell completions installed"
  else
    info "  Shell completions skipped (run: cast install-completions)"
  fi
fi

# --- Copy templates for user review (never overwrite originals) ---
info "Copying templates for review..."
cp "$SCRIPT_DIR/CLAUDE.md.template" "$CLAUDE_DIR/CLAUDE.md.template"
cp "$SCRIPT_DIR/settings.template.json" "$CLAUDE_DIR/settings.template.json"
if [ -f "$SCRIPT_DIR/settings.template.jsonc" ]; then
    cp "$SCRIPT_DIR/settings.template.jsonc" "$CLAUDE_DIR/settings.template.jsonc"
fi
success "  Templates copied (review before renaming)"

# --- Post-install summary ---
CAST_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"
printf "\n${GREEN}${BOLD}Installation complete! (CAST v${CAST_VERSION})${NC}\n\n"
printf "Next steps:\n"
printf "  1. Edit ${BOLD}~/.claude/config.sh${NC} — add your project directories\n"
printf "  2. Edit ${BOLD}~/.claude/rules/stack-context.md${NC} — describe your tech stack\n"
printf "  3. Edit ${BOLD}~/.claude/rules/project-catalog.md${NC} — list your projects\n"
printf "  4. Review ${BOLD}~/.claude/CLAUDE.md.template${NC} — rename to CLAUDE.md when ready\n"
printf "  5. Review ${BOLD}~/.claude/settings.template.json${NC} — merge into your settings\n"
printf "  6. In Claude Code, type ${BOLD}/help${NC} to see all installed agents and routing patterns\n"
printf "  7. Try: ${BOLD}\"write a test for my function\"${NC} — CAST routing will dispatch test-writer automatically\n"
printf "  8. Run: ${BOLD}cast status${NC} to see the CAST Local-First OS health dashboard\n"

# --- Phase 7f: Check Presidio availability ---
printf "\n${CYAN}Privacy Layer (Phase 7f):${NC}\n"
if python3 -c "import presidio_analyzer, presidio_anonymizer" 2>/dev/null; then
  success "  Presidio installed — cast-redact.py PII redaction is active"
else
  warn "  Presidio not installed. To enable PII redaction:"
  warn "    pip install presidio-analyzer presidio-anonymizer"
  warn "    python3 -m spacy download en_core_web_lg"
  warn "  cast-redact.py will use regex-only fallback mode until then."
fi
# --- Optional: OpenTelemetry export configuration ---
# export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
# When set, CAST will export metrics and logs via OTLP to your observability backend.
# Unset = console exporter (default, no external dependency).
# The cast-session-start-hook.sh automatically detects this variable and wires
# OTEL_METRICS_EXPORTER and OTEL_LOGS_EXPORTER into the session environment.

printf "  Audit log: ${BOLD}~/.claude/logs/audit.jsonl${NC}\n"
printf "  To enable the PreToolUse audit hook, add to ${BOLD}~/.claude/settings.json${NC}:\n"
printf '    "PreToolUse": [{"hooks": [{"type": "command", "command": "bash ~/.claude/scripts/cast-audit-hook.sh"}]}]\n'
printf "  (See settings.template.jsonc for the full example)\n"
printf "\n"
success "Installed: $AGENT_COUNT agents, $CMD_COUNT commands, $SKILL_COUNT skills  [v3.0]"

# --- Update README stat tokens ---
echo "Syncing README stats..."
bash "$(dirname "$0")/scripts/gen-stats.sh" 2>/dev/null || true

# --- Wire pre-commit hook ---
git -C "$(dirname "$0")" config core.hooksPath .githooks 2>/dev/null || true
echo "Pre-commit hook wired (.githooks/pre-commit)"

printf "\n"
