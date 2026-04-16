#!/usr/bin/env python3
"""cast-post-tool.py — Single-process PostToolUse handler.

Reads stdin JSON once and performs all post-tool-hook logic:
  Part 1: Emit [CAST-CHAIN] / [CAST-REVIEW] directive (Write/Edit)
  Part 2: Detect Agent Dispatch Manifests in .md plan files (Write on plans/)
  Part 3: Agent dispatch logging to routing-log.jsonl + status file
  Part 4: Bash non-zero exit → [CAST-DEBUG] directive

Replaces ~10 inline `python3 -c` / `python3 -` calls in post-tool-hook.sh.
Uses stdlib only. No subprocess spawns.
"""
import sys
import json
import os
import re
import fcntl


def _read_stdin_json():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _hook_output(msg: str) -> None:
    """Print a hookSpecificOutput JSON blob to stdout."""
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": msg
        }
    }))


def part1_directive(data: dict, tool_name: str, file_path: str) -> None:
    """Emit [CAST-CHAIN] / [CAST-REVIEW] directive for Write/Edit."""
    if tool_name not in ("Write", "Edit"):
        return

    is_code_file = bool(re.search(r'\.(js|jsx|ts|tsx|sh|py|mjs|cjs)$', file_path))
    is_subprocess = os.environ.get("CLAUDE_SUBPROCESS", "0") == "1"

    if not is_subprocess:
        if is_code_file:
            msg = (
                "[CAST-CHAIN] Code file modified. MANDATORY: After completing your current logical unit, "
                "dispatch in sequence: (1) `code-reviewer` (haiku) — review all changes in this unit. "
                "(2) `test-writer` (sonnet) if logic was added. "
                "Do NOT proceed to next unit or commit until code-reviewer returns Status: DONE or DONE_WITH_CONCERNS. "
                "Skipping is a protocol violation."
            )
            _hook_output(msg)
        else:
            _hook_output(
                "[CAST-REVIEW] Non-code file modified. Dispatch `code-reviewer` if the change is significant."
            )
    else:
        # Subagent context
        if is_code_file:
            depth_file = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"cast-depth-{os.getppid()}.depth")
            subagent_depth = 1
            try:
                with open(depth_file) as f:
                    subagent_depth = int(f.read().strip())
            except Exception:
                pass

            if subagent_depth >= 2:
                msg = (
                    "DEEP NESTING WARNING: [CAST-REVIEW] Code modified in subagent context. "
                    "Per your agent instructions, dispatch `code-reviewer` after this logical unit completes. "
                    "If Agent tool dispatch fails at this depth, the inline session must re-dispatch code-reviewer as fallback."
                )
            else:
                msg = (
                    "[CAST-REVIEW] Code modified in subagent context. "
                    "Per your agent instructions, dispatch `code-reviewer` after this logical unit completes."
                )
            _hook_output(msg)


def part2_plan_manifest(tool_name: str, file_path: str) -> None:
    """Detect Agent Dispatch Manifests in .md plan files."""
    if not (tool_name == "Write" and "/plans/" in file_path and file_path.endswith(".md")):
        return

    try:
        real_path = os.path.realpath(file_path)
    except Exception:
        return

    home = os.path.expanduser("~")
    if not real_path.startswith(home + "/"):
        return

    try:
        with open(real_path) as f:
            contents = f.read()
    except Exception:
        return

    if "```json dispatch" in contents:
        msg = (
            f"[CAST-ORCHESTRATE] Plan file at {real_path} contains an Agent Dispatch Manifest. "
            "Dispatch the `orchestrator` agent via the Agent tool with this plan file path. "
            "Present the queue to the user for approval before executing any batches."
        )
        _hook_output(msg)


def _append_routing_log(entry: dict) -> None:
    """Atomic append to routing-log.jsonl with file lock and rotation guard."""
    log_path = os.path.expanduser("~/.claude/routing-log.jsonl")
    line = json.dumps(entry)
    try:
        with open(log_path, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(line + "\n")
            f.flush()
            try:
                if os.path.getsize(log_path) > 5 * 1024 * 1024:
                    old2 = log_path + ".2"
                    old1 = log_path + ".1"
                    if os.path.exists(old2):
                        os.remove(old2)
                    if os.path.exists(old1):
                        os.rename(old1, old2)
            except Exception:
                pass
            # lock released on close
    except Exception:
        pass


def part3_agent_logging(data: dict) -> None:
    """Log agent dispatch to routing-log.jsonl and write status file."""
    import datetime

    ti = data.get("tool_input", {})
    subagent_type = ti.get("subagent_type", ti.get("agent_type", "unknown"))
    prompt = ti.get("prompt", ti.get("task", ""))
    prompt_preview = prompt[:80].replace("\n", " ")

    session_id = os.environ.get("CLAUDE_SESSION_ID", "unknown")
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Append to routing-log.jsonl (inline — replaces cast-log-append.py subprocess)
    entry = {
        "timestamp": timestamp,
        "session_id": session_id,
        "action": "agent_dispatched",
        "matched_route": subagent_type,
        "prompt_preview": prompt_preview,
        "confidence": "direct"
    }
    _append_routing_log(entry)

    # Write chain_dispatched status file
    status_dir = os.path.expanduser("~/.claude/agent-status")
    os.makedirs(status_dir, exist_ok=True)
    ts_compact = timestamp.replace(":", "").replace("-", "")[:15] + "Z"
    status_file = os.path.join(status_dir, f"chain-dispatch-{ts_compact}.json")

    status_data = {
        "agent": "dispatcher",
        "status": "DONE",
        "summary": f"Agent dispatched: {subagent_type}",
        "chain_dispatched": [subagent_type],
        "session_id": session_id,
        "timestamp": timestamp
    }
    try:
        with open(status_file, "w") as f:
            json.dump(status_data, f, indent=2)
    except Exception as e:
        print(f"ERROR: status file write failed: {e}", file=sys.stderr)
        sys.exit(1)


def part4_bash_debug(data: dict) -> None:
    """Emit [CAST-DEBUG] directive for non-zero Bash exits (main session only)."""
    if os.environ.get("CLAUDE_SUBPROCESS", "0") == "1":
        return

    tool_input = data.get("tool_input", {})
    tool_response = data.get("tool_response", {})
    command = tool_input.get("command", "")

    exit_code = tool_response.get("exit_code", None)

    if exit_code is None:
        output = str(tool_response.get("output", ""))
        m = re.search(r"[Ee]xit\s+(?:code[:\s]+)?(\d+)", output)
        if m:
            exit_code = int(m.group(1))
        elif tool_response.get("error"):
            exit_code = 1
        else:
            return  # No indication of non-zero exit — suppress

    exit_code = int(exit_code)
    if exit_code == 0:
        return

    # Grace list: suppress CAST-DEBUG for known benign non-zero exits
    cmd = command.strip()
    if exit_code == 1:
        if cmd.startswith("grep") or cmd.startswith("rg"):
            return  # grep/rg returning 1 = no match, not an error
        if cmd.startswith("git diff"):
            return  # git diff exit 1 = differences found, not an error
        if cmd.startswith("git log"):
            return  # git log with empty output

    directive = (
        f"[CAST-DEBUG] Bash command exited with code {exit_code}. "
        "Per CAST protocol, route this failure to the `debugger` agent via the Agent tool. "
        "Do NOT inline-triage beyond one tool call. Pass the failed command and its output as context."
    )
    _hook_output(directive)


def main():
    data = _read_stdin_json()
    tool_name = data.get("tool_name", "")
    file_path = data.get("tool_input", {}).get("file_path", "")

    if tool_name in ("Write", "Edit"):
        part1_directive(data, tool_name, file_path)
        part2_plan_manifest(tool_name, file_path)

    if tool_name == "Agent":
        part3_agent_logging(data)

    if tool_name == "Bash":
        part4_bash_debug(data)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never crash the hook pipeline
        sys.exit(0)
