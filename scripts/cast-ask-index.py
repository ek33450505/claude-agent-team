#!/usr/bin/env python3
"""cast-ask-index.py — populate record_fts from cast.db text sources.

Usage:
    cast-ask-index.py [--rebuild] [--kind <k>] [--db <path>]

Options:
    --rebuild       Full reindex. Clears record_fts first, scoped to --kind when one is
                    given, or all kinds when it is not. (Also clears record_embed, under the
                    same scoping, only when --embed is passed.)
    --kind <k>      Only index this kind (agent_run, incident, dispatch, memory, plan,
                    hatch, journal, transcript, distillate)
    --db <path>     Override CAST_DB_PATH for this run

Exit codes: 0 = success, 1 = error
Per-source failures are logged to stderr; one bad source does not abort the rest.
"""

import argparse
import datetime
import glob
import importlib.util
import json
import os
import re
import sys
from typing import Any, Callable, Dict, List, Optional

# --- DB import (match existing scripts pattern) ---
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cast_db  # type: ignore


def _load_embed_module():
    """Lazy-load cast-memory-embed.py (hyphenated filename → importlib). Returns module or None on any failure (fail-open)."""
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cast-memory-embed.py')
        spec = importlib.util.spec_from_file_location('cast_memory_embed', path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MAX_BODY = 4_000       # chars — bounds large DB rows
MAX_FILE_BODY = 8_000  # chars per chunk — files are split into chunks for full-content indexing
MAX_EMBED_INPUT = 8_000  # chars fed to the embedder (nomic context safety)


# ---------------------------------------------------------------------------
# Chrome marker filtering (mirrored from cast-session-distiller.py)
# Harness/command chrome markers — turns containing these are not user prose
# ---------------------------------------------------------------------------

_CHROME_MARKERS = [
    '<command-name>',
    '<command-message>',
    '<command-args>',
    '<local-command-stdout>',
    '<local-command-caveat>',
    '<system-reminder>',
    '<bash-stdout>',
    '<bash-stderr>',
]

_DATE_STEM_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


def _is_chrome(text: str) -> bool:
    """Return True if text contains harness/command chrome markers."""
    lower = text.lower()
    for marker in _CHROME_MARKERS:
        if marker in lower:
            return True
    if text.strip().startswith('Caveat:'):
        return True
    return False


# ---------------------------------------------------------------------------
# Root resolvers for file-based sources
# ---------------------------------------------------------------------------


def _get_journal_root() -> str:
    """Resolve journal root. Honors CAST_JOURNAL_DIR env var for test isolation."""
    override = os.environ.get('CAST_JOURNAL_DIR', '')
    if override:
        real = os.path.realpath(override)
        if not os.path.isdir(real):
            raise ValueError(f'CAST_JOURNAL_DIR is not a directory: {override!r}')
        return real
    return os.path.expanduser('~/Documents/Claude')


def _get_projects_root() -> str:
    """Resolve ~/.claude/projects root. Mirrors cast-memory-dream.py's get_projects_root().
    Honors CLAUDE_PROJECTS_DIR env var for test isolation."""
    override = os.environ.get('CLAUDE_PROJECTS_DIR', '')
    if override:
        real = os.path.realpath(override)
        if not os.path.isdir(real):
            raise ValueError(f'CLAUDE_PROJECTS_DIR is not a directory: {override!r}')
        return real
    return os.path.expanduser('~/.claude/projects')


def _get_resume_prompts_dir() -> str:
    """Resolve the resume-distillate dir. Honors CAST_RESUME_PROMPTS_DIR for test isolation."""
    override = os.environ.get('CAST_RESUME_PROMPTS_DIR', '')
    if override:
        real = os.path.realpath(override)
        if not os.path.isdir(real):
            raise ValueError(f'CAST_RESUME_PROMPTS_DIR is not a directory: {override!r}')
        return real
    return os.path.expanduser('~/.claude/resume-prompts')


# ---------------------------------------------------------------------------
# Body parsers for file-based sources
# ---------------------------------------------------------------------------


def _parse_journal_body(path: str) -> str:
    """Read full markdown journal file content (verbatim, no redaction)."""
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


def _parse_transcript_body(path: str) -> str:
    """Extract text content from a JSONL transcript file (user + assistant turns).

    Preserves file order (user and assistant interleaved). Extends
    cast-session-distiller.py's parse_user_prose logic to assistant turns.
    Not imported because the module name contains a hyphen.
    Tolerates a partially-written last line via per-line try/except.

    Extraction rules:
    - type=='user'      + content is str  → keep (user prompts)
    - type=='user'      + content is list → skip (tool_result turns)
    - type=='assistant' + content is list → extract text-typed blocks only;
      skip tool_use / thinking blocks
    - type=='assistant' + content is str  → keep
    - isMeta / isSidechain                → always skip
    - chrome markers                      → skip
    """
    parts: List[str] = []
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue  # tolerate partially-written last line
                if not isinstance(obj, dict):
                    continue
                turn_type = obj.get('type')
                if turn_type not in ('user', 'assistant'):
                    continue
                if obj.get('isMeta') or obj.get('isSidechain'):
                    continue
                msg = obj.get('message', {})
                if not isinstance(msg, dict):
                    continue
                content = msg.get('content', '')

                if turn_type == 'user':
                    # tool_result turns carry a list for content — skip entirely
                    if isinstance(content, list):
                        continue
                    if not isinstance(content, str):
                        continue
                    text = content.strip()
                    if text and not _is_chrome(text):
                        parts.append(text)

                else:  # turn_type == 'assistant'
                    if isinstance(content, list):
                        # Extract only text-typed blocks; skip tool_use, thinking, etc.
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text = block.get('text', '').strip()
                                if text and not _is_chrome(text):
                                    parts.append(text)
                    elif isinstance(content, str):
                        text = content.strip()
                        if text and not _is_chrome(text):
                            parts.append(text)

    except OSError:
        return ''
    return ' '.join(parts)


# ---------------------------------------------------------------------------
# File timestamp and title helpers
# ---------------------------------------------------------------------------


def _derive_file_ts(path: str, ts_strategy: str) -> str:
    """Derive an ISO timestamp string for a file."""
    if ts_strategy == 'stem_date':
        stem = os.path.splitext(os.path.basename(path))[0]
        if _DATE_STEM_RE.match(stem):
            return stem  # YYYY-MM-DD — valid ISO date; used directly
        # Fallback to mtime if stem is not a plain date
    mtime = os.path.getmtime(path)
    return datetime.datetime.fromtimestamp(mtime, tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _derive_file_title(path: str, title_strategy: str) -> str:
    """Derive a human-readable title for a file."""
    stem = os.path.splitext(os.path.basename(path))[0]
    if title_strategy == 'stem':
        return stem
    if title_strategy == 'project_stem':
        # project dirs are dash-encoded absolute paths (Claude Code convention):
        # the leading slash and each path separator become dashes; use the raw encoded name as-is
        project_dir = os.path.basename(os.path.dirname(path))
        return f'{project_dir} · {stem}'
    return stem


# ---------------------------------------------------------------------------
# FILE_SOURCES config — parallel to SOURCES but for file-based kinds.
# Each entry drives _index_file_source for one kind.
# Fields:
#   kind          — kind tag stored in record_fts
#   root_resolver — callable() -> str (raises ValueError on bad config)
#   glob_pattern  — glob relative to the root (non-recursive by convention)
#   ts_strategy   — 'stem_date' or 'mtime'
#   title_strategy— 'stem' or 'project_stem'
#   parse         — callable(path: str) -> str body extractor
# ---------------------------------------------------------------------------

FILE_SOURCES: List[Dict[str, Any]] = [
    {
        'kind': 'journal',
        'root_resolver': _get_journal_root,
        'glob_pattern': '*/*.md',       # layout: YYYY-MM/YYYY-MM-DD.md
        'ts_strategy': 'stem_date',
        'title_strategy': 'stem',
        'parse': _parse_journal_body,
    },
    {
        'kind': 'transcript',
        'root_resolver': _get_projects_root,
        'glob_pattern': '*/*.jsonl',    # top-level per-project dir; NOT recursive
        'ts_strategy': 'mtime',
        'title_strategy': 'project_stem',
        'parse': _parse_transcript_body,
    },
    {
        'kind': 'distillate',
        'root_resolver': _get_resume_prompts_dir,
        'glob_pattern': '*.md',         # flat dir — stems like 2026-07-06-foo-auto; NOT recursive
        'ts_strategy': 'mtime',         # stems are '<date>-<repo>-auto', not plain dates; mtime is correct
        'title_strategy': 'stem',
        'parse': _parse_journal_body,   # generic verbatim md reader — reuse, do not duplicate
    },
]


# ---------------------------------------------------------------------------
# SOURCES config
# Each entry drives the incremental-index logic for one kind.
# ---------------------------------------------------------------------------

SOURCES: List[Dict[str, Any]] = [
    {
        "kind": "agent_run",
        "table": "agent_runs",
        "ref_id_col": "id",
        "ts_col": "COALESCE(ended_at, started_at)",
        "title_expr": "agent || ' · ' || COALESCE(status, '')",
        "body_parts": ["response"],
    },
    {
        "kind": "incident",
        "table": "incidents",
        "ref_id_col": "id",
        "ts_col": "occurred_at",
        "title_expr": "substr(problem_summary, 1, 80)",
        "body_parts": ["problem_summary", "fix_summary"],
    },
    {
        "kind": "dispatch",
        "table": "dispatch_decisions",
        "ref_id_col": "id",
        "ts_col": "created_at",
        "title_expr": "chosen_agent || ' · ' || outcome",
        "body_parts": ["prompt_snippet", "outcome", "chosen_agent"],
    },
    {
        "kind": "memory",
        "table": "agent_memories",
        "ref_id_col": "id",
        "ts_col": "COALESCE(updated_at, created_at)",
        "title_expr": "name",
        "body_parts": ["name", "description", "content"],
        "meta_cols": {"agent": "agent", "project": "project", "mtype": "type"},
    },
    {
        "kind": "plan",
        "table": "plan_sessions",
        "ref_id_col": "id",
        "ts_col": "started_at",
        "title_expr": "plan_file",  # basename extracted in Python
        "body_parts": ["plan_file"],
    },
    {
        # ack_events records escape-hatch uses (scripts/cast-git-guard.py,
        # scripts/cast-neon.sh). created_at is SQLite datetime('now') SPACE-format
        # ("YYYY-MM-DD HH:MM:SS") per migration 034 — NOT the ISO-T/Z format
        # agent_runs uses. _get_high_water() is scoped per-kind (WHERE kind = ?),
        # so the hatch high-water mark only ever compares against its own
        # space-format values and never cross-contaminates with ISO-T/Z kinds.
        # repo/script can be empty string (not NULL) for hook invocations with no
        # repo context — NULLIF(..., '') covers that before COALESCE falls back.
        "kind": "hatch",
        "table": "ack_events",
        "ref_id_col": "id",
        "ts_col": "created_at",
        "title_expr": (
            "variable || ' · ' || "
            "COALESCE(NULLIF(repo, ''), '(no repo)') || ' · ' || "
            "COALESCE(NULLIF(script, ''), '(no script)')"
        ),
        "body_parts": ["variable", "value", "script", "repo"],
    },
]


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def _row_to_dict(row: Any) -> Dict[str, Any]:
    """Convert sqlite3.Row (or dict) to plain dict."""
    if isinstance(row, dict):
        return row
    # sqlite3.Row supports keys()
    if hasattr(row, "keys"):
        return dict(row)
    # Fallback: shouldn't happen with cast_db
    return {}


def _concat_body(row: Dict[str, Any], parts: List[str]) -> str:
    """Space-join non-NULL, non-empty body parts; truncate to MAX_BODY."""
    pieces: List[str] = []
    for p in parts:
        val = row.get(p)
        if val is not None and str(val).strip():
            pieces.append(str(val))
    return " ".join(pieces)[:MAX_BODY]


def _get_high_water(kind: str) -> Optional[str]:
    """Return max ts from record_fts for this kind, or None if no rows."""
    rows = cast_db.db_query(
        "SELECT max(ts) AS hw FROM record_fts WHERE kind = ?", (kind,)
    )
    if rows:
        row = _row_to_dict(rows[0])
        hw = row.get("hw")
        return hw if hw else None
    return None


def _record_fts_columns() -> set:
    """Return the set of record_fts column names, or empty set if the table is absent."""
    rows = cast_db.db_query("PRAGMA table_info(record_fts)", ())
    if not rows:
        return set()
    return {str(_row_to_dict(r).get("name") or "") for r in rows}


def _upsert_row(kind: str, ref_id: str, ts: str, title: str, body: str,
                agent: str = "", project: str = "", mtype: str = "") -> None:
    """Delete-then-insert to keep record_fts deduplicated on (kind, ref_id).

    agent/project/mtype are UNINDEXED filter columns (populated for memory rows; empty otherwise).
    """
    cast_db.db_execute(
        "DELETE FROM record_fts WHERE kind = ? AND ref_id = ?", (kind, ref_id)
    )
    cast_db.db_execute(
        "INSERT INTO record_fts(kind, ref_id, ts, title, body, agent, project, mtype) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (kind, ref_id, ts, title, body, agent, project, mtype),
    )


def _index_source(src: Dict[str, Any], rebuild: bool) -> int:
    """Index one SQL source; return count of rows inserted."""
    kind = src["kind"]
    table = src["table"]
    ref_id_col = src["ref_id_col"]
    ts_col = src["ts_col"]
    title_expr = src["title_expr"]
    body_parts: List[str] = src["body_parts"]

    high_water: Optional[str] = None
    if not rebuild:
        high_water = _get_high_water(kind)

    # SQL identifiers (table, ref_id_col, body columns) are validated to honor cast_db's
    # own guard, even though SOURCES is a hardcoded constant today. ts_col and title_expr
    # are TRUSTED SQL EXPRESSION LITERALS (e.g. "COALESCE(ended_at, started_at)") — they
    # must remain hardcoded in SOURCES; never source them from config files or user input.
    cast_db._validate_identifier(table)
    cast_db._validate_identifier(ref_id_col)
    for _col in body_parts:
        cast_db._validate_identifier(_col)

    meta_cols: Dict[str, str] = src.get("meta_cols", {})
    for _fts_col, _src_col in meta_cols.items():
        cast_db._validate_identifier(_fts_col)
        cast_db._validate_identifier(_src_col)

    # Build SELECT — ts/title evaluated in SQL; body parts capped at the SQL level via
    # SUBSTR so large rows (e.g. agent_runs.response) are never fully loaded into memory.
    body_selects = ", ".join(
        f"CAST(SUBSTR({col}, 1, {MAX_BODY + 1}) AS TEXT) AS {col}" for col in body_parts
    )
    meta_selects = "".join(
        f", CAST({_src_col} AS TEXT) AS {_fts_col}" for _fts_col, _src_col in meta_cols.items()
    )
    select_sql = (
        f"SELECT CAST({ref_id_col} AS TEXT) AS ref_id, "
        f"({ts_col}) AS ts, "
        f"({title_expr}) AS title, "
        f"{body_selects}"
        f"{meta_selects} "
        f"FROM {table}"
    )

    params: tuple = ()
    if high_water:
        # >= (not >) so rows sharing the boundary timestamp are never skipped; the
        # delete-then-insert upsert keeps this idempotent (boundary rows re-index without
        # duplicating). Empty high_water is treated as None above → first run indexes all.
        select_sql += f" WHERE ({ts_col}) >= ?"
        params = (high_water,)

    rows = cast_db.db_query(select_sql, params)
    count = 0
    for raw_row in rows:
        row = _row_to_dict(raw_row)

        ref_id = str(row.get("ref_id") or "")
        if not ref_id.strip():
            continue  # skip rows with no ref_id — cannot dedup on (kind, ref_id)
        ts_val = str(row.get("ts") or "")
        title_val = str(row.get("title") or "")

        # plan kind: extract basename from plan_file path
        if kind == "plan" and title_val:
            title_val = os.path.basename(title_val)

        body_val = _concat_body(row, body_parts)

        if not body_val.strip():
            continue  # skip rows whose body is entirely NULL/empty after concat

        _upsert_row(
            kind, ref_id, ts_val, title_val, body_val,
            agent=str(row.get("agent") or ""),
            project=str(row.get("project") or ""),
            mtype=str(row.get("mtype") or ""),
        )
        count += 1

    return count


def _chunk(text: str, size: int) -> List[str]:
    """Split text into chunks of at most `size` chars."""
    return [text[i:i + size] for i in range(0, len(text), size)]


def _index_file_source(src: Dict[str, Any], rebuild: bool) -> int:
    """Index one file-based source; return count of chunk-rows inserted.

    Mirrors _index_source's contract:
    - Uses _get_high_water / _upsert_row for consistency.
    - Skips files whose ts < high_water on incremental runs (tie-safe: indexes ts >= hw).
    - Chunks large files at MAX_FILE_BODY chars per chunk so full content is searchable.
      ref_id per chunk = "<path>#<i>"; all chunks share the file's ts.
    - Before inserting, deletes ALL existing chunks for the file via a range predicate
      over ref_id (`<path>#<int>`) so a shrunk/modified file leaves no orphaned high-index chunks.
    - Per-file try/except: one corrupt file does not abort the whole source.
    """
    kind: str = src['kind']
    root_resolver: Callable[[], str] = src['root_resolver']
    glob_pattern: str = src['glob_pattern']
    ts_strategy: str = src['ts_strategy']
    title_strategy: str = src['title_strategy']
    parse: Callable[[str], str] = src['parse']

    root = root_resolver()  # raises ValueError on bad config — caught by caller
    pattern = os.path.join(root, glob_pattern)
    paths = sorted(glob.glob(pattern))

    high_water: Optional[str] = None
    if not rebuild:
        high_water = _get_high_water(kind)

    count = 0
    for path in paths:
        try:
            ts = _derive_file_ts(path, ts_strategy)

            # Incremental skip: index ts >= high_water (tie-safe, same convention as SQL path)
            if high_water and ts < high_water:
                continue

            title = _derive_file_title(path, title_strategy)
            body = parse(path)

            if not body or not body.strip():
                continue  # skip files with no extractable content

            chunks = _chunk(body, MAX_FILE_BODY)
            n_chunks = len(chunks)

            # Delete ALL existing chunks for this file before re-inserting so a
            # shrunk/modified file leaves no orphaned high-index chunks.
            # Range predicate (not GLOB/LIKE) so filesystem paths containing SQLite glob
            # metacharacters (* ? [) can never over- or under-delete other files' chunks.
            # All chunk ref_ids are "<path>#<int>"; '#'..'#\U0010ffff' bounds every suffix.
            cast_db.db_execute(
                "DELETE FROM record_fts WHERE kind = ? AND ref_id >= ? AND ref_id < ?",
                (kind, path + '#', path + '#\U0010ffff'),
            )

            for i, chunk_body in enumerate(chunks):
                if not chunk_body.strip():
                    continue
                chunk_ref_id = f'{path}#{i}'
                chunk_title = title if n_chunks == 1 else f'{title} [{i + 1}/{n_chunks}]'
                _upsert_row(kind, chunk_ref_id, ts, chunk_title, chunk_body)
                count += 1

        except Exception as exc:
            print(f"ERROR indexing file {path} (kind={kind}): {exc}", file=sys.stderr)
            # continue with remaining files — one bad file must not abort the source

    return count


def _embed_pending(rebuild: bool, kind: Optional[str] = None) -> int:
    """Populate record_embed for record_fts rows lacking an embedding. Opt-in (--embed); fail-open.

    Reuses cast-memory-embed.py (embed_text + pack_embedding). Ollama down / module missing →
    embeds 0 rows, prints an advisory to stderr, returns 0 (never raises). Incremental: only rows
    missing from record_embed, keyed on (kind, ref_id). rebuild=True clears record_embed first.
    """
    cme = _load_embed_module()
    if cme is None:
        print("embed: cast-memory-embed.py unavailable — semantic layer skipped", file=sys.stderr)
        return 0

    if rebuild:
        # Same scoping rule as the record_fts clear in main() — a --kind rebuild
        # must not discard every other kind's embeddings, which are expensive to
        # recompute and are NOT restored by this run.
        if kind:
            cast_db.db_execute("DELETE FROM record_embed WHERE kind = ?", (kind,))
        else:
            cast_db.db_execute("DELETE FROM record_embed", ())

    rows = cast_db.db_query(
        "SELECT f.kind AS kind, f.ref_id AS ref_id, f.ts AS ts, f.title AS title, f.body AS body "
        "FROM record_fts f "
        "WHERE NOT EXISTS (SELECT 1 FROM record_embed e WHERE e.kind = f.kind AND e.ref_id = f.ref_id)",
        (),
    )
    embedded = 0
    skipped = 0
    for raw in rows:
        row = _row_to_dict(raw)
        kind = str(row.get("kind") or "")
        ref_id = str(row.get("ref_id") or "")
        if not kind or not ref_id:
            continue
        ts = str(row.get("ts") or "")
        text = (str(row.get("title") or "") + " " + str(row.get("body") or "")).strip()[:MAX_EMBED_INPUT]
        if not text:
            continue
        vec = cme.embed_text(text)
        if vec is None:
            skipped += 1
            continue
        blob = cme.pack_embedding(vec)
        cast_db.db_execute(
            "INSERT OR REPLACE INTO record_embed(kind, ref_id, vec, ts) VALUES (?, ?, ?, ?)",
            (kind, ref_id, blob, ts),
        )
        embedded += 1
    if skipped and embedded == 0:
        print(f"embed: 0 embedded, {skipped} skipped (Ollama unavailable?)", file=sys.stderr)
    return embedded


def main() -> int:
    all_kinds = [s["kind"] for s in SOURCES] + [s["kind"] for s in FILE_SOURCES]
    parser = argparse.ArgumentParser(
        description="Populate record_fts from cast.db sources."
    )
    parser.add_argument(
        "--rebuild", action="store_true",
        help="Full reindex: clear record_fts first, scoped to --kind when given",
    )
    parser.add_argument(
        "--kind", metavar="K",
        help=f"Only index this kind ({', '.join(all_kinds)})",
    )
    parser.add_argument(
        "--db", metavar="PATH",
        help="Override CAST_DB_PATH for this run",
    )
    parser.add_argument(
        "--embed", action="store_true",
        help="Also populate record_embed (semantic sidecar) via Ollama; opt-in, fail-open if Ollama is down",
    )
    args = parser.parse_args()

    # Apply --db override before cast_db is used (CAST_DB_PATH read lazily)
    if args.db:
        os.environ["CAST_DB_PATH"] = args.db

    # Schema-freshness guard: if record_fts EXISTS but lacks the U6 filter columns, the schema is
    # stale (cast-db-init.sh / install.sh hasn't upgraded it). Fail honestly instead of printing
    # false "indexed N" counts while every 8-column INSERT silently no-ops.
    _EXPECTED_FTS_COLS = {"kind", "ref_id", "ts", "title", "body", "agent", "project", "mtype"}
    _fts_cols = _record_fts_columns()
    if _fts_cols and not _EXPECTED_FTS_COLS.issubset(_fts_cols):
        print(
            "cast-ask-index: record_fts schema is stale (missing filter columns). "
            "Run 'bash scripts/cast-db-init.sh' (or install.sh) to upgrade, then re-run with --rebuild.",
            file=sys.stderr,
        )
        return 1

    # Filter both SOURCES and FILE_SOURCES by --kind
    db_sources = SOURCES
    file_sources = FILE_SOURCES
    if args.kind:
        db_sources = [s for s in SOURCES if s["kind"] == args.kind]
        file_sources = [s for s in FILE_SOURCES if s["kind"] == args.kind]
        if not db_sources and not file_sources:
            print(f"Unknown kind: {args.kind!r}. Valid: {all_kinds}", file=sys.stderr)
            return 1

    if args.rebuild:
        # Scope the clear to what is about to be reindexed. Unscoped, this DELETE
        # ran BEFORE --kind was applied, so `--rebuild --kind hatch` destroyed
        # every other kind and then reindexed only `hatch`. Measured live
        # 2026-08-27: 18,162 rows across 8 kinds (agent_run 8,867, dispatch 4,928,
        # transcript 2,719, memory 1,052, incident 252, distillate 209, journal 121,
        # plan 14) stood to be lost to rebuild one of them. The per-file delete in
        # _index_file_source already scoped itself exactly this way; this one never did.
        if args.kind:
            ok = cast_db.db_execute("DELETE FROM record_fts WHERE kind = ?", (args.kind,))
            scope = f"kind={args.kind}"
        else:
            # No --kind: every kind is being reindexed, so an unscoped clear is
            # correct — and it additionally sweeps rows of kinds this version no
            # longer produces, which a per-kind loop would leave orphaned.
            ok = cast_db.db_execute("DELETE FROM record_fts", ())
            scope = "all kinds"
        if not ok:
            print("Failed to clear record_fts for rebuild", file=sys.stderr)
            return 1
        print(f"record_fts cleared for rebuild ({scope})")

    exit_code = 0

    # Index SQL-backed sources
    for src in db_sources:
        try:
            n = _index_source(src, rebuild=args.rebuild)
            print(f"indexed {n} {src['kind']} rows")
        except Exception as exc:
            print(f"ERROR indexing {src['kind']}: {exc}", file=sys.stderr)
            exit_code = 1  # flag error but continue remaining sources

    # Index file-based sources
    for src in file_sources:
        try:
            n = _index_file_source(src, rebuild=args.rebuild)
            print(f"indexed {n} {src['kind']} rows")
        except Exception as exc:
            print(f"ERROR indexing {src['kind']}: {exc}", file=sys.stderr)
            exit_code = 1  # flag error but continue remaining sources

    if args.embed:
        try:
            n_emb = _embed_pending(rebuild=args.rebuild, kind=args.kind)
            print(f"embedded {n_emb} record_embed rows")
        except Exception as exc:
            print(f"ERROR embedding: {exc}", file=sys.stderr)
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
