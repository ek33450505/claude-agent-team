#!/usr/bin/env python3
"""
cast-commit-reconcile.py — Pre-push hatch audit reconciler.

Enforcement rule (D5b — judges WHO made the commit, not only THAT one exists):
  Per in-session, repo-scoped COMMIT_HATCH_USED audit event newer than the checkpoint:
  1. LEGACY event (no "agent_type" key — written before D5a): unchanged D5 rule. NO
     commit_provenance row recorded within [event_ts - 60s, event_ts + 15min] =
     unauthorized in-session self-commit.
  2. IDENTITY event (has the "agent_type" key): authorized only if "agent_id" is
     non-empty AND the roster type resolved from Claude Code's own subagent sidecar
     (~/.claude/projects/<slug>/<session_id>/subagents/agent-<agent_id>.meta.json, via
     cast_subagent_stop._resolve_roster_type) is exactly "commit". The event's own
     agent_type is NEVER trusted (Claude Code overwrites it with a dispatch's custom
     name, so a differently-typed agent dispatched as name "commit" would forge it).
     Violation reasons: "main-session hatch" (agent_id empty); "agent <roster> is not
     the commit agent"; "commit-agent identity unverifiable (no trusted sidecar)".
     A provenance row is NOT required for an authorized identity event (a commit
     agent's `cd other-repo && commit` is attributed to the hook cwd repo).
  3. CORRUPT hatch line (non-UTF-8, non-JSON, or non-object JSON, whose raw bytes
     contain COMMIT_HATCH_USED) = violation "corrupt hatch line (line N)" (Ed,
     2026-10-04: a damaged hatch event blocks, ackable). A corrupt line cannot be
     dated, so it is identified by the sha256 of its raw bytes: an ACK run records
     them in the RECONCILE_ACK_USED event ("corrupt_line_sha256"), and any later run
     skips a corrupt line whose hash appears in ANY well-formed ack event in the log
     (newest 1000 hashes; counted as "acked_corrupt_lines"). Untrusted corrupt bytes
     are never parsed for dates. A forged ack event is accepted the same way (same
     cooperative boundary as editing audit.jsonl).
     EXCEPTION: the LAST line of a file with no trailing newline (an append in
     progress) is reported "unverifiable" (exit 0, loud) as before.

Exit codes:
  0 — clean / acked / skipped (infra absence) / unverifiable (audit file exists
      but is unreadable — e.g. inside the Claude Code Bash sandbox — or its last,
      newline-less line is a possibly half-written hatch event; the check was
      NOT performed, said loudly on stderr + in the JSON "warning")
  1 — unacked violations found OR DB error (fail-closed)
  CAST_RECONCILE_ACK=1 acks ALL violation kinds (RECONCILE_ACK_USED event + checkpoint
  advance).

Output: valid JSON on stdout regardless of exit code.
Errors: stderr only.

Cooperative-tier limitations (D5 threat model — accepted traceless bypasses):
  Physical or repo-write access can bypass this gate via: (1) edit/delete
  audit.jsonl directly, (2) write the checkpoint file directly,
  (3) CAST_SKIP_RECONCILE=1 with the push, (4) the push's --no-verify flag,
  (5) plant a sidecar: the subagent sidecar lives under ~/.claude/projects and is
  agent-writable with the sandbox off, so it is the same cooperative boundary as
  audit.jsonl (the resolver demands exactly one candidate and refuses spoof shapes,
  but cannot stop a forged file). These require direct filesystem/repo access and
  are outside the model's scope.
"""
from __future__ import annotations

import datetime
import hashlib
import importlib.util
import json
import os
import re
import sqlite3
import subprocess
import sys
import types

# cast_db abstraction — mirrors pattern used in cast-commit-provenance.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cast_db import db_query  # noqa: E402


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

AUDIT_PATH = os.environ.get(
    "CAST_AUDIT_PATH",
    os.path.expanduser("~/.claude/logs/audit.jsonl"),
)
DB_PATH = os.environ.get(
    "CAST_DB_PATH",
    os.path.expanduser("~/.claude/cast.db"),
)


def _git_toplevel() -> str:
    """Return the cwd repo's git toplevel, or '' on failure (best-effort).

    pre-push already cd's to the repo root before invoking this script, and
    passes CAST_RECONCILE_REPO explicitly; this is the fallback for manual runs.
    """
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


# CURRENT_REPO: the repo this reconcile run is scoped to. CAST_RECONCILE_REPO
# (set by pre-push) wins; else the cwd git toplevel. realpath-normalized so it
# matches provenance/hatch repo values across the macOS /tmp symlink. '' when
# undeterminable → full legacy-global behavior (fail-closed, no filtering).
_RAW_REPO = os.environ.get("CAST_RECONCILE_REPO") or _git_toplevel()
CURRENT_REPO = os.path.realpath(_RAW_REPO) if _RAW_REPO else ""

# Legacy global checkpoint (pre-hardening single-file location). Still read as a
# seeding fallback so the first per-repo run does not trigger a 30-day re-scan.
_LEGACY_CHECKPOINT_PATH = os.path.expanduser("~/.claude/run/commit-reconcile-checkpoint")

# Per-repo checkpoint (D5 hardening, required — a global checkpoint + repo
# filtering is a trivial bypass: a clean push in repo A would advance the global
# checkpoint past repo B's pending violations). CAST_RECONCILE_CHECKPOINT, when
# set, is used verbatim (test/back-compat, no seeding). Otherwise derive a
# per-repo path; fall back to the legacy global path when the repo is unknown.
_EXPLICIT_CHECKPOINT = "CAST_RECONCILE_CHECKPOINT" in os.environ


def _derive_checkpoint_path() -> str:
    if _EXPLICIT_CHECKPOINT:
        return os.environ["CAST_RECONCILE_CHECKPOINT"]
    if CURRENT_REPO:
        digest = hashlib.sha256(CURRENT_REPO.encode()).hexdigest()[:8]
        base = os.path.basename(CURRENT_REPO.rstrip("/")) or "repo"
        return os.path.expanduser(
            f"~/.claude/run/commit-reconcile-checkpoint.d/{base}-{digest}"
        )
    return _LEGACY_CHECKPOINT_PATH


CHECKPOINT_PATH = _derive_checkpoint_path()
ACK_MODE = os.environ.get("CAST_RECONCILE_ACK", "0") == "1"

# CLAUDECODE is set in every Claude Code harness shell; absent in Ed's terminal.
# Used to mark whether reconcile events originate from an agent context.
IN_CLAUDE_SESSION: bool = os.environ.get("CLAUDECODE") == "1"

# Window for commit_provenance match: [event_ts - 60s, event_ts + 15min]
WINDOW_BEFORE_SEC = 60
WINDOW_AFTER_SEC = 15 * 60

# Fallback lookback when checkpoint is absent or malformed
DEFAULT_LOOKBACK_DAYS = 30

# Regex for L1 sanitization: strip non-safe chars from audit-derived terminal output
_SAFE_CHARS_RE = re.compile(r"[^a-zA-Z0-9._:TZ+\-]")
# Path-tolerant variant: additionally allows '/' for repo-root paths. Kept SEPARATE
# so session/timestamp values keep the stricter terminal-escape stripping above.
_SAFE_PATH_RE = re.compile(r"[^a-zA-Z0-9._:+\-/]")


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class _DBError(Exception):
    """Raised when a DB query fails in a way that warrants blocking the push (fail-closed)."""


# ---------------------------------------------------------------------------
# Sanitization (L1)
# ---------------------------------------------------------------------------

def _sanitize(s: str) -> str:
    """Strip terminal-escape-unsafe characters from audit-derived strings."""
    return _SAFE_CHARS_RE.sub("?", str(s))


def _sanitize_text(s: str) -> str:
    """Like _sanitize but keeps spaces and parentheses (human-readable reason text)."""
    return re.sub(r"[^a-zA-Z0-9._:TZ+\- ()]", "?", str(s))


def _sanitize_path(s: str) -> str:
    """Like _sanitize but tolerates '/' for filesystem paths (repo roots).

    Do NOT use for session/timestamp values — those keep the stricter _sanitize.
    """
    return _SAFE_PATH_RE.sub("?", str(s))


# ---------------------------------------------------------------------------
# Audit event helpers
# ---------------------------------------------------------------------------

def _append_audit_event(record: dict) -> None:
    """Append a JSON record line to audit.jsonl (best-effort, never crash)."""
    try:
        with open(AUDIT_PATH, "a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception as exc:  # noqa: BLE001
        print(
            f"[cast-commit-reconcile] WARNING: could not append audit event: {exc}",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# Checkpoint helpers
# ---------------------------------------------------------------------------

def _read_checkpoint_file(path: str) -> datetime.datetime | None:
    """Read a single checkpoint file → UTC-naive datetime, or None if absent/malformed."""
    try:
        with open(path) as f:
            raw = f.read().strip()
        ts = datetime.datetime.fromisoformat(raw)
        # Normalise to UTC-naive
        if ts.tzinfo is not None:
            ts = datetime.datetime(*ts.utctimetuple()[:6])
        return ts
    except (FileNotFoundError, ValueError):
        return None


def read_checkpoint() -> datetime.datetime | None:
    """Return the checkpoint datetime (UTC-naive), or None if absent/malformed.

    Per-repo seeding: when a derived per-repo checkpoint file is absent, fall back
    to the legacy global checkpoint once (prevents a 30-day re-evaluation storm on
    the first per-repo run). No seeding when CAST_RECONCILE_CHECKPOINT is explicit
    (test/back-compat) or when the path already IS the legacy global file.
    """
    ts = _read_checkpoint_file(CHECKPOINT_PATH)
    if ts is not None:
        return ts
    if not _EXPLICIT_CHECKPOINT and CHECKPOINT_PATH != _LEGACY_CHECKPOINT_PATH:
        return _read_checkpoint_file(_LEGACY_CHECKPOINT_PATH)
    return None


def write_checkpoint(ts: datetime.datetime, old_ts: datetime.datetime | None = None) -> None:
    """
    Advance the checkpoint to ts (best-effort, never crash).
    Appends a CHECKPOINT_ADVANCED audit event with old/new values.
    """
    try:
        os.makedirs(os.path.dirname(CHECKPOINT_PATH), exist_ok=True)
        with open(CHECKPOINT_PATH, "w") as f:
            f.write(ts.isoformat())
    except Exception as exc:  # noqa: BLE001
        print(
            f"[cast-commit-reconcile] WARNING: could not write checkpoint: {exc}",
            file=sys.stderr,
        )
        return  # Don't emit CHECKPOINT_ADVANCED if the write itself failed

    # Emit CHECKPOINT_ADVANCED so every advance is traceable in audit.jsonl
    _append_audit_event({
        "event": "CHECKPOINT_ADVANCED",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "old_checkpoint": old_ts.isoformat() if old_ts is not None else None,
        "new_checkpoint": ts.isoformat(),
        "repo": CURRENT_REPO,
        "in_claude_session": IN_CLAUDE_SESSION,
    })


# ---------------------------------------------------------------------------
# Audit log reader
# ---------------------------------------------------------------------------

def _parse_ts(raw_ts: str) -> datetime.datetime | None:
    """Parse an ISO timestamp string to a UTC-naive datetime, or None."""
    try:
        ts = datetime.datetime.fromisoformat(raw_ts)
        if ts.tzinfo is not None:
            # Convert timezone-aware → UTC-naive
            ts = datetime.datetime(*ts.utctimetuple()[:6])
        return ts
    except (ValueError, TypeError):
        return None


_HATCH_MARKER = b"COMMIT_HATCH_USED"
_MAX_ACKED_HASHES = 1000
_SHA256_RE = re.compile(r"[0-9a-f]{64}")


def _corrupt_event(raw: bytes, lineno: int) -> dict:
    """A violation-candidate for a corrupt hatch line, identified by sha256 of its
    raw bytes (no line terminator). Nothing in the bytes is parsed."""
    return {
        "timestamp": "",
        "session_id": "unknown",
        "repo": "",
        "_ts": None,
        "corrupt_line": lineno,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def load_hatch_events(since: datetime.datetime, stats: dict | None = None) -> list[dict]:
    """
    Parse audit.jsonl and return COMMIT_HATCH_USED events with
    in_claude_session==True that are strictly newer than `since`, plus a pseudo-event
    (key "corrupt_line") for each corrupt line that mentions COMMIT_HATCH_USED and
    whose sha256 no well-formed RECONCILE_ACK_USED event has acked (those are counted
    in stats["acked_corrupt_lines"]).

    Grandfathering rules:
      - Events lacking in_claude_session field entirely → ignored (pre-feature lines).
      - Events with in_claude_session==false → not suspicious, skipped.
    Other garbage / non-JSON lines (no hatch marker) are silently skipped.

    Repo scoping (D5 hardening), applied per event:
      - event repo non-empty AND CURRENT_REPO non-empty AND realpath(repo) !=
        CURRENT_REPO → skip (a foreign repo's event, not ours to enforce).
      - event repo non-empty and matching → evaluate, repo-scoped.
      - event repo empty/missing → evaluate as legacy-global (fail-closed grandfather).
      - CURRENT_REPO == '' (repo undeterminable) → no filtering, full legacy behavior.

    Decoding is strict UTF-8 PER LINE (never the locale default, never lossy).
    A line that is undecodable, not JSON, or JSON but not an object, AND whose raw
    bytes contain b"COMMIT_HATCH_USED", is a damaged hatch event we cannot evaluate:
      - normally → a corrupt pseudo-event (the caller reports a violation);
      - if it is the LAST line of a file with no trailing newline (an append in
        progress) → the original exception propagates and the caller reports the
        whole check "unverifiable".
    Any such line WITHOUT the marker is junk: skipped, and (undecodable only) counted
    in stats["skipped_undecodable_lines"] when a `stats` dict is passed.
    """
    events: list[dict] = []
    skipped_undecodable = 0
    acked_hashes: list[str] = []  # file order = oldest first
    try:
        # Binary read + per-line strict decode. bytes.splitlines() splits on \n, \r and
        # \r\n exactly like text-mode universal newlines.
        with open(AUDIT_PATH, "rb") as f:
            data = f.read()
        raw_lines = data.splitlines()
        open_tail = bool(data) and not data.endswith((b"\n", b"\r"))
        for idx, raw in enumerate(raw_lines):
            lineno = idx + 1
            is_open_tail = open_tail and idx == len(raw_lines) - 1
            try:
                line = raw.decode("utf-8")
            except UnicodeDecodeError:
                if _HATCH_MARKER in raw:
                    if is_open_tail:
                        raise  # half-written append → unverifiable
                    events.append(_corrupt_event(raw, lineno))
                    continue
                skipped_undecodable += 1
                continue
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if not isinstance(obj, dict):
                    raise ValueError("audit line is not a JSON object")
            except ValueError:  # JSONDecodeError is a ValueError
                if _HATCH_MARKER in raw:
                    if is_open_tail:
                        raise
                    events.append(_corrupt_event(raw, lineno))
                continue  # garbage line without the marker — skip silently

            # Collect corrupt-line hashes acked by earlier ACK runs (any age).
            if obj.get("event") == "RECONCILE_ACK_USED":
                hashes = obj.get("corrupt_line_sha256")
                if isinstance(hashes, list):
                    acked_hashes.extend(
                        h for h in hashes if isinstance(h, str) and _SHA256_RE.fullmatch(h)
                    )
                continue

            # Only care about COMMIT_HATCH_USED events
            if obj.get("event") != "COMMIT_HATCH_USED":
                continue

            # GRANDFATHER: missing in_claude_session field → ignore
            if "in_claude_session" not in obj:
                continue

            # in_claude_session==false → not suspicious, skip
            if not obj["in_claude_session"]:
                continue

            # Repo scoping: skip ONLY a foreign repo's scoped event. Empty
            # event repo (legacy) or empty CURRENT_REPO → no filtering.
            repo = obj.get("repo") or ""
            if not isinstance(repo, str):
                continue  # malformed repo value — skip this line only
            if repo and CURRENT_REPO:
                try:
                    if os.path.realpath(repo) != CURRENT_REPO:
                        continue
                except ValueError:
                    continue  # e.g. NUL byte in repo — skip this line only

            # Parse timestamp
            raw_ts = obj.get("timestamp") or obj.get("ts") or ""
            evt_ts = _parse_ts(raw_ts)
            if evt_ts is None:
                continue  # unparseable timestamp → skip

            # Only events strictly newer than checkpoint
            if evt_ts <= since:
                continue

            evt = {
                "timestamp": raw_ts,
                "session_id": obj.get("session_id", "unknown"),
                "repo": repo,
                "_ts": evt_ts,
            }
            if "agent_type" in obj:  # D5a identity event
                evt["identity"] = True
                evt["agent_type"] = obj.get("agent_type")
                evt["agent_id"] = obj.get("agent_id", "")
            events.append(evt)
    except FileNotFoundError:
        pass  # handled by caller — audit file absent → skip

    acked = set(acked_hashes[-_MAX_ACKED_HASHES:])
    acked_corrupt = 0
    kept: list[dict] = []
    for evt in events:
        if "corrupt_line" in evt and evt["sha256"] in acked:
            acked_corrupt += 1
        else:
            kept.append(evt)

    if stats is not None:
        stats["skipped_undecodable_lines"] = skipped_undecodable
        stats["acked_corrupt_lines"] = acked_corrupt
    return kept


# ---------------------------------------------------------------------------
# Identity check (D5b) — trusted roster type from Claude Code's subagent sidecar
# ---------------------------------------------------------------------------

_SUBAGENT_STOP_MOD = None  # None=unattempted, False=load failed, module=loaded


def _load_subagent_stop():
    """Load cast_subagent_stop.py from THIS script's own directory (never ~/.claude
    on sys.path, never the CWD). Importing it only defines names (its main is guarded
    by __name__); it does insert CAST_HOOK_DIR/~/.claude/scripts at sys.path[0], so
    sys.path is restored afterwards. False on any failure (callers fail closed)."""
    global _SUBAGENT_STOP_MOD
    if _SUBAGENT_STOP_MOD is None:
        saved_path = list(sys.path)
        try:
            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cast_subagent_stop.py")
            spec = importlib.util.spec_from_file_location("cast_subagent_stop", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _SUBAGENT_STOP_MOD = mod
        except BaseException:  # noqa: BLE001 - any failure → fail closed
            _SUBAGENT_STOP_MOD = False
        finally:
            sys.path[:] = saved_path
    return _SUBAGENT_STOP_MOD


def _roster_type(session_id, agent_id) -> str:
    """Sidecar-resolved roster type for (session_id, agent_id), or '' on any doubt."""
    mod = _load_subagent_stop()
    if not mod:
        return ""
    try:
        ctx = types.SimpleNamespace(session_id=session_id, agent_id=agent_id)
        return mod._resolve_roster_type(ctx) or ""
    except Exception:  # noqa: BLE001
        return ""


def violation_reason(evt: dict) -> str | None:
    """Why `evt` is an unauthorized hatch commit, or None if it is authorized."""
    if "corrupt_line" in evt:
        return f"corrupt hatch line (line {evt['corrupt_line']})"
    if not evt.get("identity"):
        # Legacy event: no identity to judge → D5 provenance-window rule.
        return None if has_provenance(evt["_ts"], evt["repo"]) else "no commit provenance in window"
    agent_id = evt.get("agent_id")
    if agent_id == "":
        return "main-session hatch"
    roster = _roster_type(evt["session_id"], agent_id) if isinstance(agent_id, str) else ""
    if roster == "commit":
        return None
    if roster:
        return f"agent {roster} is not the commit agent"
    return "commit-agent identity unverifiable (no trusted sidecar)"


# ---------------------------------------------------------------------------
# Provenance DB check
# ---------------------------------------------------------------------------

def provenance_table_exists() -> bool:
    """
    Return True if commit_provenance table is present in the DB.

    Uses raw sqlite3 (not cast_db) to distinguish absence from error:
      - Table absent (0 rows from sqlite_master) → False → caller skips
      - OperationalError "no such table" → False → caller skips
      - Any other OperationalError or exception → raises _DBError → caller blocks push
    """
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        try:
            rows = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='commit_provenance'"
            ).fetchall()
        finally:
            conn.close()
        return bool(rows)
    except sqlite3.OperationalError as exc:
        msg = str(exc).lower()
        if "no such table" in msg:
            return False  # Table genuinely absent — skip
        raise _DBError(f"DB query failed: {exc}") from exc
    except Exception as exc:
        raise _DBError(f"DB query failed: {exc}") from exc


def has_provenance(event_ts: datetime.datetime, repo: str = "") -> bool:
    """
    Return True if commit_provenance has a row with recorded_at inside
    [event_ts - WINDOW_BEFORE_SEC, event_ts + WINDOW_AFTER_SEC].

    For a repo-scoped event (repo non-empty), additionally require the provenance
    row's repo to match — closing the cross-repo masking hole where a row from
    repo A within the window falsely satisfied an event from repo B. The
    (repo = ? OR repo = '' OR repo IS NULL) leniency lets a provenance row whose
    record-time git call failed (repo stored as '') still match — a bounded
    fail-open sliver per the D5 compat table. Legacy events (repo == '') keep the
    unscoped query (today's exact behavior).
    """
    window_start = (
        event_ts - datetime.timedelta(seconds=WINDOW_BEFORE_SEC)
    ).strftime("%Y-%m-%dT%H:%M:%S")
    window_end = (
        event_ts + datetime.timedelta(seconds=WINDOW_AFTER_SEC)
    ).strftime("%Y-%m-%dT%H:%M:%S")
    sql = "SELECT 1 FROM commit_provenance WHERE recorded_at >= ? AND recorded_at <= ?"
    params: list = [window_start, window_end]
    if repo:
        sql += " AND (repo = ? OR repo = '' OR repo IS NULL)"
        params.append(repo)
    sql += " LIMIT 1"
    rows = db_query(sql, tuple(params))
    return bool(rows)


# ---------------------------------------------------------------------------
# ACK event writer
# ---------------------------------------------------------------------------

def append_ack_event(acked_events: list[dict]) -> None:
    """
    Append a RECONCILE_ACK_USED event to audit.jsonl (best-effort, never crash).
    Includes top-level in_claude_session so agent-issued acks are distinguishable
    from human acks (CLAUDECODE env present vs absent).
    """
    _append_audit_event({
        "event": "RECONCILE_ACK_USED",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "in_claude_session": IN_CLAUDE_SESSION,
        "acked_events": [
            {
                "timestamp": e["timestamp"],
                "session_id": e["session_id"],
                "repo": e.get("repo", ""),
                "in_claude_session": True,
            }
            for e in acked_events
        ],
        "corrupt_line_sha256": [e["sha256"] for e in acked_events if "sha256" in e],
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _report_unverifiable(exc: Exception) -> int:
    """The audit log exists but cannot be read or parsed (EPERM/EACCES/other OSError
    other than not-found, or a non-OSError such as a UnicodeDecodeError from a
    non-UTF-8 line that mentions COMMIT_HATCH_USED), so the D5 provenance check could
    not run. Say so loudly —
    never as a quiet "skip": inside the Claude Code Bash sandbox
    ~/.claude/logs/audit.jsonl is unreadable, and os.path.exists() reports False
    there, which used to turn an unperformed check into a silent pass.

    Exit 0 (the push is not blocked — absence of the evidence is not a
    violation), but the stdout JSON carries status "unverifiable" + a "warning",
    stderr gets a WARN naming the path, and the checkpoint is NOT advanced.
    NOTE: .githooks/pre-push shows this script's stdout and, on "unverifiable" and
    on "skip", also relays this script's stderr (it still discards stderr on a
    clean/acked verdict), so both the stdout "warning" and the stderr WARN reach
    the pusher."""
    # Non-OSError exceptions (e.g. UnicodeDecodeError) carry no errno; their text can
    # echo audit-file bytes, so sanitize the fallback before it reaches JSON/stderr.
    _errno = getattr(exc, "errno", None)
    detail = os.strerror(_errno) if _errno else _sanitize(str(exc))
    result = {
        "status": "unverifiable",
        "reason": f"audit file unreadable: {detail}",
        "checked": 0,
        "violations": [],
        "warning": "D5 commit-provenance check was NOT performed",
    }
    print(json.dumps(result))
    print(
        f"[CAST WARN] commit-provenance reconcile: audit file "
        f"{_sanitize_path(AUDIT_PATH)} is unreadable ({detail}) — the D5 provenance "
        f"check was NOT performed (push not blocked; run it outside the sandbox).",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

    # 1. Determine evaluation window from checkpoint
    checkpoint = read_checkpoint()
    if checkpoint is None:
        since = now - datetime.timedelta(days=DEFAULT_LOOKBACK_DAYS)
    else:
        since = checkpoint

    # 2. Skip cleanly ONLY if the audit file is genuinely missing. An unreadable
    #    file (EPERM/EACCES — e.g. the Bash sandbox) is "unverifiable", not "absent":
    #    os.path.exists() can't tell them apart (it returns False on any stat error).
    try:
        os.stat(AUDIT_PATH)
    except FileNotFoundError:
        result = {
            "status": "skip",
            "reason": "audit file not found",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0
    except OSError as exc:
        return _report_unverifiable(exc)

    # 3. Load candidate events from audit log
    audit_stats: dict = {}
    try:
        events = load_hatch_events(since, audit_stats)
    except Exception as exc:  # noqa: BLE001
        # The file EXISTS (stat() above succeeded), so any failure reading or parsing
        # it — open() denied after a good stat() (chmod 000), an undecodable line that
        # may be a hatch event (UnicodeDecodeError), ... — means the check could not
        # run: unverifiable, never a quiet "skip". Only a file that vanished since the
        # stat() is "absent".
        if isinstance(exc, FileNotFoundError):
            result = {
                "status": "skip",
                "reason": "audit file not found",
                "checked": 0,
                "violations": [],
            }
            print(json.dumps(result))
            return 0
        return _report_unverifiable(exc)

    # 4. Skip cleanly if DB is missing (infra not yet deployed)
    if not os.path.exists(DB_PATH):
        result = {
            "status": "skip",
            "reason": "cast.db not found",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0

    # 5. Check commit_provenance table presence — fail-closed on DB error
    try:
        table_present = provenance_table_exists()
    except _DBError as exc:
        # Exception text can echo DB/path bytes: sanitize before JSON + stderr.
        reason = _sanitize(str(exc))
        result = {
            "status": "error",
            "reason": reason,
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        print(
            f"\n[CAST pre-push] DB query failed — cannot verify provenance; push blocked.\n"
            f"(Fail-closed on infra ERROR; skips only on genuine table absence.)\n"
            f"Reason: {reason}\n",
            file=sys.stderr,
        )
        return 1

    if not table_present:
        result = {
            "status": "skip",
            "reason": "commit_provenance table not found",
            "checked": 0,
            "violations": [],
        }
        print(json.dumps(result))
        return 0

    # Undecodable junk lines are skipped, not fatal — surface the count in the JSON
    # (only when non-zero, so the common-case output is unchanged).
    skipped_note = (
        {"skipped_undecodable_lines": audit_stats["skipped_undecodable_lines"]}
        if audit_stats.get("skipped_undecodable_lines")
        else {}
    )
    if audit_stats.get("acked_corrupt_lines"):
        skipped_note["acked_corrupt_lines"] = audit_stats["acked_corrupt_lines"]

    # 6. Judge each event (identity / provenance window / corrupt line)
    violations: list[dict] = []
    violation_events: list[dict] = []
    checked = 0
    for evt in events:
        checked += 1
        reason = violation_reason(evt)
        if reason is not None:
            v = {
                "timestamp": evt["timestamp"],
                "session_id": evt["session_id"],
                "repo": evt["repo"],
                "reason": reason,
            }
            if evt.get("identity"):
                v["agent_type"] = evt.get("agent_type")
                v["agent_id"] = evt.get("agent_id")
            violations.append(v)
            violation_events.append(evt)

    # 7. Build response
    if not violations:
        result = {"status": "clean", "checked": checked, "violations": [], **skipped_note}
        print(json.dumps(result))
        write_checkpoint(now, old_ts=checkpoint)
        return 0

    if ACK_MODE:
        result = {"status": "acked", "checked": checked, "violations": violations, **skipped_note}
        print(json.dumps(result))
        append_ack_event(violation_events)
        write_checkpoint(now, old_ts=checkpoint)
        return 0

    # Unacked violations — exit 1 with remediation block on stderr (L1: sanitize audit values)
    result = {"status": "violations", "checked": checked, "violations": violations, **skipped_note}
    print(json.dumps(result))

    offenders = "".join(
        f"  - session={_sanitize(v['session_id'])}  ts={_sanitize(v['timestamp'])}"
        f"  repo={_sanitize_path(v.get('repo', ''))}\n"
        f"    reason: {_sanitize_text(v.get('reason', ''))}\n"
        for v in violations
    )
    print(
        f"\n[CAST pre-push] Unauthorized in-session self-commit(s) detected.\n"
        f"Offending sessions / timestamps:\n{offenders}\n"
        f"Remediation:\n"
        f"  1. Re-commit via the commit agent (dispatched by roster type `commit`, "
        f"unnamed or `commit__<label>`).\n"
        f"  2. Human-approved exception: CAST_RECONCILE_ACK=1 git push\n"
        f"     (appends a RECONCILE_ACK_USED event to the audit log)\n",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
