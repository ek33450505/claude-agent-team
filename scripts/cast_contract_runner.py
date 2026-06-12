#!/usr/bin/env python3
"""
CAST contract runner — assertion evaluation engine.
Reads fixture content and assertions from env vars, evaluates each assertion,
returns JSON with results.

Env vars (all required):
  CAST_FIXTURE_CONTENT    — The fixture response text
  CAST_ASSERTIONS_JSON    — JSON array of assertion objects
  CAST_FIXTURE_EXIT_CODE  — Exit code from the fixture (optional, default 0)
"""

import os
import sys
import json
import re
import sqlite3
from pathlib import Path

# Import identifier validation from cast_db when available; fall back to inline.
try:
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location(
        'cast_db',
        str(Path(__file__).parent / 'cast_db.py'),
    )
    _cast_db = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_cast_db)
    _validate_identifier = _cast_db._validate_identifier
except Exception:
    def _validate_identifier(name: str) -> str:  # type: ignore[misc]
        if not re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', name):
            raise ValueError(f'Invalid SQL identifier: {name!r}')
        return name


def get_db_path():
    """Get cast.db path from env or default."""
    return os.environ.get(
        'CAST_DB_PATH',
        str(Path.home() / '.claude' / 'cast.db')
    )


def eval_output_contains(pattern, content):
    """Check if pattern (regex) is found in content (case-insensitive, multiline)."""
    try:
        return bool(re.search(pattern, content, re.MULTILINE | re.IGNORECASE))
    except re.error as e:
        return False


def eval_output_not_contains(pattern, content):
    """Check if pattern is NOT found in content."""
    return not eval_output_contains(pattern, content)


def eval_cast_db_write(table, field, expected):
    """Check if cast.db contains a row with field=expected in table."""
    try:
        _validate_identifier(table)
        _validate_identifier(field)
        db_path = get_db_path()
        if not os.path.exists(db_path):
            return False

        conn = sqlite3.connect(db_path, timeout=2)
        cursor = conn.cursor()

        # Simple check: does the row exist?
        sql = f'SELECT COUNT(*) FROM {table} WHERE {field} = ?'
        cursor.execute(sql, (expected,))
        count = cursor.fetchone()[0]
        conn.close()

        return count > 0
    except Exception as e:
        # DB check failed — return False (assertion failed)
        return False


def eval_exit_code(expected_code, actual_code):
    """Check if exit code matches expected."""
    try:
        expected_code = int(expected_code)
        actual_code = int(actual_code)
        return expected_code == actual_code
    except (ValueError, TypeError):
        return False


def main():
    fixture_content = os.environ.get('CAST_FIXTURE_CONTENT', '')
    assertions_json_str = os.environ.get('CAST_ASSERTIONS_JSON', '[]')
    fixture_exit_code = os.environ.get('CAST_FIXTURE_EXIT_CODE', '0')

    # Parse assertions
    try:
        assertions = json.loads(assertions_json_str)
    except json.JSONDecodeError:
        assertions = []

    if not isinstance(assertions, list):
        assertions = []

    results = []

    for assertion in assertions:
        if not isinstance(assertion, dict):
            continue

        asr_type = assertion.get('type', '')
        passed = False

        if asr_type == 'output_contains':
            pattern = assertion.get('pattern', '')
            passed = eval_output_contains(pattern, fixture_content)
            results.append({
                'type': 'output_contains',
                'pattern': pattern,
                'passed': passed
            })

        elif asr_type == 'output_not_contains':
            pattern = assertion.get('pattern', '')
            passed = eval_output_not_contains(pattern, fixture_content)
            results.append({
                'type': 'output_not_contains',
                'pattern': pattern,
                'passed': passed
            })

        elif asr_type == 'cast_db_write':
            table = assertion.get('table', '')
            field = assertion.get('field', '')
            expected = assertion.get('expected', '')
            passed = eval_cast_db_write(table, field, expected)
            results.append({
                'type': 'cast_db_write',
                'table': table,
                'field': field,
                'expected': expected,
                'passed': passed
            })

        elif asr_type == 'exit_code':
            expected = assertion.get('expected', '')
            passed = eval_exit_code(expected, fixture_exit_code)
            results.append({
                'type': 'exit_code',
                'expected': expected,
                'actual': fixture_exit_code,
                'passed': passed
            })

    output = {
        'results': results,
        'passed': all(r.get('passed', False) for r in results)
    }

    print(json.dumps(output, indent=2))
    sys.exit(0 if output['passed'] else 1)


if __name__ == '__main__':
    main()
