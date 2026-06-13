#!/usr/bin/env python3
"""
validate-eval-yaml.py — CAST A3 eval case YAML validator.

Validates that an eval YAML file:
  1. Parses without error
  2. Contains all required top-level keys
  3. Each grader (type=programmatic) has a runnable command — not a prose stub

YAML parsing: uses PyYAML (import yaml). PyYAML is available in the CAST
development environment (confirmed on darwin/python3). If unavailable, the
script exits with code 1 and a clear error message instructing the user to
install PyYAML (pip install pyyaml) or use a python3 stdlib fallback.

Exit codes:
  0 — valid
  1 — invalid (prints reason to stderr)

Usage:
  python3 scripts/eval-graders/validate-eval-yaml.py evals/cases/commit/commit-missing-status-block.yaml
"""

import sys
from pathlib import Path

# Required top-level keys in every eval YAML.
REQUIRED_KEYS = {
    'id',
    'version',
    'agent',
    'description',
    'corpus_source',
    'failure_type',
    'cost_tier',
    'tags',
    'trigger',
    'expected_behaviors',
    'forbidden_behaviors',
    'graders',
}

# Each programmatic grader command must contain at least one of these tokens.
# A command that lacks all of them is treated as a prose stub (invalid).
GRADER_COMMAND_TOKENS = ('grep', 'python3', 'test ', '-f', '-q', '|', '{output')

# Allowed corpus_source values.
ALLOWED_CORPUS_SOURCES = {'honesty_tables', 'manual', 'bats_failure', 'agent_run'}

# Allowed cost_tier values.
ALLOWED_COST_TIERS = {'cheap', 'medium', 'expensive'}

# Allowed grader types.
ALLOWED_GRADER_TYPES = {'programmatic', 'llm_judge'}


def _fail(message: str) -> int:
    print(f'INVALID: {message}', file=sys.stderr)
    return 1


def _load_yaml(path: str):
    """Load YAML using PyYAML. Falls back with a clear error if unavailable."""
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        print(
            'ERROR: PyYAML is not installed. Install it with: pip install pyyaml\n'
            'Alternatively, use a JSON-compatible YAML format and parse with json.loads.',
            file=sys.stderr,
        )
        sys.exit(1)

    with open(path, 'r') as fh:
        try:
            return yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            print(f'INVALID: YAML parse error: {exc}', file=sys.stderr)
            sys.exit(1)


def validate(path: str) -> int:
    """Validate an eval YAML file. Returns 0 (valid) or 1 (invalid)."""
    p = Path(path)
    if not p.exists():
        return _fail(f'File not found: {path!r}')
    if p.suffix not in ('.yaml', '.yml'):
        return _fail(f'File must have .yaml or .yml extension: {path!r}')

    data = _load_yaml(path)

    if not isinstance(data, dict):
        return _fail('Top-level structure must be a mapping (dict), not a list or scalar')

    # 1. Required top-level keys.
    missing = REQUIRED_KEYS - data.keys()
    if missing:
        return _fail(f'Missing required keys: {sorted(missing)}')

    # 2. id must match filename (without .yaml).
    expected_id = p.stem
    if data['id'] != expected_id:
        return _fail(
            f"id field {data['id']!r} must match filename stem {expected_id!r}"
        )

    # 3. corpus_source value check.
    corpus_source = data.get('corpus_source', '')
    if corpus_source not in ALLOWED_CORPUS_SOURCES:
        return _fail(
            f'corpus_source {corpus_source!r} not in allowed values: '
            f'{sorted(ALLOWED_CORPUS_SOURCES)}'
        )

    # 4. cost_tier value check.
    cost_tier = data.get('cost_tier', '')
    if cost_tier not in ALLOWED_COST_TIERS:
        return _fail(
            f'cost_tier {cost_tier!r} not in allowed values: '
            f'{sorted(ALLOWED_COST_TIERS)}'
        )

    # 5. graders must be a non-empty list.
    graders = data.get('graders', [])
    if not isinstance(graders, list) or len(graders) == 0:
        return _fail('graders must be a non-empty list')

    # 6. Each grader must have required fields and a runnable command (stub guard).
    for i, grader in enumerate(graders):
        if not isinstance(grader, dict):
            return _fail(f'graders[{i}] must be a mapping, got {type(grader).__name__}')

        grader_id = grader.get('id', f'<unnamed grader {i}>')

        if 'id' not in grader:
            return _fail(f'graders[{i}] missing required field: id')
        if 'type' not in grader:
            return _fail(f'graders[{i}] ({grader_id!r}) missing required field: type')
        if 'pass_criteria' not in grader:
            return _fail(
                f'graders[{i}] ({grader_id!r}) missing required field: pass_criteria'
            )
        if 'on_error' not in grader:
            return _fail(
                f'graders[{i}] ({grader_id!r}) missing required field: on_error'
            )

        grader_type = grader.get('type', '')
        if grader_type not in ALLOWED_GRADER_TYPES:
            return _fail(
                f'graders[{i}] ({grader_id!r}) type {grader_type!r} not in '
                f'{sorted(ALLOWED_GRADER_TYPES)}'
            )

        if grader_type == 'programmatic':
            if 'command' not in grader:
                return _fail(
                    f'graders[{i}] ({grader_id!r}) type=programmatic requires a command field'
                )
            command = str(grader['command'])
            # Stub guard: command must look executable, not like prose description.
            if not any(token in command for token in GRADER_COMMAND_TOKENS):
                return _fail(
                    f'graders[{i}] ({grader_id!r}) command looks like a prose stub '
                    f'(must contain one of {GRADER_COMMAND_TOKENS}): {command[:80]!r}'
                )
            # {output} guard: prohibit piping full agent-response text into a shell grader.
            # {output} is the raw agent response string — untrusted text controlled by the
            # agent-under-test.  Piping it into a shell command (shell=True) would allow
            # a sufficiently adversarial agent response to execute arbitrary commands.
            # Use {output_file} (a path to a temp file) for programmatic graders;
            # reserve {output} for llm_judge prompts (not shell-executed).
            if '{output}' in command:
                return _fail(
                    f'graders[{i}] ({grader_id!r}) command contains {{output}} which would '
                    f'pipe agent-response text directly into a shell command — '
                    f'use {{output_file}} instead; {{output}} is reserved for '
                    f'llm_judge prompts (not shell-executed)'
                )

        elif grader_type == 'llm_judge':
            if 'prompt' not in grader:
                return _fail(
                    f'graders[{i}] ({grader_id!r}) type=llm_judge requires a prompt field'
                )

    # 7. expected_behaviors and forbidden_behaviors must be non-empty lists.
    for field in ('expected_behaviors', 'forbidden_behaviors'):
        val = data.get(field, [])
        if not isinstance(val, list) or len(val) == 0:
            return _fail(f'{field!r} must be a non-empty list')

    print(f'OK: {path}')
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <eval-yaml-file>', file=sys.stderr)
        return 1

    return validate(sys.argv[1])


if __name__ == '__main__':
    sys.exit(main())
