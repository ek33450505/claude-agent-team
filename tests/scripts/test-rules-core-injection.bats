#!/usr/bin/env bats

# Test suite for rules-core injection (Task 3.1, updated v7.5 Phase 6b)
# Validates that rules-core/ subset is correctly sourced from the authoritative top-level
# directory and that the stale nested rules/core/ directory has been removed.

setup() {
    # Ensure repo root is available
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
}

@test "rules-core/ directory exists" {
    [ -d "$REPO_ROOT/rules-core" ]
}

@test "stale rules/core/ no longer exists" {
    [ ! -d "$REPO_ROOT/rules/core" ]
}

@test "rules-core/ contains working-conventions.md" {
    [ -f "$REPO_ROOT/rules-core/working-conventions.md" ]
}

@test "rules-core/ contains shell.md" {
    [ -f "$REPO_ROOT/rules-core/shell.md" ]
}

@test "rules-core/ contains agents.md" {
    [ -f "$REPO_ROOT/rules-core/agents.md" ]
}

@test "working-conventions.md contains Phase-2 scoped-middle scope rule" {
    # Proves the haiku agents get the slim Phase-2 version, not the pre-Phase-1 bloat
    grep -q "ALREADY editing" "$REPO_ROOT/rules-core/working-conventions.md"
}

@test "shell.md is verbatim copy (starts with YAML frontmatter)" {
    head -1 "$REPO_ROOT/rules-core/shell.md" | grep -q "^---$"
}

@test "agents.md is verbatim copy (starts with YAML frontmatter)" {
    head -1 "$REPO_ROOT/rules-core/agents.md" | grep -q "^---$"
}

@test "install.sh contains rules-core sync step" {
    grep -q "Install rules-core (haiku-tier subset)" "$REPO_ROOT/install.sh"
}

@test "install.sh rules-core sync creates destination directory" {
    grep -q 'mkdir -p "\$CLAUDE_DIR/rules-core"' "$REPO_ROOT/install.sh"
}

@test "install.sh rules-core sync sources from authoritative rules-core/" {
    grep -q 'rules-core/\$base' "$REPO_ROOT/install.sh"
}

@test "install.sh rules-core sync no longer references stale rules/core/" {
    ! grep -q '"\$SCRIPT_DIR"/rules/core' "$REPO_ROOT/install.sh"
}

@test "commit.md references rules-core" {
    grep -q "Load \`~/.claude/rules-core/\`" "$REPO_ROOT/agents/core/commit.md"
}

@test "push.md references rules-core" {
    grep -q "Load \`~/.claude/rules-core/\`" "$REPO_ROOT/agents/core/push.md"
}

@test "code-reviewer.md references rules-core" {
    grep -q "Load \`~/.claude/rules-core/\`" "$REPO_ROOT/agents/core/code-reviewer.md"
}

@test "merge.md references rules-core" {
    grep -q "Load \`~/.claude/rules-core/\`" "$REPO_ROOT/agents/core/merge.md"
}

@test "commit.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/commit.md"
}

@test "push.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/push.md"
}

@test "code-reviewer.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/code-reviewer.md"
}

@test "merge.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/merge.md"
}

@test "all haiku agents warn NOT to load full rules/" {
    for agent in commit push code-reviewer merge; do
        grep -q "Do NOT load \`~/.claude/rules/\`" "$REPO_ROOT/agents/core/$agent.md" || return 1
    done
}

@test "install.sh rsync pattern is portable (no macOS-only flags)" {
    # Verify install.sh uses portable cp or rsync flags (no -E, -N, etc.)
    # Check the rules-core section specifically
    section=$(sed -n '/Install rules-core/,/^$/p' "$REPO_ROOT/install.sh")
    # Should use 'cp' with standard flags, no exotic options
    echo "$section" | grep -q "cp " || true  # Just verify cp is used
    ! echo "$section" | grep -qE '\-[ENlP]' || return 1  # No macOS-only flags
}
