#!/bin/bash
# post-write-review.sh — PostToolUse hook for Write|Edit
# Reminds the Senior Dev to dispatch code-reviewer after code changes.
# This is a prompt-type hook output (stdout becomes additionalContext).

echo "**[CAST]** You just modified code. After completing your current logical unit of changes, dispatch the \`code-reviewer\` agent (haiku) to review. Do NOT skip this step."
