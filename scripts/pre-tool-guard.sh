#!/usr/bin/env bash
# pre-tool-guard.sh — thin wrapper for the PreToolUse git + policy guard.
#
# CAST v9 P0: the logic (git commit/push/stash blocks + Write/Edit policy engine)
# was ported to cast-git-guard.py so it can run in-process inside the unified
# cast-pretool-dispatch.py — ONE source of truth, no bash/python duplication.
#
# This wrapper is retained as the standalone PreToolUse entrypoint and as the
# test entrypoint for tests/pre-tool-guard.bats + tests/test_push_agent_stash_guard.bats
# (the lesson tests that prove the ported guarantees). The LIVE hook wiring now
# routes through cast-pretool-dispatch.py.
#
# Exit 2 = hard block (Claude cannot bypass). Exit 0 = allow.
# Escape hatches (leading env-var assignment): CAST_COMMIT_AGENT=1 git commit,
# CAST_PUSH_OK=1 git push, CAST_STASH_OK=1 git stash, CAST_POLICY_OVERRIDE=1.

# Skip for CAST-internal subprocesses (consistency with every other CAST hook; latency)
if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cast-git-guard.py"
