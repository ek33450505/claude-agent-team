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
import unicodedata
import stat

# Security auto-dispatch helpers
SECURITY_EXTENSIONS = re.compile(r'\.(sh|py)$')
SCRIPTS_PATH_PATTERN = re.compile(r'(scripts/|hooks/)')
SIZE_THRESHOLD = 5


def _in_subagent(data: dict) -> bool:
    """True inside an Agent subagent or a managed/headless run.

    Hook input carries `agent_id` ONLY when the hook fires inside a subagent
    (Claude Code hooks docs); `agent_type` is also set for `--agent` main-thread
    sessions, so it is not used. CLAUDE_SUBPROCESS=1 marks managed/headless runs
    and is NOT set for Agent subagents, so on its own it never detected them.
    """
    return bool(data.get("agent_id")) or os.environ.get("CLAUDE_SUBPROCESS", "0") == "1"


def _read_stdin_json():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _sanitize_text(value, limit: int = 200) -> str:
    """Make attacker-influenced text safe to reflect into model context / a log.

    Drops every control (Cc), format (Cf: bidi overrides, zero-width), surrogate (Cs) and
    line/paragraph-separator (Zl U+2028, Zp U+2029) char, neutralises `[`/`]` to `(`/`)` so
    agent-derived text cannot forge a `[CAST-...]` directive, then caps the length. Non-str input
    renders as ''.
    """
    if not isinstance(value, str):
        return ""
    cleaned = "".join(c for c in value if unicodedata.category(c) not in ("Cc", "Cf", "Cs", "Zl", "Zp"))
    cleaned = cleaned.replace("[", "(").replace("]", ")")
    return cleaned if len(cleaned) <= limit else cleaned[:limit] + "..."


_AGENT_NAME_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")


def _safe_agent_name(value) -> str:
    """A plain agent-name token, else 'unknown' (written to status files, echoed by the reader)."""
    return value if isinstance(value, str) and _AGENT_NAME_RE.fullmatch(value) else "unknown"


def _project_root(data: dict) -> str:
    """The session's project root: CLAUDE_PROJECT_DIR, else the payload cwd; '' when unknown."""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ""
    return root if isinstance(root, str) and root.startswith("/") else ""


def _inside_project(data: dict, file_path: str) -> bool:
    """False when the session's project root is known and file_path resolves OUTSIDE it.

    A scratch file in /tmp or another repo must not trigger this session's review chain. With no
    known root the legacy behaviour (fire) is kept.
    """
    root = _project_root(data)
    if not root or not isinstance(file_path, str) or not file_path:
        return True
    try:
        real = os.path.realpath(os.path.join(root, file_path))
        base = os.path.realpath(root).rstrip("/")
    except Exception:
        return True
    return real == base or real.startswith(base + "/")


def _log_debug(msg: str) -> None:
    """One-line record to ~/.claude/logs/hook-debug.log (no behaviour change). Never raises."""
    try:
        import datetime as _dt
        log_path = os.path.expanduser("~/.claude/logs/hook-debug.log")
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(f"[{ts}] DEBUG cast-post-tool.py: {_sanitize_text(msg, 700)}\n")
    except Exception:
        pass


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

    # Review Gate: the dispatching session runs code-reviewer / security. A
    # subagent structurally cannot, so never instruct one to (it burns turns).
    if _in_subagent(data):
        return

    # Only files inside this session's project warrant its review chain (not /tmp scratch files).
    if not _inside_project(data, file_path):
        _log_debug(f"part1 directive suppressed: {_sanitize_text(file_path, 300)} is outside project root "
                   f"{_sanitize_text(_project_root(data), 300)}")
        return

    is_code_file = bool(re.search(r'\.(js|jsx|ts|tsx|sh|py|mjs|cjs)$', file_path))
    is_md_file = file_path.endswith(".md")
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
            "dispatch in sequence: (1) `code-reviewer` — review all changes in this unit. "
            "(2) `test-writer` if logic was added. "
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


_PLAN_READ_CAP = 256 * 1024


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
        # Bounded read: a plan can be arbitrarily large (or a FIFO/huge file); the manifest marker is
        # looked for in the first _PLAN_READ_CAP bytes only.
        with open(real_path, errors="replace") as f:
            contents = f.read(_PLAN_READ_CAP)
    except Exception:
        return

    if "```json dispatch" in contents:
        msg = (
            f"[CAST-ORCHESTRATE] Plan file at {_sanitize_text(real_path, 300)} contains an Agent Dispatch Manifest. "
            "Invoke the `/orchestrate` skill with this plan file path. "
            "Present the queue to the user for approval before executing any batches."
        )
        _hook_output(msg)


_ROUTING_LOG_MAX_BYTES = 5 * 1024 * 1024


def _rotate_routing_log(log_path: str) -> None:
    """Rotate live -> .1 (after .1 -> .2). Refuses a symlinked LIVE log; a symlink planted at
    .1/.2 is unlinked (the link itself, never its target) so rotation still bounds growth."""
    old1, old2 = log_path + ".1", log_path + ".2"
    if os.path.islink(log_path):
        return
    for p in (old1, old2):
        if os.path.islink(p):
            os.unlink(p)
    if os.path.exists(old1):
        os.replace(old1, old2)
    os.replace(log_path, old1)


def _append_routing_log(entry: dict) -> None:
    """Atomic append to routing-log.jsonl with file lock and rotation guard."""
    log_path = os.path.expanduser("~/.claude/routing-log.jsonl")
    line = json.dumps(entry)
    try:
        # O_NOFOLLOW: a symlink planted at the log path is refused (ELOOP -> dropped), never followed.
        # O_NONBLOCK: opening a FIFO planted at the log path must not hang the hook (ENXIO without a
        # reader -> dropped); a non-regular file that DID open is skipped below.
        fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            return
        with os.fdopen(fd, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(line + "\n")
            f.flush()
            try:
                if os.fstat(f.fileno()).st_size > _ROUTING_LOG_MAX_BYTES:
                    _rotate_routing_log(log_path)
            except Exception:
                pass
            # lock released on close
    except Exception:
        pass


# In-process cast-redact.py (same module cast_subagent_stop.py uses for response excerpts).
_REDACT_MOD = None  # None=unattempted, False=import failed, module=loaded


def _get_redact_module():
    global _REDACT_MOD
    if _REDACT_MOD is not None:
        return _REDACT_MOD or None
    try:
        import importlib.util as _ilu
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cast-redact.py")
        spec = _ilu.spec_from_file_location("cast_redact", path)
        if spec and spec.loader:
            mod = _ilu.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _REDACT_MOD = mod
            return mod
    except Exception:
        pass
    _REDACT_MOD = False
    return None


def _redacted_preview(prompt) -> str:
    """80-char single-line preview of a dispatch prompt with secrets/PII redacted.

    Redaction runs on a larger head first so a secret straddling the 80-char cut is still matched.
    Fail closed: if redaction is unavailable or errors, no preview is logged.
    """
    if not isinstance(prompt, str) or not prompt:
        return ""
    # Sanitize FIRST: a zero-width/format char inside a token would otherwise split it so the regexes
    # miss it, and it would then be stripped AFTER redaction, re-forming the secret in the log.
    head = _sanitize_text(re.sub(r"[\r\n\t]", " ", prompt[:512]), 512)
    mod = _get_redact_module()
    if mod is None:
        return "[redaction unavailable]"
    try:
        head = mod.redact_regex(head, mod.analyze_regex(head, []), "redact")
    except Exception:
        return "[redaction unavailable]"
    return _sanitize_text(head, 80)


def part3_agent_logging(data: dict) -> None:
    """Log agent dispatch to routing-log.jsonl and write status file."""
    import datetime

    ti = data.get("tool_input", {})
    subagent_type = _safe_agent_name(ti.get("subagent_type", ti.get("agent_type", "unknown")))
    prompt = ti.get("prompt", ti.get("task", ""))
    prompt_preview = _redacted_preview(prompt)

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

    status_data = {
        "agent": "dispatcher",
        "status": "DONE",
        "summary": f"Agent dispatched: {subagent_type}",
        "chain_dispatched": [subagent_type],
        "session_id": session_id,
        "timestamp": timestamp
    }
    try:
        # Unpredictable name + O_EXCL|O_NOFOLLOW + 0600: a pre-planted file or symlink at the path is
        # never opened/followed (the old predictable name + open(..., "w") followed symlinks).
        # The reader picks the latest file by sorted name, so the timestamp prefix is kept.
        last_err = None
        for _ in range(5):
            status_file = os.path.join(status_dir, f"chain-dispatch-{ts_compact}-{os.urandom(4).hex()}.json")
            try:
                fd = os.open(status_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except FileExistsError as e:
                last_err = e
                continue
            with os.fdopen(fd, "w") as f:
                json.dump(status_data, f, indent=2)
            last_err = None
            break
        if last_err is not None:
            raise last_err
    except Exception as e:
        print(f"ERROR: status file write failed: {e}", file=sys.stderr)
        sys.exit(1)


def part4_bash_debug(data: dict) -> None:
    """Emit [CAST-DEBUG] directive for non-zero Bash exits (main session only)."""
    if _in_subagent(data):
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


def _prov_head_before(tool_use_id):
    """head_before from the git guard's COMMIT_HATCH_USED audit line for this tool_use_id.

    Reads at most the last 256 KiB of ~/.claude/logs/audit.jsonl, scanning backwards.
    Returns (head_before_sha, event_epoch) or None (any problem, including an
    unparseable timestamp → None)."""
    try:
        if not isinstance(tool_use_id, str) or not re.fullmatch(r'[A-Za-z0-9._:-]{1,128}', tool_use_id):
            return None
        path = os.path.expanduser("~/.claude/logs/audit.jsonl")
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            start = max(0, size - 262144)
            f.seek(start)
            raw = f.read()
        lines = raw.split(b"\n")
        if start > 0:
            lines = lines[1:]  # partial first line
        for line in reversed(lines):
            if b"COMMIT_HATCH_USED" not in line:
                continue
            try:
                obj = json.loads(line.decode("utf-8", "replace"))
            except ValueError:
                continue
            if not isinstance(obj, dict) or obj.get("tool_use_id") != tool_use_id:
                continue
            hb = obj.get("head_before")
            ts = obj.get("timestamp")
            if not (isinstance(hb, str) and re.fullmatch(r'[0-9a-f]{40}([0-9a-f]{24})?', hb)):
                return None
            if not (isinstance(ts, str) and re.fullmatch(
                    r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z', ts)):
                return None
            import calendar
            import time as _t
            epoch = calendar.timegm(_t.strptime(ts.split(".")[0].rstrip("Z"), "%Y-%m-%dT%H:%M:%S"))
            return hb, epoch
    except Exception:
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
        head = _git("rev-parse", "HEAD")
        if not repo or not re.match(r'^[0-9a-f]{40,64}$', head):
            return

        # core.worktree (repo-controlled config) can make --show-toplevel report an
        # arbitrary directory. Trust it only if the payload cwd is that toplevel or
        # inside it; otherwise the recorded `repo` would be a path the agent chose.
        real_top = os.path.realpath(repo)
        if os.path.commonpath([os.path.realpath(cwd), real_top]) != real_top:
            return

        # Range mode: the guard's COMMIT_HATCH_USED audit line (same tool_use_id) carries
        # HEAD-before, so every commit this call created gets a row. Any failure → None
        # → today's HEAD-only path with its age checks.
        shas = [head]
        hb_info = _prov_head_before(data.get("tool_use_id"))
        head_before, event_epoch = hb_info if hb_info else (None, None)
        use_range = False
        if head_before:
            try:
                out = _git("rev-list", "--max-count=51", f"{head_before}..HEAD")
            except Exception:
                out = None  # call failed → HEAD-only fallback
            rng = [x for x in (out or "").split() if re.fullmatch(r'[0-9a-f]{40}([0-9a-f]{24})?', x)]
            if 0 < len(rng) <= 50:
                shas, use_range = rng, True
            elif out is not None and not out.strip() and head == head_before:
                return  # empty range and HEAD unmoved: nothing was committed
            # else (rev-list failed, e.g. unknown head_before, or >50 commits):
            # HEAD-only path with its age checks.

        # Bound the read: a repo-controlled commit object can be arbitrarily large, so
        # check its size (no object body is read) before pulling it into memory. A
        # missing object fails here (rc != 0 → "") and records nothing.
        def _ok_commit(sha):
            size = _git("cat-file", "-s", sha)
            if not re.fullmatch(r'[0-9]{1,9}', size) or int(size) > _PROV_MAX_COMMIT_BYTES:
                return False
            commit_ts = _committer_epoch(_git("cat-file", "commit", sha))
            if commit_ts is None:
                return False
            if use_range:
                # Range mode: keep only commits CREATED by this call. Commits merely
                # brought in (ff-merge / pull) keep their old committer time and drop
                # out; 5 s slack for skew between the audit line and the commit.
                return commit_ts >= event_epoch - 5
            # A hatch `git commit … || true` / "nothing to commit" leaves an OLD
            # HEAD in place — never record that as this call's commit.
            age = time.time() - commit_ts
            return _PROV_MIN_HEAD_AGE_S <= age <= _PROV_MAX_HEAD_AGE_S

        shas = [x for x in shas if _ok_commit(x)]
        if not shas:
            return

        branch = _git("rev-parse", "--abbrev-ref", "HEAD")
        session_id = data.get("session_id") or ""
        if not isinstance(session_id, str):
            session_id = ""
        at = data.get("agent_type")
        agent = at if isinstance(at, str) and re.fullmatch(r'[A-Za-z0-9._:@/-]{1,64}', at) else "main-session"
        recorded_at = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        from cast_db import db_execute
        for sha in shas:
            # UPSERT: ONLY the git post-commit hook's 'unattributed' row is upgraded to
            # the payload identity; any other label is kept. recorded_at/repo are left
            # alone (reconcile window).
            ok = db_execute(
                "INSERT INTO commit_provenance (sha, session_id, agent, branch, repo, recorded_at)"
                " VALUES (?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(sha) DO UPDATE SET agent = excluded.agent,"
                " session_id = CASE WHEN excluded.session_id != '' THEN excluded.session_id"
                " ELSE commit_provenance.session_id END"
                " WHERE commit_provenance.agent = 'unattributed'",
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
