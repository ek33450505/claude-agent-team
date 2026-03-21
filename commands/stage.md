Use the `auto-stager` agent to intelligently stage files and hand off to the commit agent.

$ARGUMENTS

The auto-stager will:
1. Run git status to assess what changed
2. Stage appropriate source files (never .env, build artifacts, or secrets)
3. Show what was staged vs skipped
4. Hand off to the commit agent for the semantic commit message
