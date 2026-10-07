#!/bin/bash
# cast-session-start-health.sh — SessionStart health surface
# Surfaces three silent failures at every session start (read-only, zero agent cost):
#   (a) auto-memories with stale verified_at (>30 days) AND naming a concrete path/fn/flag
#   (b) com.cast.* launchd jobs with non-zero last-exit-status
#   (c) PreToolUse guard modules that failed to load (cast.db hook_failures rows named
#       cast-pretool-dispatch/<module>, last 7 days) — the guard was DISABLED for those calls
#       Runs in a child process with a hard timeout (<=2s, shrinking with elapsed hook time), so
#       a hostile/slow cast.db can never hang the hook or drop checks (a)/(b). A missing DB or no
#       hook_failures object is skipped quietly; anything else unreadable (locked, corrupt, a VIEW,
#       timeout) shows a degraded notice. Module names are an allowlist (the child emits indexes,
#       never DB text); all other rows fold into one "unrecognised module" line.
#   (d) install integrity: scripts/cast-install-integrity.py verifies ~/.claude/install-manifest.sha256
#       (sha256 of every deployed script/githook + config/policies.json, the githooks dir, and the
#       CAST repo's core.hooksPath). Git hooks run from ~/.claude/githooks; if it vanishes git runs NO
#       hooks, silently. Any mismatch is a loud alarm; a missing manifest (pre-manifest install) is an
#       advisory. Child process, budgeted timeout; its text is sanitised before it reaches the banner
#       (a filename or .git/config value is attacker-influenced). Checker missing/failed = degraded notice.
#
# Emits ONE JSON object (systemMessage + hookSpecificOutput) only when something needs attention.
# Exits 0 always — never blocks a session.
#
# Escape hatch: CAST_HEALTH_LAUNCHCTL_CMD overrides the launchctl binary (for testing).
# CAST_DB_PATH overrides the cast.db location for check (c) (opened read-only).

if [ "${CLAUDE_SUBPROCESS:-0}" = "1" ]; then exit 0; fi
set -euo pipefail

# _log_error: append a structured error line to hook-errors.log (never fails itself)
_log_error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR $0: $1" >> "${HOME}/.claude/logs/hook-errors.log" 2>/dev/null || true; }
mkdir -p "${HOME}/.claude/logs" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Capture launchctl output via overridable command (enables deterministic testing)
LAUNCHCTL="${CAST_HEALTH_LAUNCHCTL_CMD:-launchctl}"
LAUNCHCTL_OUTPUT="$("$LAUNCHCTL" list 2>/dev/null || true)"

_HEALTH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CAST_HEALTH_SCRIPT_DIR="$_HEALTH_SCRIPT_DIR"
export CAST_INPUT="$INPUT"
export CAST_LAUNCHCTL_OUTPUT="$LAUNCHCTL_OUTPUT"
export CAST_HOME="$HOME"

python3 -I - <<'PYEOF' || _log_error "session-start-health python block failed (exit $?)"
import json, os, re, stat, subprocess, sys, time

_T0 = time.monotonic()  # hook budget: Claude Code kills the hook at 5s
home = os.environ.get("CAST_HOME", os.path.expanduser("~"))
launchctl_out = os.environ.get("CAST_LAUNCHCTL_OUTPUT", "")

# ── Install integrity (d) - runs FIRST ────────────────────────────────────────
# First on purpose: it is the only check whose budget scales its verification coverage (a starved
# checker verifies nothing), so it must get its full budget before the stale-memory scanner (<=2s) and
# the guard-failure check (budget = 4.0s - elapsed, floor 0.5s) spend the hook's 5s. Worst case:
# 2.0s here + 2.0s scanner + 0.5s guard = 4.5s, inside the kill.
# Runs scripts/cast-install-integrity.py --json in a child (same lookup order as the stale-memory
# scanner). Hashing ~190 small files in-process is a few ms, so the full sha256 compare always runs
# (no size/mtime shortcut that a same-size edit could slip past). The child's JSON is re-validated and
# every detail string is reduced to a safe charset + length-capped before it can reach model context.
integ_problems = []     # sanitised detail strings
integ_dropped = 0
integ_advisory = ""     # sanitised advisory text (missing manifest)
integ_error = ""        # fixed-vocabulary label when the check could not complete
integ_skipped = False   # an incremental run that verified NOTHING while caches were pending (no budget)
integ_pending = 0       # bytecode caches not yet verified (incremental run out of budget; resumes next session)
_checker = os.path.join(home, ".claude", "scripts", "cast-install-integrity.py")
if not os.path.isfile(_checker):
    _sib2 = os.path.join(os.environ.get("CAST_HEALTH_SCRIPT_DIR", ""), "cast-install-integrity.py")
    if _sib2 and os.path.isfile(_sib2):
        _checker = _sib2
if not os.path.isfile(_checker):
    _repo2 = os.environ.get("CAST_REPO_DIR", "")
    if _repo2:
        _checker = os.path.join(_repo2, "scripts", "cast-install-integrity.py")


# The model-visible notice carries NO checker-supplied free text (file names, git config values and
# paths are attacker-influenced). Only a fixed phrase per problem KIND, plus - for manifest-listed
# files only - a path that passes a strict allowlist regex; any other name is shown as a short hash.
# Full names live in `cast doctor` output (a terminal, not model context).
_SAFE_REL = re.compile(r"^(scripts|githooks|config)(/[A-Za-z0-9][A-Za-z0-9._-]{0,60}){1,2}$")
_FIXED_PHRASE = {
    "manifest-unreadable": "install manifest is unreadable",
    "manifest-invalid": "install manifest is malformed or truncated",
    "hooks-dir": "~/.claude/githooks is missing or not a real directory - git runs NO hooks",
    "hooks-path": "core.hooksPath of the CAST repo differs from the installed value (or could not be read)",
    "hook-config": "git config defines hook.*.command/event or a worktree hook override - hooks run regardless of core.hooksPath",
    "env": "session environment sets GIT_*/PYTHON* overrides that change which git config, hooks or programs run",
    "pyc-unverified": "a bytecode cache cannot be verified by any installed interpreter - re-run bash install.sh to purge it",
    "checker-error": "the integrity checker failed unexpectedly",
}
_PATH_PHRASE = {"missing": "is missing", "changed": "changed since install",
                "pyc": "compiled cache does not match its source",
                "pyc-stale": "has a stale bytecode cache (python would not load it) - not expected after install; re-run bash install.sh",
                "mode": "has different permissions than installed (git skips a hook without its exec bit)"}
_UNEXPECTED_PARENTS = ("githooks", "scripts", "scripts/migrations", "scripts/__pycache__",
                       "scripts/migrations/__pycache__")


def _h8(value):
    import hashlib
    return hashlib.sha256(str(value).encode("utf-8", "replace")).hexdigest()[:8]


def _render_problem(prob):
    kind = prob.get("kind") if isinstance(prob, dict) else None
    path = prob.get("path") if isinstance(prob, dict) else None
    if kind in _FIXED_PHRASE:
        return _FIXED_PHRASE[kind]
    if kind in _PATH_PHRASE:
        tag = path if (isinstance(path, str) and _SAFE_REL.match(path)) else "an entry <" + _h8(path) + ">"
        return f"{tag} {_PATH_PHRASE[kind]}"
    if kind == "dir-type":
        tag = path if path in ("scripts", "scripts/migrations", "config") else "a managed directory"
        return f"~/.claude/{tag} is a symlink or not a directory"
    if kind == "unexpected":
        parent = os.path.dirname(path) if isinstance(path, str) else ""
        parent = parent if parent in _UNEXPECTED_PARENTS else "a managed directory"
        return f"unlisted entry <{_h8(path)}> in ~/.claude/{parent}/ - run cast doctor for its name"
    return "unrecognised integrity problem"


def _log_integrity_error(label):
    try:
        with open(os.path.join(home, ".claude", "logs", "hook-errors.log"), "a") as lf:
            lf.write(f"ERROR cast-session-start-health install-integrity check: {label}\n")
    except OSError:
        pass


# PYTHONEXECUTABLE overrides sys.executable even under -I (macOS), and every child below is SPAWNED from
# it: a bogus value silently disables the checks and an existing fake file would be EXECUTED by the
# hook. Children therefore run from a TRUSTED interpreter chosen by the checker's own rule
# (_trusted_exes over _PY_CANDIDATES: owned by root or us, directory not world-writable) - the single
# copy of that rule, loaded here by exec of the source (no .pyc is read, so a forged cache of the checker
# cannot run in the hook). The env var itself is reported by the checker's env check. If the checker
# cannot be loaded, sys.executable is left alone: a bogus value then fails loudly (degraded notice).
_CHECKER_MAX = 1 << 20   # the real checker is ~40 KB; anything over 1 MiB is not it
_checker_bad = False     # the checker file is not a plain, small, regular file (or failed to load)
if os.path.isfile(_checker):
    try:
        # Read it like an untrusted file: O_NOFOLLOW (a symlink is refused, never followed), O_NONBLOCK
        # (a FIFO cannot hang the open), fstat must say regular file, and at most cap+1 bytes are read
        # (an oversized file is refused before it can cost time or memory). Any violation or error leaves
        # integ_error set below - the degraded notice - and the file is NEVER executed, here or as a child.
        _cfd = os.open(_checker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(_cfd).st_mode):
                raise ValueError("checker is not a regular file")
            with os.fdopen(_cfd, "rb", closefd=False) as _cf:
                _csrc = _cf.read(_CHECKER_MAX + 1)
        finally:
            os.close(_cfd)
        if len(_csrc) > _CHECKER_MAX:
            raise ValueError("checker over the size cap")
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            _ns = {"__name__": "cast_install_integrity", "__file__": _checker}
            exec(compile(_csrc, _checker, "exec"), _ns)
        _exes = _ns["_trusted_exes"](_ns["_PY_CANDIDATES"])
        _real = os.path.realpath(sys.executable)
        sys.executable = next((e for e in _exes if os.path.realpath(e) == _real), _exes[0] if _exes else sys.executable)
    except Exception:
        _checker_bad = True

if not os.path.isfile(_checker):
    # No manifest AND no checker = a pre-manifest install; with a manifest it is a real gap.
    if os.path.lexists(os.path.join(home, ".claude", "install-manifest.sha256")):
        integ_error = "checker not found"
        _log_integrity_error(integ_error)
    else:
        integ_advisory = "no install integrity manifest - run bash install.sh to create it"
elif _checker_bad:
    integ_error = "checker failed"
    _log_integrity_error(integ_error)
else:
    try:
        _ib = max(0.8, min(2.0, 4.5 - (time.monotonic() - _T0)))
        _ir = subprocess.run(
            [sys.executable, "-I", _checker, "--json", "--home", home, "--incremental",
             "--budget", "%.2f" % max(0.3, _ib - 0.35)],
            capture_output=True, timeout=_ib, stdin=subprocess.DEVNULL,
        )
        if _ir.returncode not in (0, 1) or not _ir.stdout or len(_ir.stdout) > 65536:
            raise ValueError("checker exit/stdout shape")
        _ires = json.loads(_ir.stdout[:65536].decode("utf-8", "replace"))
        _istate = _ires["state"]
        if _istate not in ("ok", "alarm", "advisory") or not isinstance(_ires["problems"], list):
            raise ValueError("checker state")
        integ_pending = max(0, min(100000, int(_ires.get("pending", 0))))
        _icaches = _ires.get("caches")
        integ_skipped = bool(integ_pending) and isinstance(_icaches, dict) and _icaches.get("verified") == 0
        if _istate == "advisory":
            integ_advisory = "no install integrity manifest - run bash install.sh to create it"
        elif _istate == "alarm":
            for _p in _ires["problems"][:20]:
                integ_problems.append(_render_problem(_p))
            integ_dropped = max(0, len(_ires["problems"]) - 20) + max(0, int(_ires.get("dropped", 0)))
            if not integ_problems:
                raise ValueError("alarm without problems")
    except subprocess.TimeoutExpired:
        integ_error = "timeout"
        _log_integrity_error(integ_error)
    except Exception:  # bad JSON / shape / spawn failure: loud, never silent
        integ_error = "checker failed"
        _log_integrity_error(integ_error)

# ── Stale memory detection ────────────────────────────────────────────────────
# Canonical logic lives in cast-stale-memories.py (shared with bin/cast doctor).
# Output format: line 1 = count, lines 2+ = filepath|verified_at|age_days
_scanner = os.path.join(home, ".claude", "scripts", "cast-stale-memories.py")
if not os.path.isfile(_scanner):
    # Fall back to sibling in same directory (repo/CI context)
    _sib = os.path.join(os.environ.get("CAST_HEALTH_SCRIPT_DIR", ""), "cast-stale-memories.py")
    if _sib and os.path.isfile(_sib):
        _scanner = _sib
if not os.path.isfile(_scanner):
    # Final fallback: explicit repo dir env var
    _repo = os.environ.get("CAST_REPO_DIR", "")
    if _repo:
        _scanner = os.path.join(_repo, "scripts", "cast-stale-memories.py")

stale_memories = []  # list of (display_name, age_days)
if os.path.isfile(_scanner):
    try:
        # -I: ignore PYTHONPATH/cwd so a planted module cannot run inside the scanner (it puts
        # its own dir on sys.path before importing cast_memory_meta). timeout=2: keep the
        # whole hook inside its 5s limit; on timeout the check is skipped silently (below).
        result = subprocess.run(
            [sys.executable, "-I", _scanner],
            capture_output=True, text=True, timeout=2,
        )
        scanner_lines = result.stdout.splitlines()
        stale_count_raw = int(scanner_lines[0].strip()) if scanner_lines else 0
        for row in scanner_lines[1:]:
            parts = row.split("|", 2)
            if len(parts) < 3:
                continue
            filepath, _vdate, age_str = parts
            # Use the frontmatter name field if readable; fall back to filename stem
            mem_name = os.path.splitext(os.path.basename(filepath))[0]
            try:
                with open(filepath, "r", errors="replace") as fh:
                    in_fm = False
                    for i2, line in enumerate(fh):
                        stripped = line.strip()
                        if i2 == 0 and stripped == "---":
                            in_fm = True
                            continue
                        if not in_fm:
                            break
                        if stripped == "---":
                            break  # end of frontmatter
                        if stripped.startswith("name:"):
                            mem_name = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                            break
            except OSError:
                pass
            try:
                stale_memories.append((mem_name, int(age_str)))
            except ValueError:
                pass
    except Exception:
        pass  # scanner unavailable — silently skip stale memory check

# ── Failing launchd jobs ──────────────────────────────────────────────────────
failing_jobs = []
for line in launchctl_out.splitlines():
    parts = line.split(None, 2)
    if len(parts) < 3:
        continue
    pid_col, status_col, label_col = parts[0], parts[1], parts[2].strip()
    if "com.cast." not in label_col:
        continue
    try:
        status_int = int(status_col)
    except ValueError:
        continue
    if pid_col == "-" and status_int != 0:
        short = label_col.replace("com.cast.", "")
        failing_jobs.append((short, status_int))

# ── Guard modules that failed to load (hook_failures) ─────────────────────────
# cast-pretool-dispatch.py disables a guard for the call when its module cannot be
# loaded and records one hook_failures row per (session, module) named
# "cast-pretool-dispatch/<module>".
#
# Boundary: a cast.db WRITER may make this alarm wrong or noisy, but must never make the
# hook hang or die (that would drop checks (a)/(b) too), silence checks (a)/(b), or make
# check (c) go SILENT while genuine rows exist in a real hook_failures table. So:
#   * the whole check runs in a CHILD process with a hard, budgeted timeout (a single SQL
#     function such as hex(zeroblob(2e7)) can run for seconds inside ONE sqlite VM step,
#     where an in-process progress handler never gets control);
#   * the child NEVER echoes DB text: it compares hook_name COLLATE BINARY against the
#     allowlist and emits an allowlist INDEX, so a column collation (RTRIM/NOCASE) cannot
#     widen the match into attacker-sized output; non-binary-equal rows count as
#     "unrecognised". The parent reads at most 4097 bytes of child stdout and kills the
#     child on overflow or past the deadline;
#   * structural classification first: no hook_failures object = quiet skip (fresh
#     install); anything that is not a real TABLE (e.g. a VIEW) = degraded notice; every
#     sqlite error after that is a degraded notice — no error-text parsing;
#   * the child's JSON is re-validated here and the degraded label must be one of a fixed
#     vocabulary, so attacker text never reaches model context or the error log.
guard_rows = []         # (module, row_count, last_timestamp) — allowlisted modules only
guard_unrec = 0         # rows whose hook_name is not (binary-)equal to an allowlisted module
guard_total = 0         # all cast-pretool-dispatch/% rows in the 7d window (banner count)
guard_check_error = ""  # short fixed-vocabulary label when the check could not complete
# Module names the dispatcher actually records (scripts/cast-pretool-dispatch.py:
# _load("<name>", ...) first args + _record_guard_failure("<name>", ...) + the
# _WORKFLOW_LINT_MOD constant). ORDER matters: the child emits indexes into this tuple.
_GUARD_MODULE_ORDER = (
    "cast_redact",
    "cast_egress_sentinel",
    "cast_git_guard",
    "cast_command_guard",
    "cast_lint_workflow_stage_models",
    "cast_lint_workflow_runtime",
)
_NOT_A_TABLE = "hook_failures is not a table"
# Exact labels the banner may carry: sqlite3.Error subclasses + the few non-sqlite ones.
_DEGRADED_LABELS = frozenset({
    "OperationalError", "DatabaseError", "IntegrityError", "ProgrammingError",
    "InterfaceError", "NotSupportedError", "DataError", "InternalError",
    "UnicodeEncodeError", "MemoryError",
    "timeout", "child failed", _NOT_A_TABLE,
})
_TS_SHAPE = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
_MAX_CHILD_OUT = 4096

# Runs in a child interpreter (python -I -c). Prints ONE small ASCII JSON object; never a
# traceback, never DB-chosen text (only ints, a 19-char shape-checked timestamp, a class name).
_CHECK_C_CODE = r'''
import json, os, re, sqlite3, sys, time, urllib.parse

PREFIX = "cast-pretool-dispatch/"
MODULES = os.environ["CAST_GUARD_MODULES"].split(",")


def emit(obj):
    sys.stdout.write(json.dumps(obj))


conn = None
try:
    # Absolute path behind an explicit empty URI authority ("file:///x"): a bare "//x/y"
    # would parse "x" as an authority and a relative path would be read as one too.
    uri_path = "/" + os.path.abspath(os.environ["CAST_DB_PATH"]).lstrip("/")
    conn = sqlite3.connect("file://" + urllib.parse.quote(uri_path) + "?mode=ro", uri=True, timeout=1)
    # One planted row with invalid UTF-8 must not make fetchall() raise for everyone.
    conn.text_factory = lambda b: b.decode("utf-8", "replace")
    # Cheap first line of defence; the parent's hard timeout is the real bound.
    deadline = time.monotonic() + 1.5
    conn.set_progress_handler(lambda: 1 if time.monotonic() > deadline else 0, 10000)
    kinds = [r[0] for r in conn.execute(
        "SELECT type FROM sqlite_master WHERE name = 'hook_failures' COLLATE NOCASE "
        "AND type IN ('table', 'view')").fetchall()]
    if not kinds:
        emit({"state": "skip"})
    elif any(k != "table" for k in kinds):
        emit({"state": "degraded", "error": "hook_failures is not a table"})
    else:
        # COLLATE BINARY: a column collation (RTRIM/NOCASE) must not widen the match.
        # The result is an allowlist INDEX (or NULL), never the stored text.
        case = ("CASE hook_name COLLATE BINARY "
                + " ".join("WHEN ? THEN %d" % i for i in range(len(MODULES))) + " END")
        rows = conn.execute(
            "SELECT " + case + ", COUNT(*), MAX(timestamp) FROM hook_failures "
            "WHERE hook_name LIKE 'cast-pretool-dispatch/%' "
            "AND timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-7 days') "
            "GROUP BY 1 ORDER BY MAX(timestamp) DESC", [PREFIX + m for m in MODULES]).fetchall()
        mods, unrec = [], 0
        for idx, cnt, ts in rows:
            if idx is None:
                unrec += int(cnt)
                continue
            ts = ts.decode("utf-8", "replace") if isinstance(ts, bytes) else ("" if ts is None else str(ts))
            ok = re.match(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}", ts)
            mods.append([int(idx), int(cnt), ts[:19] if ok else "?"])
        emit({"state": "ok", "rows": mods, "unrec": unrec})
except Exception as exc:
    emit({"state": "degraded", "error": type(exc).__name__})
finally:
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
'''
_db_path = os.environ.get("CAST_DB_PATH") or os.path.join(home, ".claude", "cast.db")


def _log_guard_check_error(label, reason=""):
    # Fixed label + our own constant/class-name text only (never DB- or exception-message
    # text); never raises. hook-errors.log is not model context.
    try:
        import re
        tail = re.sub(r"[^A-Za-z0-9_ .:/-]", "?", str(reason))[:80]
        with open(os.path.join(home, ".claude", "logs", "hook-errors.log"), "a") as lf:
            lf.write(f"ERROR cast-session-start-health guard-failure check: {label} {tail}\n")
    except OSError:
        pass


class _ChildError(Exception):
    pass


def _read_bounded(pipe, sink):
    # Read at most _MAX_CHILD_OUT+1 bytes: the parent never buffers more than that.
    try:
        sink.append(pipe.read(_MAX_CHILD_OUT + 1))
    except (OSError, ValueError):
        pass


if os.path.isfile(_db_path):  # nonexistent DB = quiet skip (and we never create one)
    import re
    import threading
    # Budget: hook timeout is 5s; leave headroom after whatever (a) already spent.
    _budget = max(0.5, min(2.0, 4.0 - (time.monotonic() - _T0)))
    _proc = None
    _th = None
    try:
        _proc = subprocess.Popen(
            [sys.executable, "-I", "-c", _CHECK_C_CODE],
            env={"CAST_DB_PATH": os.path.abspath(_db_path),
                 "CAST_GUARD_MODULES": ",".join(_GUARD_MODULE_ORDER)},
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        _buf = []
        _th = threading.Thread(target=_read_bounded, args=(_proc.stdout, _buf), daemon=True)
        _th.start()
        _th.join(_budget)
        if _th.is_alive():  # no EOF and < 4097 bytes within the budget
            raise subprocess.TimeoutExpired("guard-check", _budget)
        _out = _buf[0] if _buf else b""
        if len(_out) > _MAX_CHILD_OUT:
            raise _ChildError("child output over cap")
        _rc = _proc.wait(timeout=0.5)  # stdout hit EOF, so exit is imminent
        if _rc != 0 or not _out:
            raise _ChildError("child exit/stdout shape")
        _res = json.loads(_out.decode("ascii"))
        _state = _res["state"]
        if _state == "skip":
            pass
        elif _state == "degraded":
            _label = _res["error"]
            if not isinstance(_label, str) or _label not in _DEGRADED_LABELS:
                raise _ChildError("child error label")
            guard_check_error = _label
            _log_guard_check_error(_label)
        elif _state == "ok":
            _rows, _unrec = [], int(_res["unrec"])
            if _unrec < 0 or not isinstance(_res["rows"], list) or len(_res["rows"]) > len(_GUARD_MODULE_ORDER):
                raise _ChildError("child rows shape")
            for _i, _c, _t in _res["rows"]:
                if not (isinstance(_i, int) and 0 <= _i < len(_GUARD_MODULE_ORDER)):
                    raise _ChildError("child row index")
                if not isinstance(_c, int) or _c < 1:
                    raise _ChildError("child row count")
                if _t != "?" and not (isinstance(_t, str) and re.fullmatch(_TS_SHAPE, _t)):
                    _t = "?"
                _rows.append((_GUARD_MODULE_ORDER[_i], _c, _t))
            guard_rows, guard_unrec = _rows, _unrec
            guard_total = sum(r[1] for r in _rows) + _unrec
        else:
            raise _ChildError("child state")
    except subprocess.TimeoutExpired:
        guard_check_error = "timeout"  # the finally block kills the child
        _log_guard_check_error("timeout")
    except _ChildError as _exc:
        guard_check_error = "child failed"
        _log_guard_check_error("child failed", _exc)
    except Exception as _exc:  # unexpected (OSError spawning, bad JSON, ...): loud, not silent
        _cls = type(_exc).__name__
        guard_check_error = _cls if _cls in _DEGRADED_LABELS else "child failed"
        _log_guard_check_error(guard_check_error, _cls)
    finally:
        if _proc is not None:
            if _proc.poll() is None:
                try:
                    _proc.kill()
                except OSError:
                    pass
            try:
                _proc.wait(timeout=1)
            except Exception:
                pass
            if _th is not None:
                _th.join(1)
            try:
                _proc.stdout.close()
            except Exception:
                pass

# ── Emit banner only when something is wrong ──────────────────────────────────
stale_count = len(stale_memories)
fail_count = len(failing_jobs)

if (stale_count == 0 and fail_count == 0 and guard_total == 0 and not guard_check_error
        and not integ_problems and not integ_advisory and not integ_error and not integ_pending):
    import sys; sys.exit(0)

# Build compact banner line
mem_word = "memory" if stale_count == 1 else "memories"
job_word = "job" if fail_count == 1 else "jobs"

parts = []
if integ_problems:
    _n = len(integ_problems) + integ_dropped
    parts.append(f"⚠ install integrity: {_n} problem{'s' if _n != 1 else ''} — git hooks / guard scripts may be altered")
if integ_error:
    parts.append(f"install integrity check could not complete ({integ_error})")
if integ_advisory:
    parts.append("install integrity manifest missing")
if integ_skipped:
    parts.append(f"⚠ install integrity: bytecode verification SKIPPED this session (no time budget, {integ_pending} caches unchecked)")
elif integ_pending:
    parts.append(f"install integrity: bytecode verification incomplete ({integ_pending} pending)")
if guard_total > 0:
    guard_word = "failure" if guard_total == 1 else "failures"
    parts.append(f"⚠ {guard_total} guard load {guard_word} in 7d — protection was DISABLED")
if guard_check_error:
    parts.append(f"guard-failure check could not read cast.db ({guard_check_error})")
if stale_count > 0:
    parts.append(f"{stale_count} stale {mem_word}")
if fail_count > 0:
    parts.append(f"{fail_count} launchd {job_word} failing")
banner = "🩺 health | " + " · ".join(parts)

# Build detail lines (cap at 5 each to stay terse)
detail_lines = []
if integ_problems:
    detail_lines.append("## Install integrity (git hooks run from ~/.claude/githooks):")
    for _d in integ_problems[:8]:
        detail_lines.append(f"  • {_d}")
    _more = max(0, len(integ_problems) - 8) + integ_dropped
    if _more:
        detail_lines.append(f"  … and {_more} more")
    detail_lines.append("  Fix: re-run bash install.sh from the claude-agent-team checkout; names and values: cast doctor")
if integ_error:
    detail_lines.append("## Install integrity check degraded:")
    detail_lines.append(
        f"  Could not verify the install manifest ({integ_error}); tampering cannot be ruled out. "
        "Re-run bash install.sh; details in ~/.claude/logs/hook-errors.log"
    )
if integ_skipped:
    detail_lines.append("## Install integrity: bytecode cache verification SKIPPED this session:")
    detail_lines.append(
        f"  No time budget was left, so NONE of the {integ_pending} bytecode cache file(s) were checked - "
        "a forged cache would not have been caught this session. Run `cast doctor` for the full check."
    )
elif integ_pending:
    detail_lines.append("## Install integrity: bytecode cache verification incomplete:")
    detail_lines.append(
        f"  {integ_pending} cache file(s) not yet verified this session (time budget); verification "
        "resumes next session. Run cast doctor for the full check."
    )
if integ_advisory:
    detail_lines.append("## Install integrity manifest not found (advisory):")
    detail_lines.append("  Advisory: run bash install.sh to create the integrity manifest (~/.claude/install-manifest.sha256).")
if guard_total > 0:
    detail_lines.append("## Guard modules that failed to load (last 7 days):")
    for mod, cnt, last in guard_rows:
        detail_lines.append(f"  • {mod} ({cnt}×, last {last})")
    if guard_unrec:
        detail_lines.append(f"  • unrecognised module ({guard_unrec}×)")
    detail_lines.append(
        "  Fix: bash install.sh from the claude-agent-team checkout; "
        "details in ~/.claude/logs/hook-errors.log"
    )
if guard_check_error:
    detail_lines.append("## Guard-failure check degraded:")
    detail_lines.append(
        f"  Could not read cast.db ({guard_check_error}); guard load failures cannot be "
        "confirmed. Details in ~/.claude/logs/hook-errors.log"
    )
if stale_memories:
    detail_lines.append("## Stale memories (verified_at > 30 days + concrete ref):")
    for name, age in stale_memories[:5]:
        detail_lines.append(f"  • {name} ({age}d ago)")
    if stale_count > 5:
        detail_lines.append(f"  … and {stale_count - 5} more")
if failing_jobs:
    detail_lines.append("## Failing launchd jobs (com.cast.*):")
    for short, status in failing_jobs[:5]:
        detail_lines.append(f"  • {short} (exit {status})")
    if fail_count > 5:
        detail_lines.append(f"  … and {fail_count - 5} more")

detail_text = "\n".join(detail_lines)

output = {
    "systemMessage": banner,
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": detail_text
    }
}
print(json.dumps(output))
PYEOF

exit 0
