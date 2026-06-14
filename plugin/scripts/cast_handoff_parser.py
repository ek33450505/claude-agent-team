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
            status        (DONE | DONE_WITH_CONCERNS | BLOCKED)
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
_REQUIRED_FIELDS: dict = {
    'files_changed': None,  # comma-list or "none" — any non-empty string is valid
    'status':        {'DONE', 'DONE_WITH_CONCERNS', 'BLOCKED'},
    'blockers':      None,  # text or "none" — any non-empty string is valid
}


def extract_handoff_block(text: str):
    """Return the raw ## Handoff block body, or None if the block is absent."""
    m = _HANDOFF_RE.search(text)
    if not m:
        return None
    return m.group(1)


def _parse_kv(block: str) -> dict:
    """Parse 'key: value' lines from the Handoff block body into a dict.

    Keys are lowercased and stripped; values are stripped.
    Lines without ':' are silently skipped.
    Only the first ':' is used as a delimiter (values may contain colons).
    """
    result: dict = {}
    for line in block.splitlines():
        line = line.strip()
        if not line:
            continue
        if ':' not in line:
            continue
        key, _, value = line.partition(':')
        key = key.strip().lower()
        value = value.strip()
        if key:
            result[key] = value
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

        # Enum validation (only for fields with a defined allowed_values set)
        if allowed_values is not None and value not in allowed_values:
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
