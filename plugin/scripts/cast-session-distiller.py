#!/usr/bin/env python3
"""
cast-session-distiller.py — Extract worth-keeping facts from a session transcript.

Reads a session transcript (JSONL or plain-text fallback) from --input file or
stdin, filters to genuine user-authored prose only, applies extraction rules to
find feedback/project/user/reference memory candidates, and writes them as
frontmatter-bearing markdown files to a judgment-gated _pending/ queue.

No database writes are performed.  Candidates are reviewed and promoted via
`cast memory review`.

Usage:
  python3 cast-session-distiller.py --input transcript.jsonl [options]
  cat transcript.txt | python3 cast-session-distiller.py --dry-run [options]

Options:
  --input <file>           Read transcript from file instead of stdin
  --pending-dir <path>     Directory to write pending markdown files
                           (default: <dirname(abspath(input))>/memory/_pending)
  --dry-run                Print candidates as JSON without writing files
  --min-importance <f>     Minimum importance threshold (default: 0.7)
  --max-candidates <n>     Maximum candidates to write per run (default: 5)

Exit codes:
  0 — success (even if no candidates found)
  1 — unrecoverable error
"""

import sys
import os
import re
import json
import argparse


# ---------------------------------------------------------------------------
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


def _is_chrome(text):
    """Return True if text contains harness/command chrome markers (case-insensitive)."""
    lower = text.lower()
    for marker in _CHROME_MARKERS:
        if marker in lower:
            return True
    if text.strip().startswith('Caveat:'):
        return True
    return False


# ---------------------------------------------------------------------------
# Extraction patterns — (compiled_regex, memory_type, importance)
# Evaluated in order; first match per sentence wins.
# ---------------------------------------------------------------------------
EXTRACTION_PATTERNS = [
    (re.compile(
        r"(?:don't|dont|do not|stop doing|never)\s+.{5,}",
        re.IGNORECASE
    ), 'feedback', 0.85),

    (re.compile(
        r"(?:always|make sure|remember that|remember to)\s+.{5,}",
        re.IGNORECASE
    ), 'feedback', 0.75),

    (re.compile(
        r"(?:the reason (?:we|we're|we are)|because of|driven by)\s+.{5,}",
        re.IGNORECASE
    ), 'project', 0.70),

    (re.compile(
        r"(?:we decided|decision:)\s+.{3,}",
        re.IGNORECASE
    ), 'project', 0.70),

    (re.compile(
        r".+(?:\bis at path\b|\blives in\b|\blocated at\b)\s+.{3,}",
        re.IGNORECASE
    ), 'reference', 0.65),

    (re.compile(
        r"(?:I prefer|I like)\s+.{5,}",
        re.IGNORECASE
    ), 'user', 0.60),
]


def slugify(text, max_words=8):
    """Convert text to a slug: first N words, lowercased, joined by hyphens."""
    words = re.split(r'\W+', text.lower())
    words = [w for w in words if w][:max_words]
    return '-'.join(words) if words else 'memory'


def split_sentences(text):
    """Split text into (sentence, surrounding_context) tuples."""
    sentence_pattern = re.compile(r'(?<=[.!?])\s+')
    sentences = sentence_pattern.split(text.strip())
    result = []
    for i, sentence in enumerate(sentences):
        sentence = sentence.strip()
        if not sentence:
            continue
        parts = [sentence]
        if i > 0:
            parts = [sentences[i - 1].strip()] + parts
        if i < len(sentences) - 1:
            parts = parts + [sentences[i + 1].strip()]
        context = ' '.join(p for p in parts if p)
        result.append((sentence, context))
    return result


def parse_user_prose(text):
    """
    Parse JSONL transcript and return genuine user-prose strings.

    Filters out: assistant turns, isMeta turns, isSidechain turns,
    tool_result content (list), and harness/command chrome.

    Falls back to [text] if the input does not look like JSONL
    (first non-empty line does not start with '{').  This preserves
    dry-run / plain-text usage from stdin.
    """
    lines = text.splitlines()

    first_non_empty = next((l.strip() for l in lines if l.strip()), '')
    if not first_non_empty.startswith('{'):
        # Plain-text fallback — treat whole input as one prose blob
        return [text] if text.strip() else []

    prose_turns = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue  # skip malformed lines silently

        if not isinstance(obj, dict):
            continue

        if obj.get('type') != 'user':
            continue
        if obj.get('isMeta'):
            continue
        if obj.get('isSidechain'):
            continue

        message = obj.get('message', {})
        if not isinstance(message, dict):
            continue

        content = message.get('content', '')

        # tool_result turns carry a list for content — skip entirely
        if isinstance(content, list):
            continue

        if not isinstance(content, str):
            continue

        content = content.strip()
        if not content:
            continue

        if _is_chrome(content):
            continue

        prose_turns.append(content)

    return prose_turns


def extract_candidates(prose_turns, min_importance=0.7, max_candidates=None):
    """
    Extract memory candidates from cleaned user-prose turns.

    Returns list of dicts: {name, description, content, type, importance}

    max_candidates: when set, stop generating after 4× that count so dedup
    still has options without processing an unbounded transcript.
    """
    candidates = []
    seen_names = set()

    for prose in prose_turns:
        for sentence, context in split_sentences(prose):
            for pattern, mem_type, importance in EXTRACTION_PATTERNS:
                if importance < min_importance:
                    continue
                if pattern.search(sentence):
                    description = sentence[:140]
                    name = slugify(sentence, max_words=8)

                    if name in seen_names:
                        continue
                    seen_names.add(name)

                    candidates.append({
                        'name': name,
                        'description': description,
                        'content': context[:500],
                        'type': mem_type,
                        'importance': importance,
                    })
                    # L1: bound extraction — stop at 4× cap for dedup headroom
                    if max_candidates is not None and len(candidates) >= max_candidates * 4:
                        return candidates
                    break  # first pattern match wins per sentence

    return candidates


def _slug_exists_in_dir(slug, directory):
    """Return True if any file named <type>_<slug>.md exists in directory."""
    if not os.path.isdir(directory):
        return False
    for fname in os.listdir(directory):
        if not fname.endswith('.md'):
            continue
        stem = fname[:-3]
        parts = stem.split('_', 1)
        if len(parts) == 2 and parts[1] == slug:
            return True
    return False


def _is_duplicate(candidate, pending_dir, canonical_dir):
    """Return True if a file with this slug already exists in pending or canonical dirs."""
    slug = candidate['name']
    return (
        _slug_exists_in_dir(slug, pending_dir) or
        _slug_exists_in_dir(slug, canonical_dir)
    )


def _derive_session_id(input_path):
    """Derive session ID from transcript filename stem, if available."""
    if not input_path:
        return None
    stem = os.path.basename(input_path).split('.')[0]
    return stem if len(stem) >= 8 else None


def _write_pending_file(candidate, pending_dir, session_id=None):
    """Write a candidate as a frontmatter markdown file to pending_dir."""
    mem_type = candidate['type']
    slug = candidate['name']
    fname = f"{mem_type}_{slug}.md"
    fpath = os.path.join(pending_dir, fname)

    # M1: strip CR/LF to prevent YAML newline injection via description
    description = (candidate['description']
                   .replace('"', '\\"')
                   .replace('\n', ' ')
                   .replace('\r', ' '))

    lines = [
        '---',
        f'name: {slug}',
        f'description: "{description}"',
        'metadata:',
        '  node_type: memory',
        f'  type: {mem_type}',
        '  origin: session-distiller',
        '  confidence: low',
    ]
    if session_id:
        # L3: quote and strip CR/LF to prevent frontmatter injection via session ID
        safe_sid = session_id.replace(chr(10), '').replace(chr(13), '')
        lines.append(f'  originSessionId: "{safe_sid}"')
    lines += [
        '---',
        '',
        candidate['content'],
        '',
        '> ⚠️ Auto-extracted candidate (session-distiller). Unverified — review with `cast memory review`, then add `verified_at` on approval.',
        '',
    ]

    with open(fpath, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    return fpath


def main():
    parser = argparse.ArgumentParser(
        description='Extract worth-keeping facts from a session transcript and write to _pending/ queue'
    )
    parser.add_argument('--input', type=str, default=None,
                        help='Read transcript from file instead of stdin')
    parser.add_argument('--pending-dir', type=str, default=None,
                        help='Directory to write pending markdown files '
                             '(default: <dirname(abspath(input))>/memory/_pending)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print candidates as JSON without writing files')
    parser.add_argument('--min-importance', type=float, default=0.7,
                        help='Minimum importance threshold (default: 0.7)')
    parser.add_argument('--max-candidates', type=int, default=5,
                        help='Maximum candidates to write per run (default: 5)')
    args = parser.parse_args()

    # Read transcript
    if args.input:
        try:
            with open(args.input, 'r', encoding='utf-8') as f:
                text = f.read()
        except Exception as e:
            print(f"ERROR: Cannot read input file {args.input}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        try:
            text = sys.stdin.read()
        except Exception:
            text = ''

    if not text or not text.strip():
        if args.dry_run:
            print(json.dumps([]))
        sys.exit(0)

    prose_turns = parse_user_prose(text)

    if not prose_turns:
        if args.dry_run:
            print(json.dumps([]))
        sys.exit(0)

    candidates = extract_candidates(prose_turns, min_importance=args.min_importance,
                                   max_candidates=args.max_candidates)

    if args.dry_run:
        print(json.dumps(candidates, indent=2))
        sys.exit(0)

    if not candidates:
        print("[distiller] 0 candidates extracted", file=sys.stderr)
        sys.exit(0)

    # Determine pending dir
    pending_dir = args.pending_dir
    if not pending_dir:
        if args.input:
            pending_dir = os.path.join(
                os.path.dirname(os.path.abspath(args.input)), 'memory', '_pending'
            )
        else:
            # stdin with no --pending-dir — no write location, exit cleanly
            print("[distiller] stdin input with no --pending-dir — skipping write",
                  file=sys.stderr)
            sys.exit(0)

    try:
        os.makedirs(pending_dir, exist_ok=True)
    except Exception as e:
        print(f"[distiller] ERROR: cannot create pending dir {pending_dir}: {e}",
              file=sys.stderr)
        sys.exit(1)

    # Canonical memory dir is the parent of _pending/
    canonical_dir = os.path.dirname(pending_dir)
    session_id = _derive_session_id(args.input)

    written = 0
    skipped_dup = 0
    skipped_cap = 0

    for candidate in candidates:
        if written >= args.max_candidates:
            skipped_cap += 1
            continue
        if _is_duplicate(candidate, pending_dir, canonical_dir):
            skipped_dup += 1
            continue
        try:
            fpath = _write_pending_file(candidate, pending_dir, session_id=session_id)
            written += 1
            print(f"[distiller] wrote {fpath}", file=sys.stderr)
        except Exception as e:
            print(f"[distiller] WARN: failed to write '{candidate['name']}': {e}",
                  file=sys.stderr)

    print(f"[distiller] {written} written to _pending/, {skipped_dup} skipped (duplicates), "
          f"{skipped_cap} skipped (cap)", file=sys.stderr)
    sys.exit(0)


if __name__ == '__main__':
    main()
