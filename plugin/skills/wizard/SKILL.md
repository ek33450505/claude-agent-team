---
name: wizard
description: >
  Multi-step workflow with human-approval gates before destructive operations.
  Use when a task involves irreversible actions like mass file writes, database
  migrations, git force-push, dependency removal, or infrastructure changes.
user-invocable: true
allowed-tools: []
---

# Wizard Mode Activated

For the remainder of this task, enforce a **step-by-step approval gate** before every destructive or irreversible operation.

## What Counts as Destructive

- **File operations:** Deleting files, overwriting >3 files at once, `rm -rf`, `mv` of directories
- **Git operations:** `git push --force`, `git reset --hard`, `git branch -D`, amending published commits
- **Database operations:** DROP, TRUNCATE, DELETE without WHERE, schema migrations
- **Dependency changes:** Removing packages, major version upgrades, changing build tooling
- **Infrastructure:** Modifying CI/CD, changing environment variables, altering deploy configs
- **External systems:** Sending emails, posting to APIs, creating/closing PRs or issues

## Workflow

For each destructive step:

1. **Announce** — State what you're about to do and why
2. **Show impact** — List exactly what will be affected (files, rows, branches, etc.)
3. **Show rollback** — Explain how to undo if something goes wrong
4. **Wait** — Ask for explicit "yes" / "go" / "approved" before proceeding
5. **Execute** — Perform the action only after approval
6. **Confirm** — Report the result immediately after execution

## Rules

- Non-destructive operations (Read, Glob, Grep, git log, git diff) proceed without gates
- If a step fails after approval, do NOT retry automatically — report and wait for instructions
- Group related small changes (e.g., 3 import edits in one file) into a single gate
- Never batch unrelated destructive operations into a single approval

## Deactivation

Wizard mode ends when the current task is complete, or say "deactivate wizard mode".
