#!/usr/bin/env python3
"""cast-post-tool.py — Single-process PostToolUse handler.

Reads stdin JSON once and performs all post-tool-hook logic:
  Part 1: Emit [CAST-CHAIN] / [CAST-REVIEW] directive (Write/Edit)
  Part 2: Detect Agent Dispatch Manifests in .md plan files (Write on plans/)
  Part 3: Agent dispatch logging to routing-log.jsonl + status file
  Part 4: Bash non-zero exit → [CAST-DEBUG] directive
  Part 5: Bash hatch commit (CAST_COMMIT_AGENT=1) → commit_provenance row

Replaces ~10 inline `python3 -c` / `python3 -` calls in post-tool-hook.sh.
Uses stdlib only. No subprocess spawns, except Part 5, which runs `git` only
after its substring precheck + hatch predicate pass (hatch commits only).
"""
import sys
import json
import os
import re
import fcntl

# Security auto-dispatch helpers
SECURITY_EXTENSIONS = re.compile(r'\.(sh|py)$')
SCRIPTS_PATH_PATTERN = re.compile(r'(scripts/|hooks/)')
SIZE_THRESHOLD = 5


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
    is_md_file = file_path.endswith(".md")
    is_subprocess = os.environ.get("CLAUDE_SUBPROCESS", "0") == "1"
    is_orchestrate_active = os.environ.get("CAST_ORCHESTRATE_ACTIVE", "0") == "1"

    # Security chain: fire on shell/Python writes in scripts/ or hooks/ with >= 5 lines.
    # Security is NOT suppressed by orchestrate context — it's a real escalation, not noise.
    is_security_target = (
        bool(SECURITY_EXTENSIONS.search(file_path)) and
        bool(SCRIPTS_PATH_PATTERN.search(file_path))
    )
    new_content = (
        data.get("input", {}).get("content", "") or
        data.get("input", {}).get("new_string", "") or
        data.get("tool_input", {}).get("content", "") or
        data.get("tool_input", {}).get("new_string", "")
    )
    lines_changed = len([l for l in new_content.split('\n') if l.strip()])

    if not is_subprocess:
        # In orchestrate sessions: suppress CAST-CHAIN and CAST-REVIEW (they're noise),
        # but always keep the security chain (real escalation, not hook chatter).
        if is_orchestrate_active:
            if is_security_target and lines_changed >= SIZE_THRESHOLD:
                _hook_output(
                    "[CAST-CHAIN: security] Shell/Python script in scripts/ or hooks/ modified with "
                    f"{lines_changed} lines. MANDATORY: dispatch `security` agent after "
                    "code-reviewer completes. Security agent must scan for SQL injection, "
                    "env var interpolation into sqlite3, and shell injection before commit."
                )
            return

        # .md files are plan/docs, not code — CAST-REVIEW is not relevant.
        if is_md_file:
            return

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

        if is_security_target and lines_changed >= SIZE_THRESHOLD:
            _hook_output(
                "[CAST-CHAIN: security] Shell/Python script in scripts/ or hooks/ modified with "
                f"{lines_changed} lines. MANDATORY: dispatch `security` agent after "
                "code-reviewer completes. Security agent must scan for SQL injection, "
                "env var interpolation into sqlite3, and shell injection before commit."
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
            "Invoke the `/orchestrate` skill with this plan file path. "
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


# Part 5 — D5 commit provenance, recorded from the hook.
#
# Why here: inside Claude Code's Bash sandbox ~/.claude/cast.db is read-only, so
# the Bash children that normally write the commit_provenance row (commit agent
# step 8 → cast-commit-provenance.py; .githooks/post-commit) fail with "attempt
# to write a readonly database" while the COMMIT_HATCH_USED audit event (written
# by the PreToolUse hook, outside the sandbox) still lands — leaving every
# sandboxed commit with an event and no row, which cast-commit-reconcile.py
# blocks at push. PostToolUse hooks run outside the sandbox. Those two writers
# stay as fallbacks. The write is write-once (INSERT OR IGNORE): a row already
# written by one of them is never relabelled by this hook — recorder identity is
# a parked follow-up (an upsert would let a no-op hatch call within the 120 s
# window relabel another actor's row).
#
# SECURITY: this runs OUTSIDE the sandbox on a payload-supplied `cwd` — a repo the
# agent controls. So git is run plumbing-only (rev-parse / cat-file: no `log`,
# `show`, `diff`, `status`, which can spawn a configured gpg.program, textconv,
# pager or fsmonitor) with config that could exec neutralised, and the repo's own
# claim about its toplevel is distrusted (core.worktree) — see part5 below.
_PROV_MAX_HEAD_AGE_S = 120   # record only a HEAD committed this recently
_PROV_MIN_HEAD_AGE_S = -60   # tolerate small clock skew; reject far-future HEADs
_PROV_GIT_BUDGET_S = 4.0     # ONE shared deadline across every git call (hook timeout is 10 s)
_PROV_GIT_MIN_CALL_S = 0.5   # floor for a call's share once the budget is nearly spent
_PROV_MAX_COMMIT_BYTES = 1 << 20   # refuse to read a commit object larger than 1 MiB
_PROV_GIT_HARDEN = ["--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false"]


def _log_hook_error(where: str, exc) -> None:
    """Append one line to ~/.claude/logs/hook-errors.log. Never raises."""
    try:
        import datetime as _dt
        log_path = os.path.expanduser("~/.claude/logs/hook-errors.log")
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        ts = _dt.datetime.now(_dt.timezone.utc).isoformat().replace('+00:00', 'Z')
        with open(log_path, 'a') as f:
            f.write(f'[{ts}] ERROR cast-post-tool.py {where}: {exc}\n')
    except Exception:
        pass


def _load_git_guard():
    """Load the hyphen-named sibling cast-git-guard.py as a module.

    Same importlib pattern as cast-pretool-dispatch.py:_load(). The guard's
    hatch predicate is inlined in _git_evaluate_impl (not a callable), so
    _is_hatch_commit() below reuses its three ingredients — _scannable_segments,
    _normalize_git_segment, _COMMIT_ALLOW — rather than re-implementing the
    hatch regex, so the COMMIT_HATCH_USED event and the provenance row cannot
    disagree about what counts as a hatch commit."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cast-git-guard.py")
    spec = importlib.util.spec_from_file_location("cast_git_guard_posttool", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _has_dry_flag(seg: str) -> bool:
    """True if any argv token of `seg` starts with `--dry`. git accepts unique
    option prefixes, so `--dry` / `--dry-r` are dry runs just like `--dry-run`."""
    import shlex
    try:
        tokens = shlex.split(seg)
    except ValueError:
        tokens = seg.split()
    return any(t.startswith("--dry") for t in tokens)


def _is_hatch_commit(guard, command: str) -> bool:
    """True if any shell segment of `command` is a hatch `git commit` that is not a dry run.

    Mirrors the guard's per-segment `hit(_COMMIT_ALLOW)` check (raw segment and
    its normalized form). A dry run (any `--dry*` token) is excluded here (the
    guard still audits it as a hatch use): it creates no commit, and a row for
    whatever HEAD happens to be fresh would be a false attribution."""
    for seg in guard._scannable_segments(command):
        seg = seg.strip()
        if not seg:
            continue
        norm = guard._normalize_git_segment(seg)
        variants = (seg, norm) if norm else (seg,)
        if any(guard._COMMIT_ALLOW.search(v) for v in variants) and not _has_dry_flag(seg):
            return True
    return False


def _committer_epoch(commit_text: str):
    """Committer unix time from raw `git cat-file commit` output, or None.

    Parses the `committer <name> <email> <epoch> <tz>` header ourselves, from the
    header block only (before the first blank line) so a commit message can't
    spoof it. Plumbing replaces `git log --format=%ct`, which runs a configured
    gpg.program when log.showSignature=true and HEAD carries a gpgsig header."""
    header = commit_text.split("\n\n", 1)[0]
    for line in header.split("\n"):
        if line.startswith("committer "):
            parts = line.rsplit(" ", 2)
            if len(parts) == 3 and re.fullmatch(r'[0-9]+', parts[1]):
                return int(parts[1])
            return None
    return None


def part5_commit_provenance(data: dict) -> None:
    """Record a commit_provenance row for a successful hatch commit. Fail-open, silent."""
    try:
        command = (data.get("tool_input") or {}).get("command") or ""
        # Cheap precheck: the hot path (every Bash call) pays two substring tests.
        if not isinstance(command, str) or "CAST_COMMIT_AGENT=1" not in command or "commit" not in command:
            return

        # PostToolUse only fires for a successful call (failures go to
        # PostToolUseFailure); this is defence in depth for payloads that
        # still carry a failure marker.
        resp = data.get("tool_response")
        if isinstance(resp, dict):
            ec = resp.get("exit_code")
            if (ec is not None and str(ec) != "0") or resp.get("interrupted") \
                    or resp.get("is_error") or resp.get("error"):
                return

        if not _is_hatch_commit(_load_git_guard(), command):
            return

        cwd = data.get("cwd") or os.getcwd()
        if not isinstance(cwd, str) or not os.path.isdir(cwd):
            return

        import datetime as _dt
        import subprocess
        import time

        # One shared deadline for ALL git calls (each gets the remaining budget,
        # floored at _PROV_GIT_MIN_CALL_S); a timeout raises → swallowed → no row.
        deadline = time.monotonic() + _PROV_GIT_BUDGET_S
        # GIT_NO_LAZY_FETCH + GIT_ALLOW_PROTOCOL=none: reading an object that is MISSING in
        # a partial-clone repo (extensions.partialClone / remote.<n>.promisor — both
        # repo-controlled) triggers a lazy fetch that would run the repo's
        # remote.<n>.uploadpack, core.sshCommand, core.gitProxy or an ext:: transport —
        # code exec outside the sandbox. Either variable alone blocks all four (probed on
        # git 2.56.0); both = defence in depth, and GIT_ALLOW_PROTOCOL still covers git
        # versions that predate GIT_NO_LAZY_FETCH (which they would simply ignore).
        env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0",
                   GIT_NO_LAZY_FETCH="1", GIT_ALLOW_PROTOCOL="none")

        def _git(*args):
            budget = max(_PROV_GIT_MIN_CALL_S, deadline - time.monotonic())
            r = subprocess.run(["git"] + _PROV_GIT_HARDEN + ["-C", cwd] + list(args),
                               stdin=subprocess.DEVNULL, capture_output=True,
                               env=env, timeout=budget)
            return r.stdout.decode("utf-8", "replace").strip() if r.returncode == 0 else ""

        repo = _git("rev-parse", "--show-toplevel")
        sha = _git("rev-parse", "HEAD")
        if not repo or not re.match(r'^[0-9a-f]{40,64}$', sha):
            return

        # core.worktree (repo-controlled config) can make --show-toplevel report an
        # arbitrary directory. Trust it only if the payload cwd is that toplevel or
        # inside it; otherwise the recorded `repo` would be a path the agent chose.
        real_top = os.path.realpath(repo)
        if os.path.commonpath([os.path.realpath(cwd), real_top]) != real_top:
            return

        # Bound the read: a repo-controlled commit object can be arbitrarily large, so
        # check its size (no object body is read) before pulling it into memory. A
        # missing object fails here (rc != 0 → "") and records nothing.
        size = _git("cat-file", "-s", sha)
        if not re.fullmatch(r'[0-9]{1,9}', size) or int(size) > _PROV_MAX_COMMIT_BYTES:
            return
        commit_ts = _committer_epoch(_git("cat-file", "commit", sha))
        if commit_ts is None:
            return

        # A hatch `git commit … || true` / "nothing to commit" leaves an OLD
        # HEAD in place — never record that as this call's commit.
        age = time.time() - commit_ts
        if age > _PROV_MAX_HEAD_AGE_S or age < _PROV_MIN_HEAD_AGE_S:
            return

        branch = _git("rev-parse", "--abbrev-ref", "HEAD")
        session_id = data.get("session_id") or ""
        agent = data.get("agent_type") or "main-session"
        recorded_at = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        from cast_db import db_execute
        ok = db_execute(
            "INSERT OR IGNORE INTO commit_provenance (sha, session_id, agent, branch, repo, recorded_at)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (sha, session_id, agent, branch, repo, recorded_at),
        )
        if not ok:
            _log_hook_error("part5_commit_provenance", f"db_execute returned False for {sha}")
    except Exception as e:
        _log_hook_error("part5_commit_provenance", e)


def part6_file_writes(data: dict, tool_name: str, file_path: str) -> None:
    """Record file writes to file_writes table for IDE gutter annotations."""
    if tool_name not in ("Write", "Edit", "MultiEdit"):
        return
    if not file_path:
        return

    try:
        from cast_db import db_write, db_execute, db_query
        # Ensure the table exists (idempotent — safe on every call)
        db_execute(
            "CREATE TABLE IF NOT EXISTS file_writes ("
            "  id         INTEGER PRIMARY KEY AUTOINCREMENT,"
            "  session_id TEXT,"
            "  agent_name TEXT,"
            "  run_id     INTEGER,"
            "  file_path  TEXT NOT NULL,"
            "  tool_name  TEXT NOT NULL,"
            "  ts         TEXT NOT NULL DEFAULT (datetime('now')),"
            "  line_range TEXT"
            ")"
        )
        db_execute(
            "CREATE INDEX IF NOT EXISTS idx_file_writes_path "
            "ON file_writes(file_path)"
        )
        db_execute(
            "CREATE INDEX IF NOT EXISTS idx_file_writes_session_ts "
            "ON file_writes(session_id, ts)"
        )
        db_execute(
            "CREATE INDEX IF NOT EXISTS idx_file_writes_run "
            "ON file_writes(run_id)"
        )

        try:
            real = os.path.realpath(file_path)
        except Exception:
            real = file_path

        sid = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID")
        run_id = os.environ.get("CAST_AGENT_RUN_ID")
        agent = os.environ.get("CAST_AGENT_NAME")

        # DB fallback: attribute only when exactly one agent is running in this session —
        # misattribution is worse than NULL (concurrent agents → leave run_id NULL, never guess).
        if not run_id and sid:
            try:
                _rows = db_query(
                    "SELECT id, agent FROM agent_runs WHERE session_id = ? AND status = 'running'",
                    (sid,)
                )
                if len(_rows) == 1:
                    run_id = str(_rows[0][0])
                    if not agent:
                        agent = _rows[0][1]
            except Exception:
                pass

        db_write('file_writes', {
            'session_id': sid,
            'agent_name': agent,
            'run_id': run_id,
            'file_path': real,
            'tool_name': tool_name,
        })
    except Exception as e:
        try:
            import datetime as _dt
            log_path = os.path.expanduser("~/.claude/logs/hook-errors.log")
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            ts = _dt.datetime.now(_dt.timezone.utc).isoformat().replace('+00:00', 'Z')
            with open(log_path, 'a') as f:
                f.write(f'[{ts}] ERROR cast-post-tool.py part6_file_writes: {e}\n')
        except Exception:
            pass


def main():
    data = _read_stdin_json()
    tool_name = data.get("tool_name", "")
    file_path = data.get("tool_input", {}).get("file_path", "")

    if tool_name in ("Write", "Edit", "MultiEdit"):
        part6_file_writes(data, tool_name, file_path)

    if tool_name in ("Write", "Edit"):
        part1_directive(data, tool_name, file_path)
        part2_plan_manifest(tool_name, file_path)

    if tool_name == "Agent":
        part3_agent_logging(data)

    if tool_name == "Bash":
        # Part 5 first and self-contained: a part4 parse quirk must not drop the row.
        part5_commit_provenance(data)
        part4_bash_debug(data)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never crash the hook pipeline
        sys.exit(0)
