#!/usr/bin/env python3
"""
cast-memory-facts-write.py — Extract ## Facts blocks from agent responses and persist to agent_memories.

Hardened write logic (2026-06-19 security fix):
- Subagent-asserted confidence is capped at SUBAGENT_CONFIDENCE_CAP (0.8).
  Subagent facts are unverified; capping prevents gaming confidence-weighted ranking.
- Protected memories (last_validated_at IS NOT NULL OR confidence >= 0.9) are never
  overwritten or superseded. A prompt-injected subagent cannot destroy trusted entries.
- Non-destructive supersession for non-protected rows with new content:
    old row: valid_to=now (content preserved for audit/revert)
    new row: inserted with valid_from=now, valid_to=NULL, capped confidence
  Valid_to is NEVER reset to NULL on an existing row.
- Identical-content re-affirm: only bumps updated_at; no new row.

Env vars (set by cast-subagent-stop-hook.sh Step 2.7):
  CAST_STOP_AGENT          — agent name
  CAST_STOP_RESPONSE_TEXT  — full agent response text
  CAST_DB_PATH             — path to cast.db (CAST convention)
  CAST_PROJECT_ROOT        — repo root path (used to derive project name)

Exit: 0 always (observability feature, fail-safe — hook pipeline must not break).
Stderr: [CAST-MEMORY] summary lines.
"""

import os
import sys
import re
import sqlite3
from datetime import datetime, timezone

# ── Constants ─────────────────────────────────────────────────────────────────

# Confidence ceiling for subagent-asserted facts (unverified; prevents injection gaming)
SUBAGENT_CONFIDENCE_CAP: float = 0.8

# Maximum facts consumed per agent response
MAX_FACTS: int = 5

# Allowed memory types (mirrors cast-memory-router.py VALID_TYPES)
VALID_TYPES = {'user', 'feedback', 'project', 'reference', 'procedural', 'user_profile'}

# Slug pattern: name field must match this to be accepted
SLUG_RE = re.compile(r'^[a-zA-Z0-9_-]{1,80}$')

# ── Helpers ───────────────────────────────────────────────────────────────────


def _log_error(msg: str) -> None:
    """Append an error line to ~/.claude/logs/hook-errors.log; never raises."""
    try:
        log_path = os.path.expanduser('~/.claude/logs/hook-errors.log')
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, 'a') as fh:
            fh.write(f"[cast-memory-facts-write] {msg}\n")
    except Exception:
        pass


def _ensure_columns(conn: sqlite3.Connection) -> None:
    """Idempotently add optional columns that may be absent from older schemas."""
    for col, typedef in [
        ('confidence', 'REAL DEFAULT 1.0'),
        ('valid_from', 'TEXT'),
        ('valid_to', 'TEXT'),
        ('last_validated_at', 'TEXT'),
    ]:
        try:
            conn.execute(f'ALTER TABLE agent_memories ADD COLUMN {col} {typedef}')
        except Exception:
            pass  # column already exists or table absent — handled downstream


def _parse_facts_block(facts_block: str) -> list:
    """Parse pipe-delimited fact lines into a list of field dicts.

    Format per line:
      name: <slug> | type: <type> | content: <text> [| confidence: <float>] [| description: <text>]

    Malformed or invalid lines are silently skipped.
    Returns at most MAX_FACTS valid entries.
    """
    results = []
    for line in facts_block.splitlines():
        if len(results) >= MAX_FACTS:
            break
        line = line.strip()
        if not line:
            continue

        fields: dict = {}
        for part in line.split('|'):
            if ':' in part:
                k, _, v = part.strip().partition(':')
                fields[k.strip()] = v.strip()

        name = fields.get('name', '')
        mem_type = fields.get('type', '')
        content = fields.get('content', '')[:500]
        confidence_str = fields.get('confidence', str(SUBAGENT_CONFIDENCE_CAP))

        # Validate required fields
        if not name or not SLUG_RE.match(name):
            continue
        if mem_type not in VALID_TYPES:
            continue
        if not content:
            continue

        # Clamp confidence: subagent-asserted values are unverified
        try:
            claimed = float(confidence_str) if confidence_str else SUBAGENT_CONFIDENCE_CAP
        except ValueError:
            claimed = SUBAGENT_CONFIDENCE_CAP
        confidence = max(0.0, min(claimed, SUBAGENT_CONFIDENCE_CAP))

        results.append({
            'name': name,
            'type': mem_type,
            'content': content,
            'confidence': confidence,
        })

    return results


def _is_protected(confidence: float, last_validated_at) -> bool:
    """Return True if a memory row is protected against subagent overwrite."""
    if last_validated_at is not None:
        return True
    if confidence is not None and float(confidence) >= 0.9:
        return True
    return False


# ── Main ──────────────────────────────────────────────────────────────────────


def main() -> None:
    agent = os.environ.get('CAST_STOP_AGENT', 'unknown')
    response_text = os.environ.get('CAST_STOP_RESPONSE_TEXT', '')
    db_path = os.environ.get('CAST_DB_PATH', '').strip()
    project_root = os.environ.get('CAST_PROJECT_ROOT', '').strip()

    if not response_text or not db_path:
        return

    # Extract ## Facts block (scan from start, stop at next ## heading or EOF)
    facts_match = re.search(r'## Facts\s*\n(.*?)(?=\n##|\Z)', response_text, re.DOTALL)
    if not facts_match:
        return

    facts_block = facts_match.group(1).strip()
    if not facts_block:
        return

    facts = _parse_facts_block(facts_block)
    if not facts:
        return

    db_path_expanded = os.path.expanduser(db_path)
    try:
        # isolation_level=None → autocommit mode; we manage transactions explicitly.
        # timeout=5 makes a concurrent writer wait rather than immediately error.
        conn = sqlite3.connect(db_path_expanded, timeout=5)
        conn.isolation_level = None
        # DDL must run before BEGIN IMMEDIATE (autocommit is fine for schema changes).
        _ensure_columns(conn)
    except Exception as exc:
        _log_error(f"connect failed: {exc}")
        return

    now = datetime.now(timezone.utc).isoformat()
    project = os.path.basename(project_root.rstrip('/')) if project_root else 'unknown'

    wrote = 0
    refused = 0

    try:
        cur = conn.cursor()
        # Serialize SELECT→UPDATE→INSERT: concurrent writers wait at the lock boundary
        # (timeout=5 above) rather than racing past the protection check.
        cur.execute("BEGIN IMMEDIATE")

        for fact in facts:
            name = fact['name']
            mem_type = fact['type']
            content = fact['content']
            confidence = fact['confidence']

            # Look up existing CURRENT row (valid_to IS NULL) for (agent, name)
            cur.execute(
                "SELECT id, content, confidence, last_validated_at "
                "FROM agent_memories "
                "WHERE agent = ? AND name = ? AND valid_to IS NULL "
                "LIMIT 1",
                (agent, name),
            )
            existing = cur.fetchone()

            if existing is not None:
                ex_id, ex_content, ex_confidence, ex_last_validated_at = existing

                # ── Protection check ──────────────────────────────────────
                if _is_protected(ex_confidence, ex_last_validated_at):
                    print(
                        f"[CAST-MEMORY] refused overwrite of trusted memory '{name}' "
                        f"(agent={agent})",
                        file=sys.stderr,
                    )
                    refused += 1
                    continue

                # ── Identical content: bump updated_at only ────────────────
                if ex_content == content:
                    cur.execute(
                        "UPDATE agent_memories SET updated_at = ? WHERE id = ?",
                        (now, ex_id),
                    )
                    wrote += 1
                    continue

                # ── Different content: non-destructive supersession ────────
                # 1. Mark old row superseded (valid_to=now); its content is preserved.
                cur.execute(
                    "UPDATE agent_memories SET valid_to = ? WHERE id = ?",
                    (now, ex_id),
                )
                # 2. Insert new current row (valid_from=now, valid_to=NULL).
                #    last_validated_at left NULL — subagent facts are unverified.
                cur.execute(
                    "INSERT INTO agent_memories "
                    "(agent, project, type, name, description, content, "
                    " created_at, updated_at, confidence, valid_from) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        agent, project, mem_type, name,
                        content[:100], content,
                        now, now, confidence, now,
                    ),
                )
                wrote += 1

            else:
                # ── New (agent, name) → insert with capped confidence ──────
                cur.execute(
                    "INSERT INTO agent_memories "
                    "(agent, project, type, name, description, content, "
                    " created_at, updated_at, confidence, valid_from) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        agent, project, mem_type, name,
                        content[:100], content,
                        now, now, confidence, now,
                    ),
                )
                wrote += 1

        cur.execute("COMMIT")

    except Exception as exc:
        _log_error(f"write failed: {exc}")
        try:
            cur.execute("ROLLBACK")
        except Exception:
            pass
    finally:
        try:
            conn.close()
        except Exception:
            pass

    # Emit summary (only if something happened)
    parts = []
    if wrote > 0:
        parts.append(f"wrote {wrote} facts from {agent}")
    if refused > 0:
        parts.append(f"refused {refused} protected overwrite(s)")
    if parts:
        print(f"[CAST-MEMORY] {', '.join(parts)}", file=sys.stderr)


if __name__ == '__main__':
    main()
