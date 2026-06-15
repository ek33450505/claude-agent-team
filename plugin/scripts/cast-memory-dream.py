#!/usr/bin/env python3
"""
cast-memory-dream.py — 4-phase markdown memory consolidator for CAST.

Phases:
  1. Orient    — Enumerate canonical memory files, compute dir SHA, record run
  2. Gather    — Scan recent session JSONL for correction/preference signals
  3. Consolidate — Apply contradiction policy, fix dates, remove stale refs
  4. Prune     — Write output to _dream-output-<ts>/, rebuild MEMORY.md index

Output: JSON summary to stdout. Never modifies canonical memory/ root.

Usage:
  cast-memory-dream.py [--project-id <id>] [--db <path>] [--instructions "<text>"]
                       [--transcripts-since <ISO-date>] [--max-transcripts N]
                       [--contradiction-policy {flag-for-review,latest-wins}]
                       [--dry-run] [--cancel <run-id>]
"""

import os
import sys
import json
import re
import hashlib
import argparse
import sqlite3
import uuid
from datetime import datetime, timezone, timedelta

# cast_db co-located in scripts/; guarded so CLI still runs on broken installs
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from cast_db import log_hook_failure
except Exception:
    log_hook_failure = None


def _maybe_log_failure(script, code, msg):
    if log_hook_failure:
        try:
            log_hook_failure(script, code, msg)
        except Exception:
            pass


def get_db_path():
    """Resolve cast.db path using same logic as cast_db.py."""
    url = os.environ.get('CAST_DB_URL', '')
    if url.startswith('sqlite:///'):
        return url[len('sqlite:///'):]
    return os.environ.get('CAST_DB_PATH', os.path.expanduser('~/.claude/cast.db'))


def get_projects_root():
    """Resolve ~/.claude/projects root. Honors CLAUDE_PROJECTS_DIR env var for test isolation."""
    override = os.environ.get('CLAUDE_PROJECTS_DIR', '')
    if override:
        real = os.path.realpath(override)
        if not os.path.isdir(real):
            print(
                json.dumps({'error': f'CLAUDE_PROJECTS_DIR is not a directory: {override!r}'}),
                file=sys.stderr,
            )
            sys.exit(1)
        print(f'[cast-memory-dream] CLAUDE_PROJECTS_DIR override active: {real}', file=sys.stderr)
        return real
    return os.path.expanduser('~/.claude/projects')


def resolve_project_dir(project_id):
    """Resolve project_id to an absolute path, guarding against path traversal."""
    root = os.path.realpath(get_projects_root())
    candidate = os.path.realpath(os.path.join(root, project_id))
    if not (candidate == root or candidate.startswith(root + os.sep)):
        print(
            json.dumps({'error': f'project_id escapes projects root: {project_id!r}'}),
            file=sys.stderr,
        )
        sys.exit(1)
    return candidate


# ──────────────────────────────────────────────────────────────────────────────
# Regex patterns for signal extraction
# ──────────────────────────────────────────────────────────────────────────────

SIGNAL_PATTERNS = {
    'corrections': re.compile(
        r'\b(actually|no,|wrong|incorrect|not right|stop doing|don\'t do|I said|I meant|that\'s not|correction)\b',
        re.IGNORECASE
    ),
    'preferences': re.compile(
        r'\b(I prefer|always use|never use|I like|from now on|remember that|make sure to)\b',
        re.IGNORECASE
    ),
    'decisions': re.compile(
        r"\b(let's go with|I decided|we're using|the plan is|switch to|chosen)\b",
        re.IGNORECASE
    ),
    'recurring': re.compile(
        r'\b(again|every time|keep forgetting|as usual|same as before|we always)\b',
        re.IGNORECASE
    ),
}

# Relative date tokens for normalization
RELATIVE_DATE_RE = re.compile(
    r'\b(yesterday|today|tomorrow|last week|next week|last month|next month|'
    r'monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
    re.IGNORECASE
)

# Path reference pattern (mirrored from cast-memory-validate.py)
PATH_REGEX = re.compile(r'(?:^|[\s(\'"](/[^\s\'")\]]+))', re.MULTILINE)


# ──────────────────────────────────────────────────────────────────────────────
# Frontmatter parsing (stdlib only, no yaml)
# ──────────────────────────────────────────────────────────────────────────────

def parse_frontmatter(content):
    """
    Parse YAML-ish frontmatter delimited by ---\\n...\\n---\\n.
    Returns (dict_of_fields, body_text).
    Does NOT use the yaml library — pure string splitting.
    """
    fm = {}
    body = content
    if content.startswith('---\n'):
        parts = content.split('---\n', 2)
        if len(parts) >= 3:
            fm_block = parts[1]
            body = parts[2]
            for line in fm_block.splitlines():
                if ':' in line:
                    key, _, val = line.partition(':')
                    fm[key.strip()] = val.strip()
    return fm, body


# ──────────────────────────────────────────────────────────────────────────────
# DB helpers — every write is an isolated try/except/commit block
# (per feedback_isolate_secondary_writes.md)
# ──────────────────────────────────────────────────────────────────────────────

def db_insert_run(db_path, run_id, project_id, instructions, memory_dir_sha):
    """Insert a new memory_consolidation_runs row with status='running'."""
    now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        conn = sqlite3.connect(db_path, timeout=10)
        conn.execute(
            """INSERT INTO memory_consolidation_runs
               (run_id, project_id, status, instructions, input_fingerprint, started_at, created_at)
               VALUES (?, ?, 'running', ?, ?, ?, ?)""",
            (run_id, project_id, instructions or '', memory_dir_sha, now_iso, now_iso)
        )
        conn.commit()
        conn.close()
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', -1, f'db_insert_run: {e}')


def db_update_run(db_path, run_id, status, output_path=None,
                  memory_files_read=0, transcripts_scanned=0, candidates_written=0,
                  error=None):
    """Update a memory_consolidation_runs row (isolated transaction)."""
    now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        conn = sqlite3.connect(db_path, timeout=10)
        conn.execute(
            """UPDATE memory_consolidation_runs
               SET status=?, output_path=?, completed_at=?,
                   memory_files_read=?, transcripts_scanned=?, candidates_written=?,
                   error=?
               WHERE run_id=?""",
            (status, output_path, now_iso,
             memory_files_read, transcripts_scanned, candidates_written,
             error, run_id)
        )
        conn.commit()
        conn.close()
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', -1, f'db_update_run: {e}')


def db_cancel_run(db_path, run_id):
    """Set status='canceled' for a run (isolated transaction)."""
    try:
        conn = sqlite3.connect(db_path, timeout=10)
        conn.execute(
            "UPDATE memory_consolidation_runs SET status='canceled' WHERE run_id=?",
            (run_id,)
        )
        conn.commit()
        conn.close()
        return True
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', -1, f'db_cancel_run: {e}')
        return False


# ──────────────────────────────────────────────────────────────────────────────
# Phase 1 — Orient
# ──────────────────────────────────────────────────────────────────────────────

def phase_orient(project_id, db_path, run_id, instructions, dry_run):
    """
    Enumerate canonical memory files, compute directory SHA256,
    insert 'running' row into memory_consolidation_runs.

    Returns: list of dicts {path, sha256, frontmatter, body}
    """
    memory_dir = os.path.join(resolve_project_dir(project_id), 'memory')
    if not os.path.isdir(memory_dir):
        raise FileNotFoundError(f'Memory dir not found: {memory_dir}')

    mem_files = []
    for fname in sorted(os.listdir(memory_dir)):
        fpath = os.path.join(memory_dir, fname)
        # Skip non-files, MEMORY.md, and anything in a _dream-output-* subdir
        if not os.path.isfile(fpath):
            continue
        if fname == 'MEMORY.md':
            continue
        if '_dream-output-' in fpath:
            continue
        if not fname.endswith('.md'):
            continue

        try:
            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except Exception:
            continue

        sha = hashlib.sha256(content.encode('utf-8', errors='replace')).hexdigest()
        fm, body = parse_frontmatter(content)
        mem_files.append({
            'path': fpath,
            'sha256': sha,
            'frontmatter': fm,
            'body': body,
            'raw': content,
        })

    # Compute directory-level SHA: SHA256 of sorted (path, sha256) JSON
    dir_pairs = json.dumps(
        sorted((m['path'], m['sha256']) for m in mem_files)
    ).encode('utf-8')
    memory_dir_sha = hashlib.sha256(dir_pairs).hexdigest()

    # Insert running row (isolated transaction)
    if not dry_run:
        db_insert_run(db_path, run_id, project_id, instructions, memory_dir_sha)

    return mem_files, memory_dir_sha


# ──────────────────────────────────────────────────────────────────────────────
# Phase 2 — Gather Signal
# ──────────────────────────────────────────────────────────────────────────────

def phase_gather(project_id, transcripts_since, max_transcripts,
                 instructions, mem_files):
    """
    Scan recent session JSONL for correction/preference/decision/recurring signals.
    Also flag stale path references in existing memory files.

    Returns: (signals list, stale_paths set, transcripts_used list)
    """
    project_dir = resolve_project_dir(project_id)
    now_ts = datetime.now(timezone.utc).timestamp()

    # Resolve --transcripts-since cutoff
    cutoff_ts = None
    if transcripts_since:
        try:
            cutoff_dt = datetime.fromisoformat(transcripts_since)
            if cutoff_dt.tzinfo is None:
                cutoff_dt = cutoff_dt.replace(tzinfo=timezone.utc)
            cutoff_ts = cutoff_dt.timestamp()
        except ValueError:
            pass
    if cutoff_ts is None:
        # Default: 7 days
        cutoff_ts = now_ts - 7 * 86400

    # Find top-level *.jsonl only (no subdir recursion)
    jsonl_files = []
    try:
        for entry in os.scandir(project_dir):
            if entry.is_file() and entry.name.endswith('.jsonl'):
                mtime = entry.stat().st_mtime
                if mtime >= cutoff_ts:
                    jsonl_files.append((mtime, entry.path))
    except (OSError, PermissionError):
        pass

    # Sort by mtime desc, cap at max_transcripts
    jsonl_files.sort(key=lambda x: x[0], reverse=True)
    jsonl_files = jsonl_files[:max_transcripts]

    # Filter by --instructions keywords if provided
    instruction_groups = set()
    if instructions:
        for group in SIGNAL_PATTERNS:
            if group in instructions.lower():
                instruction_groups.add(group)
        # If no group names appear in instructions, match all groups
        if not instruction_groups:
            instruction_groups = set(SIGNAL_PATTERNS.keys())
    else:
        instruction_groups = set(SIGNAL_PATTERNS.keys())

    signals = []
    transcripts_used = []

    for mtime, fpath in jsonl_files:
        file_date = datetime.fromtimestamp(mtime, tz=timezone.utc)
        try:
            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                lines = f.readlines()
        except (OSError, PermissionError):
            continue

        transcripts_used.append(fpath)
        for line_no, line in enumerate(lines, 1):
            line = line.strip()
            if not line:
                continue
            # F5: skip oversized lines to prevent OOM before json.loads
            if len(line) > 1_000_000:
                _maybe_log_failure(
                    'cast-memory-dream', 0,
                    f'phase_gather: skipping oversized line {line_no} ({len(line)} bytes) in {fpath}'
                )
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get('type')
            if msg_type not in ('user', 'assistant'):
                continue

            # Extract text from message.content
            message = obj.get('message', {})
            content = message.get('content', '')
            if isinstance(content, list):
                # Content may be a list of blocks
                text_parts = []
                for block in content:
                    if isinstance(block, dict):
                        text_parts.append(block.get('text', ''))
                    elif isinstance(block, str):
                        text_parts.append(block)
                text = ' '.join(text_parts)
            elif isinstance(content, str):
                text = content
            else:
                continue

            if not text:
                continue

            for group, pattern in SIGNAL_PATTERNS.items():
                if group not in instruction_groups:
                    continue
                match = pattern.search(text)
                if match:
                    snippet = text[max(0, match.start() - 40):match.end() + 80].strip()
                    signals.append({
                        'transcript_path': fpath,
                        'transcript_mtime': mtime,
                        'transcript_date': file_date.strftime('%Y-%m-%d'),
                        'line_no': line_no,
                        'msg_type': msg_type,
                        'snippet': snippet[:300],
                        'pattern_group': group,
                    })

    # Flag stale path references in existing memory files
    stale_paths = set()
    for mem in mem_files:
        refs = PATH_REGEX.findall(mem['raw'])
        for ref in refs:
            if not os.path.exists(ref):
                stale_paths.add(ref)

    return signals, stale_paths, transcripts_used


# ──────────────────────────────────────────────────────────────────────────────
# Phase 3 — Consolidate
# ──────────────────────────────────────────────────────────────────────────────

def _resolve_relative_date(token, anchor_date):
    """
    Resolve a relative date token to an ISO YYYY-MM-DD string.
    anchor_date: datetime object from the source transcript's mtime.
    """
    token_lower = token.lower()
    today = anchor_date.replace(hour=0, minute=0, second=0, microsecond=0)

    if token_lower == 'today':
        return today.strftime('%Y-%m-%d')
    if token_lower == 'yesterday':
        return (today - timedelta(days=1)).strftime('%Y-%m-%d')
    if token_lower == 'tomorrow':
        return (today + timedelta(days=1)).strftime('%Y-%m-%d')
    if token_lower == 'last week':
        return (today - timedelta(weeks=1)).strftime('%Y-%m-%d')
    if token_lower == 'next week':
        return (today + timedelta(weeks=1)).strftime('%Y-%m-%d')
    if token_lower == 'last month':
        return (today - timedelta(days=30)).strftime('%Y-%m-%d')
    if token_lower == 'next month':
        return (today + timedelta(days=30)).strftime('%Y-%m-%d')

    # Weekday names — resolve to the most recent past occurrence
    weekdays = {
        'monday': 0, 'tuesday': 1, 'wednesday': 2, 'thursday': 3,
        'friday': 4, 'saturday': 5, 'sunday': 6
    }
    if token_lower in weekdays:
        target_wd = weekdays[token_lower]
        current_wd = today.weekday()
        days_back = (current_wd - target_wd) % 7
        if days_back == 0:
            days_back = 7  # "Monday" means last Monday, not today
        return (today - timedelta(days=days_back)).strftime('%Y-%m-%d')

    return token  # fallback: leave as-is


def _normalize_dates_in_body(body, anchor_date):
    """
    Replace relative date tokens in body text with ISO dates.
    Uses the SOURCE TRANSCRIPT'S mtime as the anchor (not system clock).
    """
    def replacer(m):
        return _resolve_relative_date(m.group(0), anchor_date)

    return RELATIVE_DATE_RE.sub(replacer, body)


def _remove_stale_path_lines(body, stale_paths):
    """
    Remove lines that contain a stale path reference.
    Returns (cleaned_body, list_of_removed_lines).
    """
    removed = []
    kept = []
    for line in body.splitlines(keepends=True):
        refs = PATH_REGEX.findall(line)
        if any(r in stale_paths for r in refs):
            removed.append(line.rstrip())
        else:
            kept.append(line)
    return ''.join(kept), removed


def phase_consolidate(mem_files, signals, stale_paths, contradiction_policy,
                      output_dir, dry_run):
    """
    For each canonical memory file:
      - Normalize relative dates using the most recent signal's transcript mtime as anchor
      - Remove lines with stale path refs
      - Apply contradiction policy

    Failure modes mitigated by 'flag-for-review' (default):
      - Silent delete (mem0): latest-wins silently discards the prior version
      - Confidence collapse (Letta): always-flag loses nuance when threshold is ambiguous
      - Annotation decay (dream-skill): annotation-appending degrades into noise over time
    flag-for-review avoids all three by keeping both versions visible for human review.

    Returns: list of candidate dicts {path, raw, changed, removed_lines}
    """
    review_entries = []
    changes_log = []
    candidates = []

    # Use most recent signal's date as date-normalization anchor; fallback to now
    if signals:
        newest_signal_mtime = max(s['transcript_mtime'] for s in signals)
        anchor_date = datetime.fromtimestamp(newest_signal_mtime, tz=timezone.utc)
    else:
        anchor_date = datetime.now(timezone.utc)

    # Dedup: keep one entry per frontmatter name slug (highest verified_at wins)
    seen_slugs = {}
    for mem in mem_files:
        slug = mem['frontmatter'].get('name', '')
        if not slug:
            slug = os.path.basename(mem['path'])
        slug_norm = slug.lower()
        if slug_norm in seen_slugs:
            existing = seen_slugs[slug_norm]
            existing_vat = existing['frontmatter'].get('verified_at', '')
            this_vat = mem['frontmatter'].get('verified_at', '')
            if this_vat > existing_vat:
                seen_slugs[slug_norm] = mem
            # else keep existing (higher or equal verified_at)
        else:
            seen_slugs[slug_norm] = mem

    deduped_files = list(seen_slugs.values())

    for mem in deduped_files:
        original_body = mem['body']
        candidate_body = original_body

        # Step 1: Normalize relative dates
        candidate_body = _normalize_dates_in_body(candidate_body, anchor_date)

        # Step 2: Remove stale path ref lines
        candidate_body, removed_lines = _remove_stale_path_lines(candidate_body, stale_paths)
        if removed_lines:
            changes_log.append({
                'file': mem['path'],
                'removed_lines': removed_lines,
            })

        # Step 3: Contradiction detection
        # For each signal, simple heuristic: if signal snippet content overlaps
        # with keywords in the memory body, and they appear to contradict, flag.
        # We match signals that share pattern group with a keyword in the body.
        for sig in signals:
            group = sig['pattern_group']
            snippet = sig['snippet']

            # Only check corrections signals for contradictions
            if group != 'corrections':
                continue

            # Simple heuristic: if the snippet references a keyword present in body
            # and the signal is from a user message, flag as potential contradiction
            if sig['msg_type'] != 'user':
                continue

            # Extract key nouns from snippet (words >4 chars not in stopwords)
            stopwords = {'that', 'this', 'with', 'from', 'they', 'have', 'will',
                         'been', 'were', 'would', 'could', 'should', 'actually',
                         'wrong', 'right', 'doing', 'always', 'never'}
            sig_words = {
                w.lower() for w in re.findall(r'\b\w{5,}\b', snippet)
                if w.lower() not in stopwords
            }
            body_words = {
                w.lower() for w in re.findall(r'\b\w{5,}\b', candidate_body)
                if w.lower() not in stopwords
            }
            overlap = sig_words & body_words

            if not overlap:
                continue

            if contradiction_policy == 'latest-wins':
                # Resolve by session mtime (newer wins); annotate with old snippet
                today_iso = datetime.now(timezone.utc).strftime('%Y-%m-%d')
                annotation = (
                    f'\n<!-- Updated {today_iso}, '
                    f'previously contradicted by signal from {sig["transcript_date"]}: '
                    f'{snippet[:100]} -->'
                )
                candidate_body = candidate_body.rstrip() + annotation + '\n'
            else:
                # flag-for-review (default): preserve both, write to _review_needed.md
                review_entries.append({
                    'memory_file': mem['path'],
                    'memory_slug': mem['frontmatter'].get('name', ''),
                    'current_body_excerpt': candidate_body[:400],
                    'signal_snippet': snippet,
                    'signal_source': sig['transcript_path'],
                    'signal_line': sig['line_no'],
                    'signal_date': sig['transcript_date'],
                    'overlap_keywords': sorted(overlap),
                })

        # Rebuild full file content
        fm = mem['frontmatter']
        if fm:
            fm_lines = '---\n'
            for k, v in fm.items():
                fm_lines += f'{k}: {v}\n'
            fm_lines += '---\n'
            candidate_raw = fm_lines + candidate_body
        else:
            candidate_raw = candidate_body

        changed = (candidate_raw != mem['raw'])
        candidates.append({
            'source_path': mem['path'],
            'filename': os.path.basename(mem['path']),
            'pre_sha256': mem['sha256'],   # SHA256 of canonical file at dream start
            'frontmatter': fm,
            'raw': candidate_raw,
            'changed': changed,
        })

    return candidates, review_entries, changes_log


# ──────────────────────────────────────────────────────────────────────────────
# Phase 4 — Prune & Index
# ──────────────────────────────────────────────────────────────────────────────

def _build_memory_index(candidates):
    """
    Rebuild MEMORY.md content from candidate files.
    Groups by frontmatter 'type'. Caps at 200 lines.
    """
    SECTION_ORDER = ['user', 'goals', 'project', 'reference', 'feedback']
    groups = {s: [] for s in SECTION_ORDER}
    other = []

    for c in candidates:
        fm = c['frontmatter']
        name = fm.get('name', os.path.splitext(c['filename'])[0])
        description = fm.get('description', '')
        mem_type = fm.get('type', '').lower()
        fname = c['filename']
        entry = f'- [{name}]({fname}) — {description}'
        if mem_type in groups:
            groups[mem_type].append(entry)
        else:
            other.append(entry)

    lines = ['# CAST Project Memory\n', '\n']
    section_labels = {
        'user': '## User',
        'goals': '## Goals',
        'project': '## Project',
        'reference': '## References',
        'feedback': '## Feedback',
    }
    for sec in SECTION_ORDER:
        entries = groups[sec]
        if entries:
            lines.append(f'{section_labels[sec]}\n\n')
            for e in entries:
                lines.append(f'{e}\n')
            lines.append('\n')

    if other:
        lines.append('## Other\n\n')
        for e in other:
            lines.append(f'{e}\n')

    # Cap at 200 lines
    if len(lines) > 200:
        hidden = len(lines) - 199
        lines = lines[:199]
        lines.append(f'... {hidden} more entries hidden\n')

    return ''.join(lines)


def phase_prune(candidates, review_entries, changes_log,
                project_id, run_id, memory_dir_sha,
                signals, transcripts_used,
                contradiction_policy, instructions,
                db_path, dry_run):
    """
    Write candidate files to output dir. Rebuild MEMORY.md.
    Write _dream-manifest.json and _changes.md and _review_needed.md.
    Update DB run row.
    Print JSON summary to stdout.
    """
    now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    # Replace colons so directory name is filesystem-safe
    ts_safe = now_iso.replace(':', '')
    output_dir = os.path.join(
        resolve_project_dir(project_id), 'memory', f'_dream-output-{ts_safe}', ''
    )

    # HARD ASSERT: output path must contain _dream-output-
    assert '_dream-output-' in output_dir, (
        f'Safety violation: output_dir does not contain _dream-output-: {output_dir}'
    )

    files_written = []
    files_unchanged = []

    if not dry_run:
        os.makedirs(output_dir, exist_ok=True)

        # Write changed candidate files; note unchanged
        for c in candidates:
            dest = os.path.join(output_dir, c['filename'])
            if c['changed']:
                with open(dest, 'w', encoding='utf-8') as f:
                    f.write(c['raw'])
                # Emit objects with pre_sha256 so promote can SHA-check canonical
                files_written.append({
                    'name': c['filename'],
                    'candidate_path': dest,
                    'canonical_path': c['source_path'],
                    'pre_sha256': c['pre_sha256'],
                })
            else:
                files_unchanged.append({
                    'name': c['filename'],
                    'canonical_path': c['source_path'],
                    'pre_sha256': c['pre_sha256'],
                })

        # Rebuild MEMORY.md in output dir
        memory_index = _build_memory_index(candidates)
        memory_index_path = os.path.join(output_dir, 'MEMORY.md')
        # Compute pre_sha256 of canonical MEMORY.md at dream start
        canonical_memory_md = os.path.join(
            resolve_project_dir(project_id), 'memory', 'MEMORY.md'
        )
        try:
            with open(canonical_memory_md, 'rb') as f:
                memory_md_pre_sha = hashlib.sha256(f.read()).hexdigest()
        except (OSError, FileNotFoundError):
            memory_md_pre_sha = ''
        with open(memory_index_path, 'w', encoding='utf-8') as f:
            f.write(memory_index)
        files_written.append({
            'name': 'MEMORY.md',
            'candidate_path': memory_index_path,
            'canonical_path': canonical_memory_md,
            'pre_sha256': memory_md_pre_sha,
        })

        # Write _review_needed.md if there are contradictions
        review_path = os.path.join(output_dir, '_review_needed.md')
        review_needed_files = []
        if review_entries:
            with open(review_path, 'w', encoding='utf-8') as f:
                f.write('# Review Needed — Contradiction Candidates\n\n')
                f.write(
                    'These entries may contradict canonical memory content.\n'
                    'Both versions are preserved below. Human review required before promote.\n\n'
                )
                for entry in review_entries:
                    f.write(f'## {entry["memory_slug"] or entry["memory_file"]}\n\n')
                    f.write(f'**Memory file:** `{entry["memory_file"]}`\n\n')
                    f.write(f'**Signal source:** `{entry["signal_source"]}` line {entry["signal_line"]}'
                            f' (date: {entry["signal_date"]})\n\n')
                    f.write(f'**Overlap keywords:** {", ".join(entry["overlap_keywords"])}\n\n')
                    f.write('**Current memory excerpt:**\n```\n')
                    f.write(entry['current_body_excerpt'])
                    f.write('\n```\n\n')
                    f.write('**Contradicting signal:**\n```\n')
                    f.write(entry['signal_snippet'])
                    f.write('\n```\n\n---\n\n')
            review_needed_files.append(review_path)

        # Write _changes.md if stale lines were removed
        # (auxiliary file — not tracked in files_written, not promoted)
        if changes_log:
            changes_path = os.path.join(output_dir, '_changes.md')
            with open(changes_path, 'w', encoding='utf-8') as f:
                f.write('# Changes Applied\n\n')
                f.write('## Stale Path References Removed\n\n')
                for entry in changes_log:
                    f.write(f'### `{entry["file"]}`\n\n')
                    for line in entry['removed_lines']:
                        f.write(f'- Removed: `{line}`\n')
                    f.write('\n')

        # Write _dream-manifest.json
        manifest = {
            'run_id': run_id,
            'created_at': now_iso,
            'memory_dir_sha_at_dream_start': memory_dir_sha,
            'files_written': files_written,
            'files_unchanged': files_unchanged,
            'review_needed': review_needed_files,
            'input_transcripts': transcripts_used,
            'contradiction_policy': contradiction_policy,
            'instructions': instructions or '',
        }
        manifest_path = os.path.join(output_dir, '_dream-manifest.json')
        with open(manifest_path, 'w', encoding='utf-8') as f:
            json.dump(manifest, f, indent=2)

        # Update DB run row (isolated transaction)
        db_update_run(
            db_path, run_id, 'completed',
            output_path=output_dir,
            memory_files_read=len(candidates),
            transcripts_scanned=len(transcripts_used),
            candidates_written=len(files_written),
        )
    else:
        # dry-run: compute what would happen without writing
        for c in candidates:
            if c['changed']:
                files_written.append({
                    'name': c['filename'],
                    'candidate_path': f'[dry-run] {c["filename"]}',
                    'canonical_path': c['source_path'],
                    'pre_sha256': c['pre_sha256'],
                })
            else:
                files_unchanged.append({
                    'name': c['filename'],
                    'canonical_path': c['source_path'],
                    'pre_sha256': c['pre_sha256'],
                })

    summary = {
        'run_id': run_id,
        'status': 'dry-run' if dry_run else 'completed',
        'output_dir': output_dir if not dry_run else None,
        'memory_dir_sha': memory_dir_sha,
        'memory_files_read': len(candidates),
        'transcripts_scanned': len(transcripts_used),
        'signals_found': len(signals),
        'files_written': files_written,         # list of {name, pre_sha256, ...} objects
        'files_written_count': len(files_written),
        'files_unchanged': len(files_unchanged),
        'review_needed': len(review_entries),
        'contradiction_policy': contradiction_policy,
        'created_at': now_iso,
    }
    return summary


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def resolve_project_id(explicit_id):
    """
    Resolve project-id. If explicit, use it.
    Otherwise, parse from cwd if it matches the ~/.claude/projects/<id> pattern.
    """
    if explicit_id:
        return explicit_id

    cwd = os.getcwd()
    # Pattern: convert /Users/.../path to -Users-...-path
    # Check if this cwd has a corresponding projects dir
    candidate = cwd.replace('/', '-').lstrip('-')
    projects_root = get_projects_root()
    if os.path.isdir(os.path.join(projects_root, candidate)):
        return candidate

    return None


def main():
    parser = argparse.ArgumentParser(
        description='4-phase markdown memory consolidator for CAST.'
    )
    parser.add_argument('--project-id', help='CAST project ID (e.g. -Users-ed-Projects-...)')
    parser.add_argument('--db', help='Path to cast.db (overrides CAST_DB_PATH)')
    parser.add_argument('--instructions', default='',
                        help='Focus instructions (max 4096 chars); keyword filter for signal extraction')
    parser.add_argument('--transcripts-since', metavar='ISO-DATE',
                        help='Only scan transcripts newer than this date (ISO 8601)')
    parser.add_argument('--max-transcripts', type=int, default=10, metavar='N',
                        help='Max number of session transcripts to scan (default: 10)')
    parser.add_argument('--contradiction-policy',
                        choices=['flag-for-review', 'latest-wins'],
                        default='flag-for-review',
                        help='How to handle contradictions (default: flag-for-review)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print what would happen without writing any files or DB rows')
    parser.add_argument('--cancel', metavar='RUN-ID',
                        help='Cancel a running dream run by run_id')
    args = parser.parse_args()

    db_path = args.db if args.db else get_db_path()

    # ── Cancel mode ──────────────────────────────────────────────────────────
    if args.cancel:
        if not os.path.exists(db_path):
            print(json.dumps({'error': f'cast.db not found: {db_path}'}))
            sys.exit(1)
        ok = db_cancel_run(db_path, args.cancel)
        result = {
            'run_id': args.cancel,
            'status': 'canceled' if ok else 'cancel-failed',
        }
        print(json.dumps(result))
        sys.exit(0 if ok else 1)

    # ── Validate --instructions ──────────────────────────────────────────────
    instructions = args.instructions or ''
    if len(instructions) > 4096:
        print(json.dumps({'error': '--instructions exceeds 4096 character limit'}))
        sys.exit(1)

    # ── Resolve project-id ───────────────────────────────────────────────────
    project_id = resolve_project_id(args.project_id)
    if not project_id:
        print(json.dumps({
            'error': '--project-id is required (could not auto-detect from cwd)'
        }))
        sys.exit(1)

    # ── DB required (unless dry-run) ─────────────────────────────────────────
    if not args.dry_run and not os.path.exists(db_path):
        print(json.dumps({'error': f'cast.db not found: {db_path}'}))
        sys.exit(1)

    run_id = uuid.uuid4().hex

    # ── Phase 1: Orient ──────────────────────────────────────────────────────
    try:
        mem_files, memory_dir_sha = phase_orient(
            project_id, db_path, run_id, instructions, args.dry_run
        )
    except FileNotFoundError as e:
        print(json.dumps({'error': str(e)}))
        sys.exit(1)
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', 1, f'phase_orient: {e}')
        print(json.dumps({'error': f'Phase 1 failed: {e}'}))
        sys.exit(1)

    # ── Phase 2: Gather Signal ───────────────────────────────────────────────
    try:
        signals, stale_paths, transcripts_used = phase_gather(
            project_id,
            args.transcripts_since,
            args.max_transcripts,
            instructions,
            mem_files,
        )
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', 2, f'phase_gather: {e}')
        if not args.dry_run:
            db_update_run(db_path, run_id, 'failed', error=str(e))
        print(json.dumps({'error': f'Phase 2 failed: {e}'}))
        sys.exit(1)

    # ── Phase 3: Consolidate ─────────────────────────────────────────────────
    try:
        # output_dir not needed until Phase 4, but review entries accumulate here
        candidates, review_entries, changes_log = phase_consolidate(
            mem_files, signals, stale_paths,
            args.contradiction_policy,
            output_dir=None,  # placeholder; writes happen in phase 4
            dry_run=args.dry_run,
        )
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', 3, f'phase_consolidate: {e}')
        if not args.dry_run:
            db_update_run(db_path, run_id, 'failed', error=str(e))
        print(json.dumps({'error': f'Phase 3 failed: {e}'}))
        sys.exit(1)

    # ── Phase 4: Prune & Index ───────────────────────────────────────────────
    try:
        summary = phase_prune(
            candidates, review_entries, changes_log,
            project_id, run_id, memory_dir_sha,
            signals, transcripts_used,
            args.contradiction_policy, instructions,
            db_path, args.dry_run,
        )
    except AssertionError as e:
        _maybe_log_failure('cast-memory-dream', 4, f'safety_assert: {e}')
        if not args.dry_run:
            db_update_run(db_path, run_id, 'failed', error=str(e))
        print(json.dumps({'error': f'Safety assertion failed: {e}'}))
        sys.exit(1)
    except Exception as e:
        _maybe_log_failure('cast-memory-dream', 4, f'phase_prune: {e}')
        if not args.dry_run:
            db_update_run(db_path, run_id, 'failed', error=str(e))
        print(json.dumps({'error': f'Phase 4 failed: {e}'}))
        sys.exit(1)

    print(json.dumps(summary))
    sys.exit(0)


if __name__ == '__main__':
    main()
