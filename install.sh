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
CORE_AGENTS="planner debugger test-writer code-reviewer data-scientist db-reader commit security push code-writer bash-specialist"
EXTENDED_AGENTS="architect tdd-guide build-error-resolver e2e-runner refactor-cleaner doc-updater readme-writer router"
PRODUCTIVITY_AGENTS="researcher report-writer meeting-notes email-manager morning-briefing"
PROFESSIONAL_AGENTS="browser qa-reviewer presenter"
ORCHESTRATION_AGENTS="orchestrator auto-stager chain-reporter verifier test-runner"
SPECIALIST_AGENTS="devops performance seo-content linter"

CORE_CMDS="plan review debug test secure commit data query push"
EXTENDED_CMDS="architect tdd build-fix e2e refactor docs readme"
PRODUCTIVITY_CMDS="research report meeting email morning"
PROFESSIONAL_CMDS="browser qa present"
ALWAYS_CMDS="eval cast"

MACOS_SKILLS="calendar-fetch inbox-fetch reminders-fetch"
LINUX_SKILLS="calendar-fetch-linux inbox-fetch-linux"
GENERAL_SKILLS="action-items briefing-writer git-activity careful-mode freeze-mode wizard"

# --- Pre-flight check ---
if ! command -v claude >/dev/null 2>&1; then
    warn "Warning: 'claude' CLI not found in PATH. Install it before using the framework."
fi

# --- Menu ---
printf "\n${BOLD}Claude Agent Team — Installer${NC}\n\n"
printf "  ${BOLD}[1]${NC} Full install — all 36 agents, 26 commands, 9 skills, scripts, rules\n"
printf "  ${BOLD}[2]${NC} Core only   — 11 core agents + their commands (minimal, portable)\n"
printf "  ${BOLD}[3]${NC} Custom      — choose categories\n"
printf "\n"
printf "Enter choice [1/2/3]: "
read -r CHOICE

# Determine what to install
INSTALL_CORE=true
INSTALL_EXTENDED=false
INSTALL_PRODUCTIVITY=false
INSTALL_PROFESSIONAL=false
INSTALL_SPECIALIST=false
INSTALL_MACOS_SKILLS=false

case "$CHOICE" in
    1)
        INSTALL_EXTENDED=true
        INSTALL_PRODUCTIVITY=true
        INSTALL_PROFESSIONAL=true
        INSTALL_SPECIALIST=true
        if $IS_MACOS; then
            INSTALL_MACOS_SKILLS=true
        fi
        ;;
    2)
        # Core only — defaults are fine
        ;;
    3)
        printf "\nSelect categories to install (core agents always included):\n\n"

        printf "  Extended agents (8): architect, tdd-guide, build-error-resolver,\n"
        printf "    e2e-runner, refactor-cleaner, doc-updater, readme-writer, router\n"
        printf "  Install? [y/N]: "
        read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] && INSTALL_EXTENDED=true

        printf "\n  Productivity agents (5): researcher, report-writer, meeting-notes,\n"
        printf "    email-manager, morning-briefing\n"
        printf "  Install? [y/N]: "
        read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] && INSTALL_PRODUCTIVITY=true

        printf "\n  Professional agents (3): browser, qa-reviewer, presenter\n"
        printf "  Install? [y/N]: "
        read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] && INSTALL_PROFESSIONAL=true

        printf "\n  Specialist agents (4): devops, performance, seo-content, linter\n"
        printf "  Install? [y/N]: "
        read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] && INSTALL_SPECIALIST=true

        if $IS_MACOS; then
            printf "\n  macOS skills (calendar-fetch, inbox-fetch, reminders-fetch)\n"
            warn "  Note: these require Microsoft Outlook for calendar/email."
            printf "  Install? [y/N]: "
            read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] && INSTALL_MACOS_SKILLS=true
        else
            warn "\n  macOS skills skipped — not running on macOS (detected: $PLATFORM)"
        fi
        ;;
    *)
        error "Invalid choice. Exiting."
        exit 1
        ;;
esac

printf "\n"
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

# --- Install agents (flat — strip subdirectory structure) ---
install_agents() {
    local subdir="$1"
    shift
    for agent in "$@"; do
        local src="$SCRIPT_DIR/agents/$subdir/$agent.md"
        if [ -f "$src" ]; then
            cp "$src" "$CLAUDE_DIR/agents/$agent.md"
            AGENT_COUNT=$((AGENT_COUNT + 1))
        else
            warn "  Agent not found: $src"
        fi
    done
}

info "Installing agents..."
install_agents "core" $CORE_AGENTS
$INSTALL_EXTENDED && install_agents "extended" $EXTENDED_AGENTS
$INSTALL_PRODUCTIVITY && install_agents "productivity" $PRODUCTIVITY_AGENTS
$INSTALL_PROFESSIONAL && install_agents "professional" $PROFESSIONAL_AGENTS
install_agents "orchestration" $ORCHESTRATION_AGENTS
$INSTALL_SPECIALIST && install_agents "specialist" $SPECIALIST_AGENTS
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
install_cmds $ALWAYS_CMDS
install_cmds $CORE_CMDS
$INSTALL_EXTENDED && install_cmds $EXTENDED_CMDS
$INSTALL_PRODUCTIVITY && install_cmds $PRODUCTIVITY_CMDS
$INSTALL_PROFESSIONAL && install_cmds $PROFESSIONAL_CMDS
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
if $INSTALL_MACOS_SKILLS; then
    for skill in $MACOS_SKILLS; do
        install_skill "$skill"
    done
else
    # Install Linux stubs for macOS-only skills
    for skill in $LINUX_SKILLS; do
        install_skill "$skill"
    done
fi
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
    base="$(basename "$script_file")"
    dest_name="${base%.template}"
    cp "$script_file" "$CLAUDE_DIR/scripts/$dest_name"
    chmod +x "$CLAUDE_DIR/scripts/$dest_name"
    success "  Installed: $dest_name"
done

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
printf "\n"
success "Installed: $AGENT_COUNT agents, $CMD_COUNT commands, $SKILL_COUNT skills  [v${CAST_VERSION}]"
if ! $IS_MACOS; then
    warn "Note: macOS skills were replaced with Linux stubs. Morning briefings will use git-activity and action-items only."
fi

# --- Update README stat tokens ---
if [ -f "$SCRIPT_DIR/scripts/gen-stats.sh" ] && [ -f "$SCRIPT_DIR/README.md" ]; then
    bash "$SCRIPT_DIR/scripts/gen-stats.sh" "$SCRIPT_DIR/README.md" >/dev/null 2>&1 || true
fi

printf "\n"
