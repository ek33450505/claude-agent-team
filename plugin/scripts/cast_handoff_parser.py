#!/usr/bin/env python3
"""
cast_handoff_parser.py — Parse and validate ## Handoff blocks from agent responses.

Importable as a module:
    from cast_handoff_parser import validate_handoff

CLI (for smoke-testing):
    python3 scripts/cast_handoff_parser.py < text
    echo "..." | python3 scripts/cast_handoff_parser.py

Schema (mirrors schemas/agent-handoff.json):
  REQUIRED: files_changed (comma-list or "none")
            status        (DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT)
            blockers      (text or "none")
  OPTIONAL: agent, key_decisions, next_agent_needs, <any other key: value>

Return value of validate_handoff():
  {
    "block_present": bool,
    "ok":            bool,
    "violation":     str | None,   # "missing_handoff" | "invalid_handoff_format" | "handoff_schema_violation"
    "pattern":       str | None,   # specifics, e.g. "missing_field:status"
    "detail":        str | None,   # human-readable description
    "raw_excerpt":   str,          # first 500 chars of block body (for DB raw_excerpt)
  }
"""
import re
import sys
import json

# Regex: match ## Handoff block body up to the next ## heading or end of string.
# Uses the pattern from docs/chain-handoff.md.
_HANDOFF_RE = re.compile(r'## Handoff\s*\n([\s\S]+?)(?=\n## |\Z)')

# Required field definitions: field_name → set of allowed values, or None for any non-empty string.
# KEEP IN SYNC with the inline fallback copy in scripts/cast_subagent_stop.py
# (_inline_validate_handoff / _INLINE_STATUS_VALUES). The two drifted apart once
# already — NEEDS_CONTEXT was missing from both from 2026-07-02 to 2026-08-04,
# logging 41 valid-status agent responses as protocol violations (see
# agent_protocol_violations, pattern='invalid_value:status=NEEDS_CONTEXT').
#
# This duplication is DELIBERATE, not sloppiness — do not "fix" it by merging
# the two or having the fallback import this module. The inline copy exists
# specifically for the case where importing THIS module fails (missing file,
# syntax error, bad sys.path); an import from inside that same fallback would
# fail for the identical reason it's needed, so it cannot depend on this file
# at runtime by construction. Parity is enforced by
# tests/test_cast_handoff_parser.py (TestStatusEnumParity) instead of a shared
# import — that test is the sync mechanism; keep it passing when either copy
# changes.
_REQUIRED_FIELDS: dict = {
    'files_changed': None,  # comma-list or "none" — any non-empty string is valid
    'status':        {'DONE', 'DONE_WITH_CONCERNS', 'BLOCKED', 'NEEDS_CONTEXT'},
    'blockers':      None,  # text or "none" — any non-empty string is valid
}

# Enum values may arrive wrapped in markdown emphasis ("**DONE**") or followed by
# trailing prose ("BLOCKED (verdict stated as text...)") — agents write these and
# mean the plain token; the intent is unambiguous. Extract the leading UPPER_SNAKE
# token before comparing against the allowed set: skip leading whitespace/emphasis
# markers, then capture a contiguous run of uppercase letters/underscores. This
# strips a wrapping "_DONE_" -> "DONE" (anchored at start/end only) without eating
# the internal underscores of DONE_WITH_CONCERNS itself. A value with no leading
# uppercase token (lowercase prose, pure punctuation, empty) normalizes to '' and
# is rejected same as before — a genuinely wrong or absent value is still caught.
_ENUM_TOKEN_RE = re.compile(r'^[\s*_]*([A-Z][A-Z_]*)')

# Handoff KEYS arrive markdown-emphasised for exactly the same reason enum VALUES
# do ("**files_changed:** a.py" alongside "**DONE**") — agents write the emphasis
# and mean the plain token. That tolerance shipped for values (_normalize_enum_value
# above) and was never applied to keys, so partitioning on the first ':' produced
# the key "**files_changed" and the required field read as absent. Measured
# 2026-08-27: 862 of 2,555 recorded agent_protocol_violations were well-formed
# handoffs failing on emphasis alone, burying the real violations ~40:1.
# Anchored at both ends only, so the internal underscore of "files_changed"
# is untouched.
_KEY_LEAD_RE = re.compile(r'^[\s*_`"\'+-]+')
_KEY_TRAIL_RE = re.compile(r'[\s*_`"\']+$')
_KEY_SPACE_RE = re.compile(r'\s+')
_VALUE_LEAD_EMPHASIS_RE = re.compile(r'^[\s*_`"\']+')
# Emphasis characters proper — a leading run made only of bullet markers and
# whitespace ("- files_changed") carries no closing half, so the value is left alone.
_EMPHASIS_CHARS = '*_`"\''


def _normalize_key(key: str) -> str:
    """Reduce a Handoff key to its bare identifier.

    Strips the decoration agents wrap keys in — markdown emphasis, list markers,
    JSON/shell quotes — and folds internal whitespace to '_'. Measured shapes, all
    from real rows: "**files_changed", "- **files_changed", '"files_changed"',
    "files changed", "_files_changed_", "`files_changed`".

    Whitespace folding cannot manufacture a false match: it maps "files changed"
    to "files_changed" (the agent plainly meant that field) while "files staged"
    and "files committed" become "files_staged"/"files_committed" — still not a
    required field, so those stay the genuine violations they are.
    """
    k = _KEY_TRAIL_RE.sub('', _KEY_LEAD_RE.sub('', key))
    return _KEY_SPACE_RE.sub('_', k.strip()).lower()

# A required field whose value is written as a list on the FOLLOWING lines:
#     files_changed:
#     - scripts/a.py
#     - scripts/b.py
# parses as present-but-empty, because the bullet lines carry no ':' of their own.
# Agents write this constantly and mean the list as the value (746 further
# violations from the same measurement). Consecutive list items are absorbed into
# the pending key; the first line that is not a list item — including a blank
# line — closes the continuation. Note the leading "*" alternative cannot swallow
# an emphasised key line: "**files_changed:**" has no whitespace after its first
# "*", so \s+ fails to match.
_LIST_ITEM_RE = re.compile(r'^(?:[-*+]|\d+[.)])\s+(.*\S)\s*$')


def _normalize_enum_value(value: str) -> str:
    """Return the leading UPPER_SNAKE token from an enum field value, tolerant of
    surrounding markdown emphasis/whitespace and trailing prose. Returns '' when no
    such token is found — callers treat '' as not-in-allowed-set.

    The capture group is greedy over [A-Z_]*, so a closing "_" emphasis wrapper
    (e.g. "_DONE_") is captured along with the token itself ("DONE_") since
    underscore is also a legal mid-token character (DONE_WITH_CONCERNS). Strip
    only a TRAILING underscore after capture — every real enum value ends in a
    letter, so this never truncates a legitimate token, and it correctly reduces
    "_DONE_WITH_CONCERNS_" -> "DONE_WITH_CONCERNS" (internal underscores untouched).
    """
    m = _ENUM_TOKEN_RE.match(value)
    return m.group(1).rstrip('_') if m else ''


def extract_handoff_block(text: str):
    """Return the raw ## Handoff block body, or None if the block is absent."""
    m = _HANDOFF_RE.search(text)
    if not m:
        return None
    return m.group(1)


def _parse_kv(block: str) -> dict:
    """Parse 'key: value' lines from the Handoff block body into a dict.

    Keys are lowercased, stripped, and stripped of markdown emphasis; values are
    stripped. Lines without ':' are silently skipped unless they are list items
    continuing the previous key. Only the first ':' is used as a delimiter
    (values may contain colons).
    """
    result: dict = {}
    # Key of the most recent 'key:' line whose inline value was empty — the next
    # lines may be its value as a list. None means no continuation is open.
    pending_list_key = None

    for raw_line in block.splitlines():
        line = raw_line.strip()
        if not line:
            pending_list_key = None
            continue

        if pending_list_key is not None:
            item = _LIST_ITEM_RE.match(line)
            if item and _normalize_key(item.group(1).partition(':')[0]) in _REQUIRED_FIELDS:
                # "- **status:** DONE" is a bulleted KEY line, not a value of the
                # pending list. Absorbing it would silently destroy a required
                # field, so fall through and parse it as a key.
                item = None
            if item:
                seen = result[pending_list_key]
                result[pending_list_key] = f'{seen}, {item.group(1)}' if seen else item.group(1)
                continue
            pending_list_key = None

        if ':' not in line:
            continue
        key_raw, _, value = line.partition(':')
        key = _normalize_key(key_raw)
        value = value.strip()
        lead = _KEY_LEAD_RE.match(key_raw)
        if lead and any(c in _EMPHASIS_CHARS for c in lead.group(0)):
            # The key opened a markdown/quote wrapper, so the closing half of it is
            # sitting at the head of the value:
            #     "**files_changed:** a.py"  ->  key "**files_changed", value "** a.py"
            # Strip it ONLY then. A plainly-written key's value is left byte-for-byte
            # alone, so a legitimate leading "*" (a "*.py" glob) survives — and
            # "**blockers:**" with nothing after it correctly reduces to an empty
            # value rather than reading as the non-empty string "**".
            value = _VALUE_LEAD_EMPHASIS_RE.sub('', value)
        if not key:
            continue
        result[key] = value
        pending_list_key = key if not value else None

    return result


def validate_handoff(text: str) -> dict:
    """Validate the ## Handoff block in `text` against the typed schema.

    Returns a structured result dict. See module docstring for field descriptions.
    Never raises — all errors are captured in the returned dict.
    """
    try:
        block = extract_handoff_block(text)
    except Exception as exc:
        return {
            'block_present': False,
            'ok': False,
            'violation': 'invalid_handoff_format',
            'pattern': None,
            'detail': f'Handoff block extraction failed: {exc}',
            'raw_excerpt': '',
        }

    if block is None:
        return {
            'block_present': False,
            'ok': False,
            'violation': 'missing_handoff',
            'pattern': None,
            'detail': 'No ## Handoff block found in agent response',
            'raw_excerpt': '',
        }

    raw_excerpt = block[:500]

    try:
        fields = _parse_kv(block)
    except Exception as exc:
        return {
            'block_present': True,
            'ok': False,
            'violation': 'invalid_handoff_format',
            'pattern': None,
            'detail': f'Failed to parse Handoff block key-value lines: {exc}',
            'raw_excerpt': raw_excerpt,
        }

    if not fields:
        return {
            'block_present': True,
            'ok': False,
            'violation': 'invalid_handoff_format',
            'pattern': None,
            'detail': 'Handoff block is present but contains no parseable key: value lines',
            'raw_excerpt': raw_excerpt,
        }

    # Validate each required field
    for field, allowed_values in _REQUIRED_FIELDS.items():
        if field not in fields:
            return {
                'block_present': True,
                'ok': False,
                'violation': 'handoff_schema_violation',
                'pattern': f'missing_field:{field}',
                'detail': f'Required field "{field}" is absent from ## Handoff block',
                'raw_excerpt': raw_excerpt,
            }

        value = fields[field]
        if not value:
            return {
                'block_present': True,
                'ok': False,
                'violation': 'handoff_schema_violation',
                'pattern': f'empty_field:{field}',
                'detail': f'Required field "{field}" is present but has an empty value',
                'raw_excerpt': raw_excerpt,
            }

        # Enum validation (only for fields with a defined allowed_values set).
        # Tolerant of markdown emphasis / trailing prose around the token (see
        # _normalize_enum_value) — a genuinely wrong or absent leading token is
        # still rejected; the raw value (not the normalized token) is reported
        # below for debuggability.
        if allowed_values is not None and _normalize_enum_value(value) not in allowed_values:
            return {
                'block_present': True,
                'ok': False,
                'violation': 'handoff_schema_violation',
                'pattern': f'invalid_value:{field}={value}',
                'detail': (
                    f'Field "{field}" value "{value}" is not in the allowed set: '
                    f'{sorted(allowed_values)}'
                ),
                'raw_excerpt': raw_excerpt,
            }

    # All required fields present and valid
    return {
        'block_present': True,
        'ok': True,
        'violation': None,
        'pattern': None,
        'detail': None,
        'raw_excerpt': raw_excerpt,
    }


if __name__ == '__main__':
    text = sys.stdin.read()
    result = validate_handoff(text)
    print(json.dumps(result, indent=2))
    # Exit 1 when validation fails so CLI callers can detect violations
    sys.exit(0 if result['ok'] else 1)
