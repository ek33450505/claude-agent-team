#!/usr/bin/env python3
"""cast-pretool-dispatch.py — CAST v9 P0 unified PreToolUse dispatcher.

Collapses the three serial Bash-path PreToolUse hooks — the egress sentinel,
the git/policy guard (pre-tool-guard), and the command-guard — into ONE process.
Bash hot path: 6 spawns (3 bash shims + 3 python cold-starts, ~78 ms measured)
→ 1 python process (~15 ms floor). Realizes master_v9.md §0.5 / P0
("one dispatcher process per tool call, not N").

SUBTRACTION SAFETY GATE (master_v9.md §0.2): this dispatcher REUSES the exact
logic modules the standalone wrappers wrap —
  cast-egress-sentinel.py   (classify / assess_sensitivity / record / emit_advisory)
  cast-git-guard.py         (evaluate: git commit/push/stash + Write/Edit policy)
  cast-command-guard.py     (safe_is_blocked: pkill/killall/mass-kill/catastrophic-rm)
so cast-egress-sentinel.bats / pre-tool-guard.bats / test_push_agent_stash_guard.bats
/ cast-command-guard.bats keep proving the underlying guarantees, and
cast-pretool-dispatch.bats proves the routing + integration. Replace-then-remove:
the wrappers stay on disk as those test entrypoints; only the live hook WIRING is
repointed here.

ROUTING (by tool_name):
  1. HARD BLOCKS first — CPU-bound (regex only, no I/O), so the wipe-protection
     guard is guaranteed to run before any egress I/O could stall the hook's
     timeout budget:
       Bash:        git-guard (commit/push/stash) THEN command-guard (kill/rm).
       Write/Edit:  git-guard policy engine (TTL sweep + config/policies.json).
     First hard block wins → block reason to stderr + exit 2.
  2. EGRESS scope (mcp__*, WebFetch, WebSearch, Bash, Read), reached only when
     nothing hard-blocked: classify + RECORD to the local egress ledger (the KEEP
     value — master_v9.md §1) + emit advisory (record-only). The hard-block set
     (git/kill/rm) and the egress-record set (network/credential) are DISJOINT for
     Bash (verified: the egress sentinel records none of the blocked commands), so
     evaluating blocks first loses no audit record while making command-guard
     robust against a slow egress write.

FAIL-OPEN per guard: a crash/missing module in one guard never suppresses another
(each load + call is independently guarded), and any load failure is logged to
hook-errors.log so `cast doctor` can surface a silently-disabled guard. command-
guard is always evaluated for Bash unless git-guard already hard-blocked — which
prevents the whole command from executing anyway. CLAUDE_SUBPROCESS=1 → skip. Any
unhandled error → exit 0 (allow); a guard crash must never block all tool use.

CONTRACT (identical to the wrappers): exit 2 + stderr = block; stdout
hookSpecificOutput JSON = egress advisory; exit 0 = allow.

ENFORCEMENT vs AWARENESS (master_v9.md §0.3): these guards are ADVISORY-grade — the
model-facing block in an interactive session, NOT the non-bypassable wall. The real
boundary for the catastrophic classes (credential reads, network egress, filesystem)
is the OS sandbox (sandbox.filesystem.denyRead / network.allowedDomains) + permissions.
deny, which native rules enforce for all subprocesses. These hooks remain the path-aware
/ escape-hatch / indirection-robust layer native rules cannot express, and the record.
See docs/architecture/enforcement-awareness-split.md for the full classification.
"""
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Egress scope = the original cast-egress-sentinel matcher set (plus any mcp__*).
_EGRESS_TOOLS = ("WebFetch", "WebSearch", "Bash", "Read")

_MODULE_CACHE = {}


def _log_error(msg):
    """Append to hook-errors.log so a silently-disabled guard is observable. Never raises."""
    try:
        log_dir = os.path.join(os.path.expanduser("~"), ".claude", "logs")
        os.makedirs(log_dir, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(os.path.join(log_dir, "hook-errors.log"), "a") as f:
            f.write(f"[{ts}] ERROR cast-pretool-dispatch.py: {msg}\n")
    except Exception:
        pass


def _load(mod_name, filename):
    """Load a hyphen-named sibling script as a module, cached. Fail-soft → None.

    A None return means a guard is silently disabled for this process — log it
    (M2) so `cast doctor` / hook-errors.log surfaces the lost protection."""
    if mod_name in _MODULE_CACHE:
        return _MODULE_CACHE[mod_name]
    mod = None
    try:
        path = os.path.join(SCRIPT_DIR, filename)
        spec = importlib.util.spec_from_file_location(mod_name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:
        mod = None
        _log_error(f"guard module failed to load ({filename}) — guard DISABLED this call: {e}")
    _MODULE_CACHE[mod_name] = mod
    return mod


def _is_egress_tool(tool):
    return tool in _EGRESS_TOOLS or tool.startswith("mcp__")


def _run_egress(sentinel, data):
    """Replicate cast-egress-sentinel.main()'s body with pre-parsed data.

    RECORDS (the KEEP value); returns an action tuple or None.
    ("advisory", verdict) or None. Never raises."""
    try:
        tool_name = data.get("tool_name", "") or ""
        tool_input = data.get("tool_input", {}) or {}
        if not isinstance(tool_input, dict):
            tool_input = {}
        session_id = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID", "unknown")
        policy = sentinel._load_policy()
        event = sentinel.classify(tool_name, tool_input, policy)
        if event is None:
            return None
        verdict = sentinel.assess_sensitivity(event, tool_input)
        sentinel.record(event, verdict, tool_name, session_id)
        if verdict.get("severity") == "warn":
            return ("advisory", verdict)
        return None
    except Exception:
        return None


def _emit_egress(sentinel, action):
    try:
        kind, payload = action
        if kind == "advisory":
            sentinel.emit_advisory(payload)
    except Exception:
        pass


def _block(message):
    if message:
        print(message, file=sys.stderr)
    return 2


def main():
    if os.environ.get("CLAUDE_SUBPROCESS", "0") == "1":
        return 0
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    if not raw.strip():
        return 0
    try:
        data = json.loads(raw)
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0

    tool = data.get("tool_name", "") or ""
    tool_input = data.get("tool_input", {}) or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    # 1. HARD BLOCKS first (CPU-bound; run before any egress I/O).
    #    git-guard covers Bash git guards AND Write/Edit policy (mirrors pre-tool-guard).
    if tool in ("Bash", "Write", "Edit"):
        git_guard = _load("cast_git_guard", "cast-git-guard.py")
        if git_guard is not None:
            try:
                code, msg = git_guard.evaluate(tool, tool_input)
            except Exception:
                code, msg = 0, ""
            if code == 2:
                return _block(msg)

    if tool == "Bash":
        command = tool_input.get("command", "") or ""
        if command:
            cg = _load("cast_command_guard", "cast-command-guard.py")
            if cg is not None:
                try:
                    blocked, message = cg.safe_is_blocked(command)
                except Exception:
                    blocked, message = False, ""
                if blocked:
                    # Preserve the standalone guard's BLOCK log side effect.
                    try:
                        cg.write_log(
                            os.path.join(os.path.expanduser("~"), ".claude", "logs",
                                         "command-guard.log"),
                            f"BLOCK: {command}",
                        )
                    except Exception:
                        pass
                    return _block(message)

    # 2. EGRESS — record + emit (only reached when nothing hard-blocked; blocked
    #    commands are never off-machine-bound, so no egress record is lost).
    if _is_egress_tool(tool):
        sentinel = _load("cast_egress_sentinel", "cast-egress-sentinel.py")
        if sentinel is not None:
            action = _run_egress(sentinel, data)
            if action is not None:
                _emit_egress(sentinel, action)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
