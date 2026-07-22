#!/usr/bin/env python3
"""cast_subagent_stop.py — consolidated SubagentStop processor (parse-once).

Single python process that replaces the 14 heredocs + 3 ``python3 -c`` calls of
``cast-subagent-stop-hook.sh`` plus the deleted per-event sub-hooks. Stdin JSON
(exported by the bash wrapper as ``CAST_STOP_INPUT``) is parsed exactly once; the
one-time classification below is reused by every stage.

Blueprint: plans/w2-1-subagentstop-consolidation-blueprint.md §2. Stages 0, 1, 2
and 17 are IMPLEMENTED here; stages 3-16 are no-op stubs that later agents fill.

Contract: every stage runs inside :func:`run_stage` (its own try/except +
``log_hook_failure('<stage>')``). Fail-open — best-effort per stage, the process
always exits 0 so a broken stage never blocks the parent session.
"""

import glob
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from typing import List, Optional

# ── log_hook_failure loader (sibling cast_db.py) ─────────────────────────────
_HOOK_DIR = os.environ.get("CAST_HOOK_DIR", os.path.expanduser("~/.claude/scripts"))
sys.path.insert(0, _HOOK_DIR)
try:
    from cast_db import log_hook_failure  # type: ignore
except Exception:  # pragma: no cover - degrade gracefully if unavailable
    log_hook_failure = None  # type: ignore


def _log_fail(stage: str, exit_code: int, msg: str, session_id: Optional[str] = None) -> None:
    """Best-effort hook_failures write; never raises."""
    if log_hook_failure:
        try:
            log_hook_failure(f"cast-subagent-stop-hook:{stage}", exit_code, msg, session_id)
        except Exception:
            pass


def _log_error(msg: str) -> None:
    """Append a structured line to ~/.claude/logs/hook-errors.log (never raises).

    Preserves the completeness hook's ``_log_error`` surface (stage 5) — a human-
    readable log line that complements the DB write.
    """
    try:
        logs_dir = os.path.expanduser("~/.claude/logs")
        os.makedirs(logs_dir, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(os.path.join(logs_dir, "hook-errors.log"), "a") as f:
            f.write(f"[{ts}] cast-subagent-stop-hook: {msg}\n")
    except Exception:
        pass


# ── One-time classification primitives ───────────────────────────────────────
# Full Status alternation (longest-first so DONE_WITH_CONCERNS wins over bare DONE).
_STATUS_VALUES = "DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT|APPROVE|REQUEST_CHANGES"
# Gate subset — Step 2.8 recognizes only the four terminal verdicts (no reviewer aliases).
_GATE_VALUES = "DONE_WITH_CONCERNS|DONE|BLOCKED|NEEDS_CONTEXT"

_STATUS_RE = re.compile(r"[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*(" + _STATUS_VALUES + r")")
# Trailing-emphasis variant used by stage 16 — same as _STATUS_RE but tolerates
# closing bold/italic markers after the verdict word (e.g. "**Status: DONE**").
_STATUS_RE_TRAILING = re.compile(_STATUS_RE.pattern + r"[*_]{0,2}")
_JSON_STATUS_RE = re.compile(r'"status"\s*:\s*"(' + _STATUS_VALUES + r')"')
_VERDICT_RE = re.compile(r"\b(" + _STATUS_VALUES + r")\b")
# Last-match-wins gate: prose "Status: X" OR JSON "status": "X" over the four verdicts.
_GATE_RE = re.compile(
    r'(?:[*_]{0,2}\s*Status:\s*[*_]{0,2}\s*|"status"\s*:\s*")(' + _GATE_VALUES + r')"?'
)
# Fenced ```json status``` form — the main hook's Step 2.1 truncation guard (hook L706).
_FENCED_JSON_STATUS_RE = re.compile(
    r'```json\s+status[\s\S]*?"status"\s*:\s*"(' + _STATUS_VALUES + r')"', re.IGNORECASE
)
# Line-anchored prose-dispatch patterns (protocol-check L106-109) — case-insensitive,
# start-of-line only so incidental mentions ("...will dispatch..." mid-line) do not match.
_PROSE_DISPATCH_RE = re.compile(
    r"^(dispatching|i'll dispatch|i will dispatch|will dispatch)\s+.+",
    re.IGNORECASE | re.MULTILINE,
)


def is_exempt_agent(agent_name: str) -> bool:
    """Python port of ``cast_status_exempt_agent`` in scripts/cast-status-contract.sh.

    KEEP IN SYNC with that bash function — the exempt set MUST NOT drift between the
    two (blueprint §5 R7). Returns True (EXEMPT — skip the Status contract) for
    non-CAST / unidentifiable agents; False for identifiable CAST agents.
    """
    a = agent_name or ""
    if a in (
        "general-purpose",
        "Explore",
        "Plan",
        "claude",
        "statusline-setup",
        "output-style-setup",
        "unknown",
        "",
    ):
        return True
    if "workflow-subagent" in a:
        return True
    return False


def compute_trunc_class(output: str) -> int:
    """Three-value truncation classifier (0/1/2) — verbatim logic of hook lines 1098-1136.

    0 = well-formed (Status block present); 1 = missing_formality; 2 = actual truncation.
    """
    if _STATUS_RE.search(output) or _JSON_STATUS_RE.search(output):
        return 0
    if _VERDICT_RE.search(output):
        return 0
    length = len(output)
    if length < 200:
        return 2
    tail = output[-100:]
    if re.search(r":\s*$", tail):
        return 2
    if output.count("```") % 2 != 0:
        return 2
    if not re.search(r"[.!?)\]}\s]\s*$", tail):
        return 2
    return 1


def compute_gate_match(output_full: str, is_exempt: bool) -> str:
    """Step 2.8 gate verdict — last full-pattern match, prose or JSON form.

    Last-match-wins (hook lines 1029-1031 `tail -1`). Empty when exempt or no match.
    """
    if is_exempt:
        return ""
    matches = _GATE_RE.findall(output_full or "")
    return matches[-1] if matches else ""


def compute_event_type(has_turn_ceiling: bool, stop_reason: str) -> str:
    """task_blocked on turn-ceiling or error-ish stop_reason; else task_completed."""
    if has_turn_ceiling:
        return "task_blocked"
    if re.search(r"(error|fail|rate.?limit|timeout)", stop_reason or "", re.IGNORECASE):
        return "task_blocked"
    return "task_completed"


def compute_successors(agent_name: str, event_type: str) -> List[str]:
    """Chain-map successors for a DONE agent (hook Step 4). Empty on any error."""
    if event_type != "task_completed":
        return []
    chain_map_path = os.path.expanduser("~/.claude/config/chain-map.json")
    try:
        with open(chain_map_path) as f:
            chain = json.load(f)
        successors = chain.get(agent_name, []) or []
        return [s for s in successors if s]
    except Exception:
        return []


# ── File-class classifier (F2) ───────────────────────────────────────────────
def classify_files(paths: list) -> str:
    """Return the highest-severity class present across all edited file paths.

    Precedence (first match per file wins), rank taken across all files:
      enforcement (5) > test (4) > code (3) > config (2) > docs (1) > other (0)

    Returns "" for an empty list. Defensive: skips non-str entries.
    """
    _RANKS = {
        "enforcement": 5,
        "test": 4,
        "code": 3,
        "config": 2,
        "docs": 1,
        "other": 0,
    }
    max_rank = -1
    max_label = ""
    for p in paths:
        if not isinstance(p, str):
            continue
        base = os.path.basename(p)
        # enforcement: protected paths / install / guard/hook in name
        if (
            "/scripts/" in p
            or "/bin/" in p
            or "/hooks/" in p
            or "/.githooks/" in p
            or "/migrations/" in p
            or "managed-settings" in p
            or "config/policies" in p
            or "config/egress" in p
            or base in ("install.sh",)
            or base.startswith("cast-db-init")
            or "guard" in base
            or "hook" in base
        ):
            label = "enforcement"
        elif (
            "/tests/" in p
            or "test_" in p
            or p.endswith(".bats")
            or re.search(r"\.test\.[^.]+$", p)
            or re.search(r"\.spec\.[^.]+$", p)
        ):
            label = "test"
        elif p.endswith((".py", ".js", ".ts", ".tsx", ".jsx", ".sh", ".rb", ".go")):
            label = "code"
        elif p.endswith((".json", ".yaml", ".yml", ".toml")):
            label = "config"
        elif p.endswith((".md", ".txt")) or "/docs/" in p:
            label = "docs"
        else:
            label = "other"
        rank = _RANKS[label]
        if rank > max_rank:
            max_rank = rank
            max_label = label
    return max_label


# ── Parse-once context ───────────────────────────────────────────────────────
class Ctx:
    """Holds the once-parsed payload + one-time classification for every stage."""

    def __init__(self) -> None:
        self.data: dict = {}
        self.response_text: str = ""
        self.output_full: str = ""
        self.agent_name: str = "unknown"
        self.agent_id: str = ""
        self.session_id: str = ""
        self.stop_reason: str = ""
        self.has_turn_ceiling: bool = False
        self.duration_ms: int = 0
        self.tool_uses: int = 0
        self.edited_files: list = []
        self.file_class: str = ""
        self.cache_read: Optional[int] = None
        self.cache_create: Optional[int] = None
        self.branch: Optional[str] = None
        # timestamps
        self.ts: str = ""
        self.ts_iso: str = ""
        # sanitized derivations
        self.safe_agent: str = ""
        self.safe_session_id: str = ""
        # db
        self.db_path: str = ""
        self.db_present: bool = False
        # classification
        self.event_type: str = "task_completed"
        self.db_status: str = "DONE"
        self.is_exempt: bool = False
        self.trunc_class: int = 0
        self.has_verdict_keyword: bool = False
        self.gate_match: str = ""
        self.successors: List[str] = []
        # True when the payload carries a raw agent identity (type/name/id); used by
        # the precondition guard to distinguish subagent Stops from main-session Stops.
        self.has_agent_identity: bool = False
        # set by stage 0, consumed by stage 2
        self.fast_row_id = None


def parse_input() -> Optional[Ctx]:
    """Parse CAST_STOP_INPUT once; return a fully-classified Ctx (or None to no-op)."""
    raw = os.environ.get("CAST_STOP_INPUT", "")
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None

    ctx = Ctx()
    ctx.data = data

    # Multi-path response extraction (hook lines 87-110): structured
    # agent_response.content[] → last_assistant_message → output → body.
    response_text = ""
    try:
        agent_response = data.get("agent_response") or {}
        content_blocks = agent_response.get("content") or []
        if isinstance(content_blocks, list) and content_blocks:
            texts = [
                block.get("text", "")
                for block in content_blocks
                if isinstance(block, dict) and block.get("type") == "text"
            ]
            response_text = "\n".join(t for t in texts if t)
    except Exception:
        response_text = ""
    if not response_text:
        response_text = (
            data.get("last_assistant_message")
            or data.get("output")
            or data.get("body")
            or ""
        )
    flat_output = data.get("last_assistant_message") or data.get("output") or ""

    # Capture raw identity before coalescing — used for the precondition guard
    # (mirrors hook line-307 guard: both agent_id AND agent_name absent → main-session Stop).
    raw_name = data.get("agent_type") or data.get("agent_name") or data.get("subagent_name") or ""
    agent_id = data.get("agent_id") or data.get("subagent_id") or ""
    agent_name = raw_name or "unknown"
    session_id = data.get("session_id") or ""

    db_path = os.path.expanduser(os.environ.get("CAST_DB_PATH", "~/.claude/cast.db"))

    # Agent-name fallback query (hook lines 116-129), bound param.
    if agent_name == "unknown" and agent_id:
        try:
            if os.path.isfile(db_path):
                conn = sqlite3.connect(db_path, timeout=2)
                row = conn.execute(
                    "SELECT agent FROM agent_runs WHERE agent_id = ? LIMIT 1", (agent_id,)
                ).fetchone()
                if row and row[0]:
                    agent_name = row[0]
                conn.close()
        except Exception:
            pass  # fall back to "unknown" on any DB error

    ctx.response_text = response_text
    ctx.output_full = flat_output or response_text
    ctx.agent_name = agent_name
    ctx.agent_id = agent_id
    ctx.session_id = session_id
    # Precondition guard flag: True when the payload supplied a raw agent identity.
    # The DB-fallback above may have enriched agent_name, but we gate only on what
    # arrived in the payload (raw_name or agent_id) — a main-session Stop supplies neither.
    ctx.has_agent_identity = bool(raw_name or agent_id)
    ctx.stop_reason = data.get("stop_reason") or ""
    ctx.has_turn_ceiling = "[TURN CEILING]" in (flat_output or response_text)

    try:
        ctx.duration_ms = int(data.get("duration_ms") or data.get("total_duration_ms") or 0)
    except (ValueError, TypeError):
        ctx.duration_ms = 0

    tu = data.get("tool_uses")
    if isinstance(tu, list):
        ctx.tool_uses = len(tu)
    else:
        try:
            ctx.tool_uses = int(data.get("tool_use_count") or 0)
        except (ValueError, TypeError):
            ctx.tool_uses = 0

    _cr = data.get("cache_read_input_tokens")
    _cc = data.get("cache_creation_input_tokens")
    try:
        ctx.cache_read = int(_cr) if _cr not in (None, "") else None
    except (ValueError, TypeError):
        ctx.cache_read = None
    try:
        ctx.cache_create = int(_cc) if _cc not in (None, "") else None
    except (ValueError, TypeError):
        ctx.cache_create = None

    # Timestamps — match the bash `date -u` formats (no microseconds) exactly.
    _now = datetime.now(timezone.utc)
    ctx.ts = _now.strftime("%Y%m%dT%H%M%SZ")
    ctx.ts_iso = _now.strftime("%Y-%m-%dT%H:%M:%SZ")

    ctx.safe_agent = re.sub(r"[^a-zA-Z0-9_-]", "", agent_name)
    ctx.safe_session_id = re.sub(r"[^a-zA-Z0-9-]", "", session_id)

    ctx.db_path = db_path
    try:
        ctx.db_present = os.path.isfile(db_path) and os.path.getsize(db_path) > 0
    except OSError:
        ctx.db_present = False

    # ── One-time classification (replaces the 7 per-event regex evaluations) ──
    ctx.event_type = compute_event_type(ctx.has_turn_ceiling, ctx.stop_reason)
    ctx.db_status = "BLOCKED" if ctx.event_type == "task_blocked" else "DONE"
    ctx.is_exempt = is_exempt_agent(agent_name)
    ctx.trunc_class = compute_trunc_class(ctx.output_full)
    ctx.has_verdict_keyword = bool(_VERDICT_RE.search(ctx.output_full))
    ctx.gate_match = compute_gate_match(ctx.output_full, ctx.is_exempt)
    ctx.successors = compute_successors(agent_name, ctx.event_type)

    return ctx


def run_stage(name: str, fn, ctx: Ctx) -> None:
    """Run one stage in isolation: its own try/except + log_hook_failure('<stage>').

    A stage crash is recorded and swallowed so every later stage still runs — this
    restores the per-heredoc `|| true` isolation the monolithic hook gave for free.
    """
    try:
        fn(ctx)
    except SystemExit:
        pass
    except Exception as e:
        _log_fail(name, -1, str(e), ctx.session_id)


# ── Stage 0: Phase-1 fast status write (eebd870 stuck-running fix) ───────────
def stage0_fast_write(ctx: Ctx) -> None:
    """UPDATE agent_runs SET status,ended_at WHERE id=? capturing fast_row_id.

    Runs FIRST, before ANY transcript I/O — a hard-kill during the multi-MB
    transcript read (stage 2) must never strand the row status='running'. Ported
    verbatim from cast-subagent-stop-hook.sh lines 371-408. No re-query.
    """
    if not ctx.db_present:
        return
    db = ctx.db_path
    agent = ctx.agent_name
    sess = ctx.session_id
    ts = ctx.ts_iso
    st = ctx.db_status

    fast_row_id = None
    _fast_agent_id = ctx.agent_id
    _fconn = None
    try:
        _fconn = sqlite3.connect(db, timeout=5)
        if _fast_agent_id:
            _frow = _fconn.execute(
                "SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent_id=?",
                (_fast_agent_id,),
            ).fetchone()
        else:
            _frow = _fconn.execute(
                "SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent=? AND session_id=?",
                (agent, sess),
            ).fetchone()
        fast_row_id = _frow[0] if _frow and _frow[0] is not None else None
        if fast_row_id is not None:
            _fconn.execute(
                "UPDATE agent_runs SET status=?, ended_at=? WHERE id=?",
                (st, ts, fast_row_id),
            )
            _fconn.commit()
        _fconn.close()
    except Exception as _fe:
        try:
            if _fconn is not None:
                _fconn.close()
        except Exception:
            pass
        if log_hook_failure:
            log_hook_failure("cast-subagent-stop-hook:agent_runs_fast", -1, str(_fe), sess)

    ctx.fast_row_id = fast_row_id


# ── Stage 1: event file write ────────────────────────────────────────────────
def stage1_event_file(ctx: Ctx) -> None:
    """Write task_completed/blocked event JSON to ~/.claude/cast/events/."""
    events_dir = os.path.expanduser("~/.claude/cast/events")
    os.makedirs(events_dir, exist_ok=True)
    event = {
        "event_id": (ctx.agent_name or "unknown") + "-subagent-stop-" + ctx.ts_iso,
        "timestamp": ctx.ts_iso,
        "event_type": ctx.event_type,
        "agent": ctx.agent_name or "unknown",
        "session_id": ctx.session_id,
        "stop_reason": ctx.stop_reason,
        "source": "SubagentStop",
    }
    filepath = os.path.join(events_dir, f"{ctx.ts}-{ctx.safe_agent}-subagent-stop.json")
    with open(filepath, "w") as f:
        json.dump(event, f, indent=2)


# ── Stage 2: transcript glob + 20MB guard + cost + Phase-2 enrichment ────────
def stage2_transcript_cost(ctx: Ctx) -> None:
    """Transcript glob → 20MB guard → cost → enrichment UPDATE WHERE id=fast_row_id.

    Ported verbatim from cast-subagent-stop-hook.sh lines 328-601. The 20MB
    CAST_TRANSCRIPT_MAX_BYTES guard (lines 419-438) is NEVER moved — it protects
    the async-timeout kill path. Enrichment targets the SAME row stage 0 closed.
    """
    if not ctx.db_present:
        return

    db = ctx.db_path
    agent = ctx.agent_name
    sess = ctx.session_id
    ts = ctx.ts_iso
    st = ctx.db_status
    tool_uses = ctx.tool_uses
    response_text = ctx.response_text or None
    cache_read = ctx.cache_read
    cache_create = ctx.cache_create
    fast_row_id = ctx.fast_row_id

    # Resolve transcript path (in-process glob, hook lines 328-338).
    transcript_path = ""
    if ctx.agent_id and ctx.session_id:
        pattern = os.path.expanduser(
            f"~/.claude/projects/*/{ctx.session_id}/subagents/**/agent-{ctx.agent_id}.jsonl"
        )
        try:
            matches = glob.glob(pattern, recursive=True)
            if matches:
                transcript_path = max(matches, key=os.path.getmtime)
        except Exception:
            transcript_path = ""

    # Branch of the agent's working tree (F1 per-feature cost attribution).
    branch = None
    try:
        _payload_cwd = os.path.expanduser((ctx.data.get("cwd") or "").strip())
        _git_cwd = _payload_cwd if _payload_cwd and os.path.isdir(_payload_cwd) else None
        branch = (
            subprocess.run(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
                cwd=_git_cwd,
            ).stdout.strip()
            or None
        )
    except Exception:
        branch = None

    pricing_path = os.path.expanduser("~/.claude/config/model-pricing.json")

    cost_usd = None
    input_tokens = None
    output_tokens = None
    transcript_model = None

    try:
        transcript_path = (transcript_path or "").strip()
        try:
            _max_bytes = int(os.environ.get("CAST_TRANSCRIPT_MAX_BYTES", "20971520") or "20971520")
        except (ValueError, TypeError):
            _max_bytes = 20971520
        _transcript_size = (
            os.path.getsize(transcript_path)
            if transcript_path and os.path.isfile(transcript_path)
            else 0
        )
        _transcript_oversized = _transcript_size > _max_bytes
        if _transcript_oversized:
            # Oversized transcript — SKIP the full line-by-line read. This hook is async
            # with a hard timeout; iterating a multi-MB .jsonl risks a kill mid-read that
            # strands the row 'running'. Fall back to the payload's cache tokens (already
            # in cache_read / cache_create); input/output tokens and cost_usd stay NULL.
            # Honest degradation over a silently wrong cost — one log line records it.
            if log_hook_failure:
                log_hook_failure(
                    "cast-subagent-stop-hook:cost_transcript_oversized",
                    0,
                    f"transcript {_transcript_size} bytes exceeds "
                    f"CAST_TRANSCRIPT_MAX_BYTES={_max_bytes}; cost fields partial "
                    f"(payload cache tokens only): {transcript_path}",
                    sess,
                )
        elif transcript_path and os.path.isfile(transcript_path):
            total_input = 0
            total_output = 0
            total_cache_read = 0
            total_cache_create = 0
            total_tool_uses = 0
            edited = set()
            found_usage = False

            with open(transcript_path, "r", errors="replace") as f:
                for raw_line in f:
                    raw_line = raw_line.strip()
                    if not raw_line:
                        continue
                    try:
                        obj = json.loads(raw_line)
                    except Exception:
                        continue
                    msg = obj.get("message", {}) if isinstance(obj.get("message"), dict) else {}
                    _content = msg.get("content")
                    if isinstance(_content, list):
                        for _blk in _content:
                            if isinstance(_blk, dict) and _blk.get("type") == "tool_use":
                                total_tool_uses += 1
                                _name = _blk.get("name")
                                if _name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                                    _inp = _blk.get("input") or {}
                                    _key = "notebook_path" if _name == "NotebookEdit" else "file_path"
                                    _fpath = _inp.get(_key)
                                    if isinstance(_fpath, str) and _fpath:
                                        edited.add(_fpath)
                    usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else obj.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    total_input += usage.get("input_tokens", 0) or 0
                    total_output += usage.get("output_tokens", 0) or 0
                    total_cache_read += usage.get("cache_read_input_tokens", 0) or 0
                    total_cache_create += usage.get("cache_creation_input_tokens", 0) or 0
                    found_usage = True
                    if not transcript_model and isinstance(msg.get("model"), str):
                        transcript_model = msg["model"]

            if found_usage:
                input_tokens = total_input
                output_tokens = total_output
                # Transcript is authoritative for ALL token types — overrides payload values.
                # The SubagentStop payload's cache fields reflect only the last message, not
                # the full subagent session. For multi-message agents cache tokens dominate cost
                # and the payload would understate them by a large factor.
                cache_read = total_cache_read
                cache_create = total_cache_create
                # Transcript is authoritative for tool_use count — overrides payload zero.
                # The SubagentStop payload never carries tool_use counts; the transcript
                # content blocks are the only source. Mirrors the cache-token override above.
                if total_tool_uses > 0:
                    tool_uses = total_tool_uses

                # F2: collect edited file paths and derive severity class.
                ctx.edited_files = sorted(edited)
                ctx.file_class = classify_files(ctx.edited_files)

                # Load pricing table
                rate_in = 3.0
                rate_out = 15.0
                try:
                    if pricing_path and os.path.isfile(pricing_path):
                        with open(pricing_path, "r") as pf:
                            pricing = json.load(pf)
                        models = pricing.get("models", {})
                        model_key = transcript_model or ""
                        entry = models.get(model_key) or models.get("_default") or {}
                        rate_in = entry.get("cost_per_million_input", 3.0)
                        rate_out = entry.get("cost_per_million_output", 15.0)
                except Exception as _pe:
                    if log_hook_failure:
                        log_hook_failure("cast-subagent-stop-hook:pricing_load", -1, str(_pe), sess)

                # Anthropic full cost formula (cache tokens dominate)
                cr = cache_read or 0
                cc = cache_create or 0
                cost_usd = round(
                    (total_input * rate_in + total_output * rate_out + cc * rate_in * 1.25 + cr * rate_in * 0.1)
                    / 1_000_000,
                    6,
                )
            else:
                if log_hook_failure:
                    log_hook_failure(
                        "cast-subagent-stop-hook:cost_no_usage",
                        0,
                        f"no usage blocks found in transcript {transcript_path}",
                        sess,
                    )
        else:
            if transcript_path:
                # path was resolved but file doesn't exist — log it
                if log_hook_failure:
                    log_hook_failure(
                        "cast-subagent-stop-hook:cost_no_transcript",
                        0,
                        f"transcript not found: {transcript_path}",
                        sess,
                    )
            # No transcript path at all — silent NULL (common for agents dispatched without agent_id)
    except Exception as _ce:
        cost_usd = None
        if log_hook_failure:
            log_hook_failure("cast-subagent-stop-hook:cost_exception", -1, str(_ce), sess)

    # Add new telemetry columns if they don't exist (idempotent — migration 011)
    try:
        conn = sqlite3.connect(db, timeout=5)
        for col, coltype in [
            ("duration_ms", "INTEGER"),
            ("tool_uses", "INTEGER"),
            ("response", "TEXT"),
            ("branch", "TEXT"),
            ("files", "TEXT"),
            ("file_class", "TEXT"),
        ]:
            try:
                conn.execute(f"ALTER TABLE agent_runs ADD COLUMN {col} {coltype}")
            except Exception:
                pass  # column already exists
        conn.commit()
        conn.close()
    except Exception:
        pass

    # Update the running row for this agent. Use agent_id for precise matching when
    # available; fall back to MIN(id) FIFO heuristic when agent_id is absent.
    # FIFO: oldest started row of this type is the one that just finished first.
    # cost_usd, input_tokens, output_tokens, model are written atomically in the same UPDATE.
    agent_id = ctx.agent_id
    files_val = json.dumps(ctx.edited_files) if ctx.edited_files else None
    file_class_val = ctx.file_class or None
    for attempt in range(3):
        try:
            conn = sqlite3.connect(db, timeout=5)
            cur = conn.cursor()
            if fast_row_id is not None:
                # The fast status write above already closed this row out of 'running';
                # enrich the SAME row by id (its status is no longer 'running', so the
                # status='running' subqueries below would not re-find it).
                cur.execute(
                    "UPDATE agent_runs SET status=?, ended_at=?, "
                    "duration_ms=CAST((julianday(replace(replace(?,'T',' '),'Z','')) - julianday(replace(replace(started_at,'T',' '),'Z',''))) * 86400000 AS INTEGER), "
                    "tool_uses=?, response=?, "
                    "cache_read_input_tokens=?, cache_creation_input_tokens=?, "
                    "cost_usd=?, input_tokens=?, output_tokens=?, model=?, branch=?, "
                    "files=?, file_class=? "
                    "WHERE id=?",
                    (st, ts, ts, tool_uses, response_text, cache_read, cache_create,
                     cost_usd, input_tokens, output_tokens, transcript_model, branch,
                     files_val, file_class_val, fast_row_id),
                )
            elif agent_id:
                cur.execute(
                    "UPDATE agent_runs SET status=?, ended_at=?, "
                    "duration_ms=CAST((julianday(replace(replace(?,'T',' '),'Z','')) - julianday(replace(replace(started_at,'T',' '),'Z',''))) * 86400000 AS INTEGER), "
                    "tool_uses=?, response=?, "
                    "cache_read_input_tokens=?, cache_creation_input_tokens=?, "
                    "cost_usd=?, input_tokens=?, output_tokens=?, model=?, branch=?, "
                    "files=?, file_class=? "
                    "WHERE id=("
                    "  SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent_id=?"
                    ")",
                    (st, ts, ts, tool_uses, response_text, cache_read, cache_create,
                     cost_usd, input_tokens, output_tokens, transcript_model, branch,
                     files_val, file_class_val, agent_id),
                )
            else:
                cur.execute(
                    "UPDATE agent_runs SET status=?, ended_at=?, "
                    "duration_ms=CAST((julianday(replace(replace(?,'T',' '),'Z','')) - julianday(replace(replace(started_at,'T',' '),'Z',''))) * 86400000 AS INTEGER), "
                    "tool_uses=?, response=?, "
                    "cache_read_input_tokens=?, cache_creation_input_tokens=?, "
                    "cost_usd=?, input_tokens=?, output_tokens=?, model=?, branch=?, "
                    "files=?, file_class=? "
                    "WHERE id=("
                    "  SELECT MIN(id) FROM agent_runs WHERE status='running' AND agent=? AND session_id=?"
                    ")",
                    (st, ts, ts, tool_uses, response_text, cache_read, cache_create,
                     cost_usd, input_tokens, output_tokens, transcript_model, branch,
                     files_val, file_class_val, agent, sess),
                )
            rows_affected = conn.execute("SELECT changes()").fetchone()[0]
            conn.commit()
            conn.close()
            if rows_affected > 0 or attempt == 2:
                break
            import time as _time
            _time.sleep(0.1)
        except Exception as e:
            try:
                conn.close()
            except Exception:
                pass
            if attempt < 2:
                import time as _time
                _time.sleep(0.1)
            else:
                if log_hook_failure:
                    log_hook_failure("cast-subagent-stop-hook:agent_runs", -1, str(e), sess)
            break


# ── Shared loaders for stages 3-8 (importlib once, cached) ───────────────────
def _load_db_write():
    """Return cast_db.db_write (sys.path already has _HOOK_DIR); no-op on failure."""
    try:
        from cast_db import db_write  # type: ignore
        return db_write
    except Exception:
        def _noop(table, payload):  # graceful degrade — never crash the pipeline
            return False
        return _noop


# Inline validate_handoff fallback — ported verbatim from the old hook (L804-831)
# for the case where cast_handoff_parser cannot be imported.
_HANDOFF_RE = re.compile(r"## Handoff\s*\n([\s\S]+?)(?=\n## |\Z)")


def _inline_validate_handoff(text: str) -> dict:
    m = _HANDOFF_RE.search(text)
    if not m:
        return {"block_present": False, "ok": False, "violation": "missing_handoff",
                "pattern": None, "detail": "No ## Handoff block found", "raw_excerpt": ""}
    block = m.group(1)
    fields = {}
    for line in block.splitlines():
        line = line.strip()
        if ":" in line:
            k, _, v = line.partition(":")
            fields[k.strip().lower()] = v.strip()
    for req in ("files_changed", "status", "blockers"):
        if req not in fields or not fields[req]:
            return {"block_present": True, "ok": False,
                    "violation": "handoff_schema_violation",
                    "pattern": f"missing_field:{req}", "detail": f"Missing {req}",
                    "raw_excerpt": block[:500]}
    if fields.get("status") not in ("DONE", "DONE_WITH_CONCERNS", "BLOCKED"):
        return {"block_present": True, "ok": False,
                "violation": "handoff_schema_violation",
                "pattern": f'invalid_value:status={fields.get("status", "")}',
                "detail": "Invalid status value", "raw_excerpt": block[:500]}
    return {"block_present": True, "ok": True, "violation": None,
            "pattern": None, "detail": None, "raw_excerpt": block[:500]}


def _load_validate_handoff():
    """Return cast_handoff_parser.validate_handoff; inline fallback on failure."""
    try:
        from cast_handoff_parser import validate_handoff  # type: ignore
        return validate_handoff
    except Exception:
        return _inline_validate_handoff


# In-process cast-redact.py loader (replaces the per-event subprocess spawn).
_REDACT_MOD = None  # None=unattempted, False=import failed, module=loaded


def _get_redact_module():
    global _REDACT_MOD
    if _REDACT_MOD is not None:
        return _REDACT_MOD or None
    try:
        import importlib.util as _ilu
        path = os.path.join(_HOOK_DIR, "cast-redact.py")
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


def redact_excerpt(text: str) -> Optional[str]:
    """Redact PII in ``text`` in-process (cast-redact.py analyze_regex/redact_regex).

    Falls back to the old subprocess ``cast-redact.py --engine regex`` mechanism if
    the in-process import fails. Returns the redacted text, or None on total failure
    so the CALLER chooses the policy — stage-6 handoff is fail-OPEN (keep original);
    stage-15 incidents (later) is fail-closed ([REDACTION_FAILED]).
    """
    if not text:
        return text
    mod = _get_redact_module()
    if mod is not None:
        try:
            entities = mod.analyze_regex(text, [])
            return mod.redact_regex(text, entities, "redact")
        except Exception:
            pass
    try:
        res = subprocess.run(
            ["python3", os.path.join(_HOOK_DIR, "cast-redact.py"), "--engine", "regex"],
            input=text.encode(),
            capture_output=True,
            timeout=5,
        )
        if res.returncode == 0:
            return json.loads(res.stdout.decode()).get("redacted_text", text)
    except Exception:
        pass
    return None


# ── Stage 3: dispatch_decisions outcome update (F2 record→decision loop) ─────
def stage3_dispatch_decisions(ctx: Ctx) -> None:
    """Resolve the PreToolUse(Task)-captured pending decision row to its outcome.

    Ported from cast-subagent-stop-hook.sh L604-651. FIFO MIN(id) match on
    (chosen_agent, session_id) mirrors the agent_runs heuristic. BLOCKED on a
    task_blocked event, else DONE. No pending row → no-op.
    """
    if not ctx.db_present:
        return
    agent = ctx.agent_name
    sess = ctx.session_id
    if not agent or not sess:
        return
    outcome = ctx.db_status  # "BLOCKED" if task_blocked else "DONE"
    conn = None
    try:
        conn = sqlite3.connect(ctx.db_path, timeout=2)
        conn.execute(
            "UPDATE dispatch_decisions SET outcome=? "
            "WHERE id=(SELECT MIN(id) FROM dispatch_decisions "
            "          WHERE outcome='pending' AND chosen_agent=? AND session_id=?)",
            (outcome, agent, sess),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
        _log_fail("dispatch_decisions", -1, str(e), sess)


# ── Stage 4: single truncation write (agent_truncations + quality_gates) ─────
def _extract_work_log(text: str) -> Optional[str]:
    """Text between a '## Work Log' heading and the next 'Status:' line (or EOF).

    Verbatim port of cast-truncation-check.sh extract_work_log() (L56-72). Returns
    the stripped section, or None when no heading is present / the capture is empty.
    """
    m = re.search(r"##\s+Work\s+Log\s*\n([\s\S]*?)(?=\nStatus:|$)", text, re.IGNORECASE)
    if not m:
        return None
    extracted = m.group(1).strip()
    return extracted if extracted else None


def stage4_truncation_record(ctx: Ctx) -> None:
    """SINGLE truncation write — collapses today's double write (blueprint §6.5).

    Merges main-hook Step 2.1 (L653-751) with cast-truncation-check.sh's
    extract_work_log semantics. Guard: non-exempt agent, response >=50 chars, and
    NO Status/JSON-status block (the main hook's unanchored, test-locked detection —
    blueprint R5). Writes agent_truncations (the authoritative truncation record).
    The old cast-truncation-check.sh path is deleted, so this is now the ONE writer.
    """
    if ctx.is_exempt or not ctx.db_present:
        return
    response_text = ctx.response_text or ""
    if len(response_text.strip()) < 50:
        return
    if _STATUS_RE.search(response_text) or _FENCED_JSON_STATUS_RE.search(response_text):
        return

    agent = ctx.agent_name
    sess = ctx.session_id
    agent_id = ctx.agent_id
    ts = ctx.ts_iso
    last_line = response_text[-200:] if len(response_text) > 200 else response_text
    char_count = len(response_text)
    partial_work_log = _extract_work_log(response_text)

    conn = None
    try:
        conn = sqlite3.connect(ctx.db_path, timeout=5)
        conn.execute(
            "INSERT INTO agent_truncations (session_id, agent_type, agent_id, last_line, timestamp, char_count, partial_work_log) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (sess, agent, agent_id or None, last_line, ts, char_count, partial_work_log or None),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
        _log_fail("truncation", -1, str(e), sess)


# ── Stage 5: completeness_events (non-exempt + no Status + non-empty output) ─
def stage5_completeness(ctx: Ctx) -> None:
    """Write a completeness_events row when a non-exempt agent's non-empty output
    lacks a Status block. Port of cast-response-completeness-hook.sh (L110-214):
    HIGH/MEDIUM severity + the _log_error line + CREATE TABLE IF NOT EXISTS.

    Uses the FLAT last_assistant_message/output field (the original hook's PARSED
    'output'), NOT the structured-content fallback — reading ctx.data keys, no
    re-parse. Status detection is human-form OR plain JSON-form (completeness
    L129-131), matching the retargeted completeness suite.
    """
    if ctx.is_exempt:
        return
    output = ctx.data.get("last_assistant_message") or ctx.data.get("output") or ""
    if not output:
        return
    if _STATUS_RE.search(output) or _JSON_STATUS_RE.search(output):
        return

    agent = ctx.agent_name or "unknown"
    ts = ctx.ts_iso
    snippet = output[:200]
    # Severity: HIGH when the output ends on an incomplete phrase (L152-156).
    if re.search(r"(Perfect!|Let me|I'll|Now|I'm|I am)\s*$", output, re.IGNORECASE):
        severity = "HIGH"
    else:
        severity = "MEDIUM"

    _log_error(
        f"[CAST COMPLETENESS] Agent response missing Status block. Possible "
        f"truncation. Agent: {agent}. Severity: {severity}. Timestamp: {ts}."
    )

    conn = None
    try:
        conn = sqlite3.connect(ctx.db_path, timeout=5)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS completeness_events ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "agent TEXT NOT NULL, "
            "truncated_at TEXT NOT NULL, "
            "snippet TEXT, "
            "severity TEXT DEFAULT 'MEDIUM', "
            "created_at TEXT DEFAULT CURRENT_TIMESTAMP)"
        )
        conn.execute(
            "INSERT INTO completeness_events (agent, truncated_at, snippet, severity) "
            "VALUES (?, ?, ?, ?)",
            (agent, ts, snippet, severity),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
        _log_fail("completeness", -1, str(e), ctx.session_id)


# ── Stage 6: ## Handoff schema validation → agent_protocol_violations ────────
def stage6_handoff_validation(ctx: Ctx) -> None:
    """Validate the typed ## Handoff schema (WARN-only). Port of hook L754-921.

    False-positive guard: an absent block on a SOLO dispatch (no batch_id) logs
    nothing; an absent block on a CHAINED dispatch (batch_id present) is a
    missing_handoff violation. The raw excerpt is redacted in-process before storage
    (fail-OPEN — the original keeps the unredacted text on redaction failure).
    """
    if ctx.is_exempt:
        return
    response_text = ctx.response_text or ""
    if not response_text.strip():
        return

    db_write = _load_db_write()
    validate_handoff = _load_validate_handoff()

    agent_type = ctx.agent_name or "unknown"
    agent_id = ctx.agent_id or ""
    session_id = ctx.session_id or ""
    batch_id = ctx.data.get("batch_id")

    try:
        result = validate_handoff(response_text)
    except Exception:
        return  # parser error → degrade gracefully, no violation logged

    block_present = result.get("block_present", False)
    ok = result.get("ok", True)
    violation = result.get("violation")
    pattern = result.get("pattern")
    detail = result.get("detail", "")
    raw_excerpt = result.get("raw_excerpt", "")

    # Solo dispatch with absent block: not an error — log nothing.
    if not block_present and not batch_id:
        return
    # No violation: nothing to log.
    if ok:
        return

    excerpt_raw = (raw_excerpt or detail or "")[:500]
    _redacted = redact_excerpt(excerpt_raw)
    excerpt_for_db = _redacted if _redacted is not None else excerpt_raw

    payload = {
        "session_id": session_id,
        "agent_type": agent_type,
        "agent_id": agent_id,
        "violation": violation,
        "pattern": pattern,
        "timestamp": ctx.ts_iso,
        "raw_excerpt": excerpt_for_db,
    }
    payload = {k: v for k, v in payload.items() if v is not None}
    try:
        db_write("agent_protocol_violations", payload)
    except Exception:
        pass  # never crash the hook pipeline

    sys.stderr.write(
        f"[CAST-WARN] handoff_validation: {agent_type} {violation}"
        + (f" ({pattern})" if pattern else "")
        + " — logged to cast.db\n"
    )


# ── Stage 7: prose-dispatch protocol check → agent_protocol_violations ───────
def stage7_protocol_check(ctx: Ctx) -> None:
    """Flag prose-only dispatch claims ("Dispatching X" with no Agent tool call).

    Port of cast-agent-protocol-check.sh (L53-158). Builds full_text from the
    structured content blocks + flat message field; a real tool_use anywhere in the
    payload suppresses the warning. WARN-only, never blocks.
    """
    db_write = _load_db_write()

    agent_type = ctx.agent_name or "unknown"
    agent_id = ctx.agent_id or ""
    session_id = ctx.session_id or ""
    batch_id = ctx.data.get("batch_id")

    agent_response = ctx.data.get("agent_response") or {}
    content_blocks = agent_response.get("content") or []

    text_parts = []
    has_tool_use = False
    for block in content_blocks:
        if isinstance(block, dict):
            if block.get("type") == "text":
                text_parts.append(block.get("text") or "")
            elif block.get("type") == "tool_use":
                has_tool_use = True

    flat_text = (
        ctx.data.get("last_assistant_message")
        or ctx.data.get("output")
        or ctx.data.get("response_text")
        or ctx.data.get("body")
        or ""
    )
    if flat_text:
        text_parts.append(flat_text)

    full_text = "\n".join(p for p in text_parts if p)

    tool_uses = ctx.data.get("tool_uses")
    if isinstance(tool_uses, list) and tool_uses:
        has_tool_use = True
    if (ctx.data.get("tool_use_count") or 0) > 0:
        has_tool_use = True
    raw_input = os.environ.get("CAST_STOP_INPUT", "") or ""
    if '"type": "tool_use"' in raw_input or '"type":"tool_use"' in raw_input:
        has_tool_use = True

    if not full_text:
        return

    clean_text = re.sub(r"```.*?```", "", full_text, flags=re.DOTALL)
    match = _PROSE_DISPATCH_RE.search(clean_text)

    if match and not has_tool_use:
        start = max(0, match.start() - 40)
        end = min(len(clean_text), match.end() + 80)
        excerpt = clean_text[start:end].strip()
        matched_pattern = match.group(0).strip()[:120]

        payload = {
            "session_id": session_id,
            "agent_type": agent_type,
            "agent_id": agent_id,
            "batch_id": batch_id,
            "violation": "prose_dispatch",
            "pattern": matched_pattern,
            "timestamp": ctx.ts_iso,
            "raw_excerpt": excerpt[:500],
        }
        payload = {k: v for k, v in payload.items() if v is not None}
        try:
            db_write("agent_protocol_violations", payload)
        except Exception:
            pass  # never crash the hook pipeline

        sys.stderr.write(
            f"[CAST-PROTOCOL] Agent {agent_type} appears to have paraphrased dispatch "
            f"of '{matched_pattern}' without an Agent tool call\n"
        )
        sys.stderr.write(
            f"[CAST-WARN] agent_protocol_violations: {agent_type} paraphrased dispatch "
            f"— logged to cast.db\n"
        )


# ── Stage 8: quality_gates row for code-reviewer/test-runner/security ────────
def stage8_quality_gate(ctx: Ctx) -> None:
    """Record a gate agent's self-reported Status to quality_gates (dashboard).

    Port of hook L923-984. Only code-reviewer / test-runner / security. DONE and the
    reviewer alias APPROVE are pass (contract_passed=1); everything else is non-pass.
    """
    if ctx.agent_name not in ("code-reviewer", "test-runner", "security"):
        return
    if not ctx.db_present:
        return
    out = ctx.output_full or ""
    m = _STATUS_RE.search(out)
    if not m:
        return
    status = m.group(1)
    agent = ctx.agent_name
    sess = ctx.session_id
    ts = ctx.ts_iso

    conn = None
    try:
        import uuid
        conn = sqlite3.connect(ctx.db_path, timeout=5)
        conn.execute(
            "INSERT INTO quality_gates (id, session_id, agent_name, timestamp, status_line, contract_passed, retry_count, gate_type) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            # APPROVE is pass-like (reviewer's DONE equivalent); REQUEST_CHANGES is non-pass.
            (str(uuid.uuid4()), sess, agent, ts, status, 1 if status in ("DONE", "APPROVE") else 0, 0, "status_contract"),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
        _log_fail("quality_gates", -1, str(e), sess)


# ── Shared helpers for the module-run + incident stages ──────────────────────
def _repo_root(ctx: Ctx) -> str:
    """git rev-parse --show-toplevel (cached on ctx); falls back to cwd.

    One spawn per event max — stages 9 and 10 both need the repo root for their
    env contract, so the result is memoized on the ctx.
    """
    cached = getattr(ctx, "_repo_root_cache", None)
    if cached is not None:
        return cached
    root = None
    try:
        root = (
            subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=5,
            ).stdout.strip()
            or None
        )
    except Exception:
        root = None
    if not root:
        root = os.getcwd()
    ctx._repo_root_cache = root  # type: ignore[attr-defined]
    return root


def _run_script_module(rel_name: str, env_overrides: dict) -> None:
    """Run a sibling script as __main__ in-process via runpy, with a scoped env.

    Replaces the per-event ``python3 <script>`` subprocess spawns of hook Steps 2.6
    and 2.7. ``env_overrides`` are applied to ``os.environ`` for the duration of the
    run and restored afterward (the scripts read their inputs from env). ``SystemExit``
    (the scripts call ``sys.exit()``) is caught so it never propagates out of the
    stage. Skips gracefully when the script is absent.
    """
    import runpy

    path = os.path.join(_HOOK_DIR, rel_name)
    if not os.path.isfile(path):
        return
    saved: dict = {}
    for k, v in env_overrides.items():
        saved[k] = os.environ.get(k)
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    try:
        runpy.run_path(path, run_name="__main__")
    except SystemExit:
        pass
    finally:
        for k, old in saved.items():
            if old is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


def _redact_fail_closed(text: str) -> str:
    """FAIL-CLOSED redaction for the incidents surface (stage 15).

    On ANY redaction failure, returns the ``[REDACTION_FAILED]`` marker — NEVER the
    raw text. Empty text passes through unchanged (nothing to leak). Contrast with
    stage 6/16, which are fail-OPEN (keep the original on failure).
    """
    if not text:
        return text
    redacted = redact_excerpt(text)
    if redacted is None or redacted == "":
        _log_error("WARN: redaction failed — storing [REDACTION_FAILED] marker")
        return "[REDACTION_FAILED]"
    return redacted


# ── Stage 9: claimed-work verifier → agent_hallucinations ────────────────────
def stage9_claimed_work(ctx: Ctx) -> None:
    """Category-1 hallucination guard — verify Work-Log file claims vs reality.

    Port of hook Step 2.6 (L986-1000). START_TIME comes from a BOUND-PARAM query
    (replaces the shell ``sqlite3`` string interpolation at old L992 — the
    SAFE_SESSION_ID SQL concern is eliminated structurally). Runs
    cast_claimed_work_verifier.py in-process via runpy with its env contract;
    ``SystemExit`` is caught. Observability-only, never blocks.
    """
    if not (ctx.response_text or "").strip():
        return

    # Resolve the agent's real start time (bound params — no interpolation). Falls
    # back to the stop-time when no matching row exists yet.
    start_time = ctx.ts_iso
    if ctx.db_present:
        conn = None
        try:
            conn = sqlite3.connect(ctx.db_path, timeout=2)
            row = conn.execute(
                "SELECT started_at FROM agent_runs WHERE session_id=? AND agent=? ORDER BY id DESC LIMIT 1",
                (ctx.session_id, ctx.agent_name),
            ).fetchone()
            conn.close()
            if row and row[0]:
                start_time = row[0]
        except Exception:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass

    _run_script_module(
        "cast_claimed_work_verifier.py",
        {
            "CAST_STOP_RESPONSE_TEXT": ctx.response_text,
            "CAST_AGENT_NAME": ctx.agent_name,
            "CAST_SESSION_ID": ctx.session_id,
            "CAST_AGENT_START_TIME": start_time,
            "CAST_REPO_ROOT": _repo_root(ctx),
            "CAST_DB_PATH": ctx.db_path,
        },
    )


# ── Stage 10: ## Facts block → agent_memories ────────────────────────────────
def stage10_facts_write(ctx: Ctx) -> None:
    """Extract a ## Facts block → agent_memories (cast-memory-facts-write.py).

    Port of hook Step 2.7 (L1005-1014). Runs the hardened facts writer in-process
    via runpy with its env contract; ``SystemExit`` caught. Skips gracefully when
    the script is absent (handled by :func:`_run_script_module`). Non-blocking.
    """
    if not (ctx.response_text or "").strip():
        return
    _run_script_module(
        "cast-memory-facts-write.py",
        {
            "CAST_STOP_AGENT": ctx.agent_name,
            "CAST_STOP_RESPONSE_TEXT": ctx.response_text,
            "CAST_DB_PATH": ctx.db_path,
            "CAST_PROJECT_ROOT": _repo_root(ctx),
        },
    )


# ── Stage 11: turn-ceiling checkpoint file ───────────────────────────────────
def stage11_turn_ceiling(ctx: Ctx) -> None:
    """Turn-ceiling checkpoint file (hook Step 3, L1052-1082).

    Only when the agent hit the turn ceiling (``[TURN CEILING]`` marker in the
    output). Writes a resume-hint checkpoint JSON to
    ~/.claude/cast/turn-ceiling-events/.
    """
    if not ctx.has_turn_ceiling:
        return
    ceil_dir = os.path.expanduser("~/.claude/cast/turn-ceiling-events")
    os.makedirs(ceil_dir, exist_ok=True)
    checkpoint = {
        "timestamp": ctx.ts_iso,
        "agent": ctx.agent_name or "unknown",
        "session_id": ctx.session_id,
        "stop_reason": ctx.stop_reason,
        "event": "turn_ceiling_hit",
        "output_preview": (ctx.output_full or "")[:200],
        "resume_hint": "Re-invoke the agent with --resume or dispatch orchestrator to continue from last checkpoint.",
    }
    filepath = os.path.join(ceil_dir, f"{ctx.ts}-{ctx.safe_agent}.json")
    with open(filepath, "w") as f:
        json.dump(checkpoint, f, indent=2)


# ── Stage 12: truncation file + banner (class 2) / missing_formality (class 1) ─
def stage12_truncation_files(ctx: Ctx) -> None:
    """trunc_class==2 → truncated-agent file + [CAST-TRUNCATED] banner; ==1 →
    missing_formality protocol-violation row. Port of hook L1139-1209.

    Gated to non-exempt agents (Step 3.5's ``STATUS_CONTRACT_EXEMPT==0``) with a
    known agent name. The banner uses SAFE_AGENT (sanitized) so a hostile payload
    cannot break the emitted JSON. Distinct from stage 4 (agent_truncations DB write)
    — this is the file-artifact + parent-session directive path.
    """
    if ctx.is_exempt:
        return
    out = ctx.output_full or ""
    agent = ctx.agent_name or ""
    if not out or not agent or agent == "unknown":
        return

    if ctx.trunc_class == 2:
        # ACTUAL TRUNCATION: write the partial-output file, then fire the banner.
        trunc_dir = os.path.expanduser("~/.claude/cast/truncated-agents")
        try:
            os.makedirs(trunc_dir, exist_ok=True)
            record = {
                "timestamp": ctx.ts_iso,
                "agent": agent,
                "session_id": ctx.session_id,
                "truncation_detected": True,
                "output_tail": out[-500:] if out else "",
            }
            ts_safe = ctx.ts_iso.replace(":", "").replace("-", "").replace(".", "")
            filepath = os.path.join(trunc_dir, f"{ts_safe}-{ctx.safe_agent or 'unknown'}.json")
            with open(filepath, "w") as f:
                json.dump(record, f, indent=2)
        except Exception as e:
            _log_fail("truncation_file", -1, str(e), ctx.session_id)
        # Emit the directive to the parent session. SAFE_AGENT (sanitized) — never the
        # raw agent name — so a JSON-breaking payload cannot corrupt the object.
        banner_text = (
            "[CAST-TRUNCATED] Agent " + (ctx.safe_agent or "") + " stopped without a "
            "valid Status block. Output may be incomplete. Re-dispatch the agent or "
            "review ~/.claude/cast/truncated-agents/ for the partial output. Do NOT "
            "auto-retry expensive agents — surface this as BLOCKED."
        )
        sys.stdout.write(
            json.dumps(
                {"hookSpecificOutput": {"hookEventName": "SubagentStop", "additionalContext": banner_text}},
                ensure_ascii=False,
            )
            + "\n"
        )
    elif ctx.trunc_class == 1:
        # MISSING FORMALITY: suppress the banner, log a protocol violation (best-effort).
        if not ctx.db_present:
            return
        conn = None
        try:
            conn = sqlite3.connect(ctx.db_path, timeout=2)
            tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "agent_protocol_violations" not in tables:
                conn.close()
                return
            conn.execute(
                "INSERT INTO agent_protocol_violations (session_id, agent_type, violation, pattern, timestamp, raw_excerpt) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (ctx.session_id, agent, "missing_formality", "no_status_block", ctx.ts_iso, out[-200:] if out else None),
            )
            conn.commit()
            conn.close()
        except Exception as e:
            try:
                if conn:
                    conn.close()
            except Exception:
                pass
            _log_fail("missing_formality", -1, str(e), ctx.session_id)


# ── Stage 13: duration p95 advisory → routing_events(slow_agent) ─────────────
def stage13_duration_p95(ctx: Ctx) -> None:
    """Duration p95 advisory (duration-check L50-137). Runs AFTER stage 2 so the
    freshly-written ``duration_ms`` is authoritative — fixes today's unordered
    cross-hook race. Reads this run's duration from the row stage 2 closed, queries
    ONLY history for the p95, and records a routing_events(slow_agent) row +
    [CAST-PERF] banner when the run exceeds p95 (needs >=5 samples).
    """
    if not ctx.db_present:
        return
    agent_type = ctx.agent_name or "unknown"
    session_id = ctx.session_id or "unknown"
    conn = None
    try:
        conn = sqlite3.connect(ctx.db_path, timeout=5)
        # This run's duration — prefer the row stage 2 enriched, then agent_id, then session.
        duration_ms = None
        if ctx.fast_row_id is not None:
            r = conn.execute(
                "SELECT duration_ms FROM agent_runs WHERE id=? AND duration_ms IS NOT NULL",
                (ctx.fast_row_id,),
            ).fetchone()
            if r:
                duration_ms = r[0]
        if duration_ms is None and ctx.agent_id:
            r = conn.execute(
                "SELECT duration_ms FROM agent_runs WHERE agent_id=? AND duration_ms IS NOT NULL ORDER BY id DESC LIMIT 1",
                (ctx.agent_id,),
            ).fetchone()
            if r:
                duration_ms = r[0]
        if duration_ms is None and session_id != "unknown":
            r = conn.execute(
                "SELECT duration_ms FROM agent_runs WHERE session_id=? AND duration_ms IS NOT NULL ORDER BY id DESC LIMIT 1",
                (session_id,),
            ).fetchone()
            if r:
                duration_ms = r[0]
        if duration_ms is None:
            conn.close()
            return

        rows = conn.execute(
            "SELECT duration_ms FROM agent_runs "
            "WHERE agent = ? AND duration_ms IS NOT NULL "
            "AND started_at >= datetime('now','-30 days') "
            "ORDER BY duration_ms",
            (agent_type,),
        ).fetchall()
        samples = [r[0] for r in rows if r[0] is not None]
        sample_count = len(samples)
        if sample_count < 5:
            conn.close()
            return
        p95_index = int(0.95 * sample_count) - 1
        p95_index = max(0, min(p95_index, sample_count - 1))
        p95_ms = samples[p95_index]
        if duration_ms <= p95_ms:
            conn.close()
            return

        data_json = json.dumps(
            {"duration_ms": duration_ms, "p95_ms": p95_ms, "agent_type": agent_type, "sample_count": sample_count}
        )
        conn.execute(
            "INSERT INTO routing_events (session_id, timestamp, event_type, matched_route, data) "
            "VALUES (?, ?, ?, ?, ?)",
            (session_id, ctx.ts_iso, "slow_agent", agent_type, data_json),
        )
        conn.commit()
        conn.close()
        sys.stderr.write(
            f"[CAST-PERF] {agent_type} exceeded p95 duration ({duration_ms}ms vs p95 "
            f"{p95_ms}ms, n={sample_count} samples)\n"
        )
    except Exception as e:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
        _log_fail("duration_p95", -1, str(e), ctx.session_id)


# ── Stage 14: daily budget guard → flag file + banner ────────────────────────
def stage14_budget_alert(ctx: Ctx) -> None:
    """Daily budget guard (budget-alert L37-156). Runs AFTER stage 2 so today's
    ``SUM(cost_usd)`` already includes this event's cost — fixes today's
    read-before-write race. An ``O_EXCL`` marker guarantees exactly one alert per
    UTC day; stale prior-day markers are swept. Emits [CAST-BUDGET-WARN] /
    [CAST-BUDGET-HARD-LIMIT] hookSpecificOutput.
    """
    if not ctx.db_present:
        return
    state_dir = os.path.expanduser("~/.claude/cast")
    day_compact = datetime.now(timezone.utc).strftime("%Y%m%d")
    alert_marker = os.path.join(state_dir, f"budget-alert-{day_compact}.flag")
    # Fast-path dedup: today's alert already fired.
    if os.path.exists(alert_marker):
        return

    conn = None
    try:
        conn = sqlite3.connect(ctx.db_path, timeout=5)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        # Global daily budget (most specific / most recent wins).
        cur.execute(
            "SELECT limit_usd, alert_at_pct FROM budgets "
            "WHERE scope = 'global' AND period = 'daily' ORDER BY id DESC LIMIT 1"
        )
        budget_row = cur.fetchone()
        if not budget_row:
            conn.close()
            return
        limit_usd = float(budget_row["limit_usd"] or 0)
        alert_at_pct = float(budget_row["alert_at_pct"] or 0.80)
        if limit_usd <= 0:
            conn.close()
            return

        # Today's spend from agent_runs (the same authoritative source `cast budget`
        # reports). LIKE-form absorbs both 'T'/'Z' and space-form timestamps.
        today = datetime.now(timezone.utc).date().isoformat()
        cur.execute(
            "SELECT COALESCE(SUM(cost_usd), 0.0) FROM agent_runs WHERE started_at LIKE ? || '%'",
            (today,),
        )
        today_spend = float(cur.fetchone()[0] or 0)
        conn.close()
        conn = None
        if today_spend <= 0:
            return

        pct_used = today_spend / limit_usd
        if pct_used >= 1.0:
            msg = (
                f"[CAST-BUDGET-HARD-LIMIT] Daily spend ${today_spend:.4f} has reached the "
                f"${limit_usd:.2f} daily budget limit ({pct_used*100:.0f}%). "
                "MANDATORY: Pause all agent dispatches until the budget resets at midnight UTC."
            )
        elif pct_used >= alert_at_pct:
            remaining = limit_usd - today_spend
            msg = (
                f"[CAST-BUDGET-WARN] Daily spend ${today_spend:.4f} is {pct_used*100:.0f}% "
                f"of the ${limit_usd:.2f} daily budget (${remaining:.4f} remaining). "
                "Consider routing lighter tasks to local models to conserve budget."
            )
        else:
            return

        # Atomically claim today's alert slot (O_EXCL = exactly one winner per day).
        try:
            os.makedirs(state_dir, exist_ok=True)
            fd = os.open(alert_marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.close(fd)
        except FileExistsError:
            return  # another concurrent hook already claimed today's alert — stay silent
        except Exception:
            pass  # marker dir unwritable etc. — degrade gracefully, still allow the alert

        # Opportunistically remove stale markers from prior days (best-effort).
        try:
            today_flag = os.path.basename(alert_marker)
            for stale in glob.glob(os.path.join(state_dir, "budget-alert-*.flag")):
                if os.path.basename(stale) != today_flag:
                    try:
                        os.remove(stale)
                    except Exception:
                        pass
        except Exception:
            pass

        output = {"hookSpecificOutput": {"hookEventName": "SubagentStop", "additionalContext": msg}}
        sys.stdout.write(json.dumps(output) + "\n")
    except Exception as e:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
        _log_fail("budget_alert", -1, str(e), ctx.session_id)


# ── Stage 15: incident record (fail-CLOSED redaction) ────────────────────────
def stage15_incident_record(ctx: Ctx) -> None:
    """Incident capture (incident-record L47-222). PATH1: debugger + Status DONE/
    DONE_WITH_CONCERNS. PATH2 (only if PATH1 did not insert): ANY agent with Status
    BLOCKED or a ^BLOCKER verdict line. Summaries are redacted FAIL-CLOSED — a
    redaction failure stores ``[REDACTION_FAILED]``, never raw response text.
    ``surfaced_by`` (the agent enum) is a bound param and deliberately NOT redacted.
    """
    if not ctx.db_present:
        return
    response_text = ctx.response_text or ""
    if not response_text.strip():
        return

    agent_type = ctx.agent_name or "unknown"
    # Stripped text for MATCHING ONLY (drops markdown emphasis padding); the original
    # response_text is always used for summary extraction.
    stripped_text = re.sub(r"[*_]{1,3}", "", response_text)
    handoff_m = re.search(r"## Handoff\s*\n([\s\S]+?)(?=\n## |\Z)", response_text)

    related_files = "[]"
    if handoff_m:
        fc_m = re.search(r"files_changed:\s*(.+)", handoff_m.group(1))
        if fc_m:
            related_files = fc_m.group(1).strip()

    related_commit = ""
    try:
        r = subprocess.run(["git", "log", "-1", "--format=%H"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            related_commit = r.stdout.strip()
    except Exception:
        related_commit = ""

    def _do_insert(problem_summary: str, fix_summary: str, surfaced_by: str) -> None:
        """Redact summaries (fail-closed) and insert one incidents row (bound params)."""
        import uuid as _uuid

        p_sum = _redact_fail_closed(problem_summary)
        f_sum = _redact_fail_closed(fix_summary)
        occurred_at = ctx.ts_iso
        c = None
        try:
            c = sqlite3.connect(ctx.db_path, timeout=5)
            c.execute(
                "INSERT INTO incidents (id, occurred_at, problem_summary, fix_summary, related_files, related_commit, resolution_status, surfaced_by) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (str(_uuid.uuid4()), occurred_at, p_sum, f_sum, related_files, related_commit, "open", surfaced_by),
            )
            c.commit()
            c.close()
        except Exception as e:
            try:
                if c:
                    c.close()
            except Exception:
                pass
            _log_fail("incident_insert", -1, str(e), ctx.session_id)

    inserted = False

    # PATH 1: debugger + Status DONE/DONE_WITH_CONCERNS (evaluated first).
    if agent_type == "debugger" and re.search(r"Status:\s*(DONE|DONE_WITH_CONCERNS)", stripped_text):
        m = re.search(r"Summary:\s*(.+)", response_text)
        problem_summary = m.group(1).strip()[:500] if m else " ".join(response_text.split())[:200]
        if not problem_summary:
            problem_summary = "(no summary)"
        fix_summary = handoff_m.group(1).strip()[:1000] if handoff_m else response_text[-1000:].strip()
        _do_insert(problem_summary, fix_summary, "debugger")
        inserted = True

    # PATH 2: BLOCKED / ^BLOCKER verdict — any agent (only if PATH 1 did not insert).
    if not inserted:
        is_blocked = bool(re.search(r"Status:\s*BLOCKED", stripped_text))
        # Broad ^BLOCKER line anchor is intentional (the F3 review-verdict convention).
        blocker_match = re.search(r"^\s*BLOCKER\b(.*)", stripped_text, re.MULTILINE)
        if is_blocked or blocker_match:
            if blocker_match:
                blocker_content = blocker_match.group(1).strip()
                base_summary = blocker_content if blocker_content else "(blocker)"
            else:
                sm = re.search(r"Summary:\s*(.+)", response_text)
                if sm:
                    base_summary = sm.group(1).strip()[:500]
                else:
                    base_summary = " ".join(response_text.split())[:200] or "(no summary)"
            problem_summary = f"[{agent_type} BLOCKED] {base_summary}"[:500]
            fix_summary = handoff_m.group(1).strip()[:1000] if handoff_m else ""
            _do_insert(problem_summary, fix_summary, agent_type)


# ── Stage 16: compressed hookSpecificOutput (LAST) ───────────────────────────
def stage16_compressed_output(ctx: Ctx) -> None:
    """Compressed hookSpecificOutput (hook L1249-1322). Emits ONE JSON object with
    the agent's Status + a redacted Summary + a redacted Concerns list. In-process
    redaction is FAIL-OPEN here (advisory context; matches the original passthrough).
    Emitted LAST before the stage-17 tail sentinel — one valid JSON object per line.
    """
    text = ctx.response_text or ""
    if not text.strip():
        return

    # Summary line
    m = re.search(r"Summary:\s*(.+)", text)
    summary = m.group(1).strip() if m else ""

    # Concerns list (from a Concern(s): block up to the next heading / Status line)
    concerns: List[str] = []
    cm = re.search(r"Concerns?:(.*?)(?=\n#|\n##|\nStatus:|$)", text, re.DOTALL | re.IGNORECASE)
    if cm:
        for line in cm.group(1).splitlines():
            line = line.strip().lstrip("- ").strip()
            if line:
                concerns.append(line)

    # In-process redaction — fail-OPEN (keep the original on any failure).
    _rs = redact_excerpt(summary)
    summary = _rs if _rs is not None else summary
    concerns_json = json.dumps(concerns)
    _rc = redact_excerpt(concerns_json)
    if _rc is not None:
        try:
            parsed = json.loads(_rc)
            if isinstance(parsed, list):
                concerns = parsed
        except Exception:
            pass

    # Status — longest-first alternation; leading/trailing emphasis tolerated.
    # Derived from module-level _STATUS_RE via _STATUS_RE_TRAILING (adds trailing [*_]{0,2}).
    sm = _STATUS_RE_TRAILING.search(text)
    status = sm.group(1) if sm else "UNKNOWN"

    compressed = {"status": status, "summary": summary, "concerns": concerns}
    output = {
        "hookSpecificOutput": {
            "hookEventName": "SubagentStop",
            "additionalContext": json.dumps(compressed),
        }
    }
    sys.stdout.write(json.dumps(output) + "\n")


# ── Stage 17: tail-var emission for the bash wrapper ─────────────────────────
def stage17_tail(ctx: Ctx) -> None:
    """Emit a sentinel-delimited block of shlex-quoted vars for the wrapper to eval.

    The wrapper evals ONLY the block between __CAST_TAIL_BEGIN__/__CAST_TAIL_END__.
    Every value is shlex.quote()'d — the eval downstream is safe ONLY because of that
    (arbitrary agent output flows into CAST_GATE_MATCH / CAST_SUCCESSORS). Removing the
    quoting would open a shell-injection path.
    """
    lines = [
        "__CAST_TAIL_BEGIN__",
        "CAST_GATE_MATCH=" + shlex.quote(ctx.gate_match or ""),
        "CAST_SUCCESSORS=" + shlex.quote("\n".join(ctx.successors)),
        "SAFE_AGENT=" + shlex.quote(ctx.safe_agent or ""),
        "SAFE_SESSION_ID=" + shlex.quote(ctx.safe_session_id or ""),
        "__CAST_TAIL_END__",
    ]
    sys.stdout.write("\n".join(lines) + "\n")


def main() -> int:
    ctx = parse_input()
    if ctx is None:
        return 0
    # Precondition guard (hook line 307): refuse telemetry for a main-session Stop —
    # SubagentStop always carries a raw agent_id or agent_name in the payload.
    # ctx.agent_name is never falsy (coalesces to "unknown"), so we gate on
    # ctx.has_agent_identity which captures raw_name or agent_id BEFORE coalescing.
    if not ctx.has_agent_identity:
        return 0

    run_stage("stage0_fast_write", stage0_fast_write, ctx)
    run_stage("stage1_event_file", stage1_event_file, ctx)
    run_stage("stage2_transcript_cost", stage2_transcript_cost, ctx)
    run_stage("stage3_dispatch_decisions", stage3_dispatch_decisions, ctx)
    run_stage("stage4_truncation_record", stage4_truncation_record, ctx)
    run_stage("stage5_completeness", stage5_completeness, ctx)
    run_stage("stage6_handoff_validation", stage6_handoff_validation, ctx)
    run_stage("stage7_protocol_check", stage7_protocol_check, ctx)
    run_stage("stage8_quality_gate", stage8_quality_gate, ctx)
    run_stage("stage9_claimed_work", stage9_claimed_work, ctx)
    run_stage("stage10_facts_write", stage10_facts_write, ctx)
    run_stage("stage11_turn_ceiling", stage11_turn_ceiling, ctx)
    run_stage("stage12_truncation_files", stage12_truncation_files, ctx)
    run_stage("stage13_duration_p95", stage13_duration_p95, ctx)
    run_stage("stage14_budget_alert", stage14_budget_alert, ctx)
    run_stage("stage15_incident_record", stage15_incident_record, ctx)
    run_stage("stage16_compressed_output", stage16_compressed_output, ctx)
    run_stage("stage17_tail", stage17_tail, ctx)
    return 0


if __name__ == "__main__":
    sys.exit(main())
