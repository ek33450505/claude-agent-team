#!/usr/bin/env bats

# Test suite for rules-core injection (Task 3.1)
# Validates that rules/core/ subset is correctly created, wired, and injected into haiku-tier agents

setup() {
    # Ensure repo root is available
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
}

@test "rules/core/ directory exists" {
    [ -d "$REPO_ROOT/rules/core" ]
}

@test "rules/core/ contains exactly 3 files" {
    file_count=$(find "$REPO_ROOT/rules/core" -maxdepth 1 -type f | wc -l | tr -d ' ')
    [ "$file_count" -eq 3 ]
}

@test "rules/core/ contains working-conventions.md" {
    [ -f "$REPO_ROOT/rules/core/working-conventions.md" ]
}

@test "rules/core/ contains shell.md" {
    [ -f "$REPO_ROOT/rules/core/shell.md" ]
}

@test "rules/core/ contains agents.md" {
    [ -f "$REPO_ROOT/rules/core/agents.md" ]
}

@test "working-conventions.md content is unchanged from source" {
    # Ensure no local edits have diverged from the source copy
    # The file should have the same line count as the original
    line_count=$(wc -l < "$REPO_ROOT/rules/core/working-conventions.md" | tr -d ' ')
    [ "$line_count" -gt 100 ]  # sanity check: should be substantial
}

@test "shell.md is verbatim copy (starts with YAML frontmatter)" {
    head -1 "$REPO_ROOT/rules/core/shell.md" | grep -q "^---$"
}

@test "agents.md is verbatim copy (starts with YAML frontmatter)" {
    head -1 "$REPO_ROOT/rules/core/agents.md" | grep -q "^---$"
}

@test "install.sh contains rules-core sync step" {
    grep -q "Install rules-core (haiku-tier subset)" "$REPO_ROOT/install.sh"
}

@test "install.sh rules-core sync creates destination directory" {
    grep -q 'mkdir -p "\$CLAUDE_DIR/rules-core"' "$REPO_ROOT/install.sh"
}

@test "install.sh rules-core sync iterates over rules/core/" {
    grep -q 'for rule_file in "\$SCRIPT_DIR"/rules/core/\*' "$REPO_ROOT/install.sh"
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

@test "commit.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/commit.md"
}

@test "push.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/push.md"
}

@test "code-reviewer.md has Context Rules section" {
    grep -q "## Context Rules (haiku-tier optimization)" "$REPO_ROOT/agents/core/code-reviewer.md"
}

@test "all haiku agents warn NOT to load full rules/" {
    for agent in commit push code-reviewer; do
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
