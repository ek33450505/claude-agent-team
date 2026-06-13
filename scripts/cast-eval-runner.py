#!/usr/bin/env python3
"""
cast-eval-runner.py — CAST A3 eval harness runner (Phase A MVP).

Subcommands:
  run <eval-id|--all> [--output-file PATH] [--dry-run] [--k N]
  list [--agent NAME] [--failure-type TYPE]

Grader source paths are resolved relative to CAST repo root (CAST_REPO_DIR env
or inferred from this script's location).

Exit codes:
  0 — overall PASS (or SKIP)
  1 — overall FAIL
  2 — ERROR (grader could not decide, or system error)

Phase A: k=1 only, programmatic graders only.
Phase B (future): LLM judge, pass@k>1, cast eval report.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add the scripts directory to sys.path so cast_db can be imported.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import cast_db
    _HAS_CAST_DB = True
except ImportError:  # fake-success-ok — cast_db is optional; runner degrades with a WARNING
    _HAS_CAST_DB = False

try:
    import yaml
    _HAS_YAML = True
except ImportError:  # fake-success-ok — PyYAML absence causes a hard exit at load time, not silent skip
    _HAS_YAML = False


# ── Status constants ───────────────────────────────────────────────────────────

_STATUS_PASS = 'pass'
_STATUS_FAIL = 'fail'
_STATUS_ERROR = 'error'
_STATUS_SKIP = 'skip'

_EXIT_PASS = 0
_EXIT_FAIL = 1
_EXIT_ERROR = 2


# ── Path resolution ────────────────────────────────────────────────────────────

def _get_db_path() -> str:
    return os.environ.get('CAST_DB_PATH', str(Path.home() / '.claude' / 'cast.db'))


def _get_repo_dir() -> Path:
    """Resolve the CAST repo root directory.

    Priority:
      1. CAST_REPO_DIR env var (set by bin/cast or tests)
      2. Inferred from this script's location: <repo>/scripts/<this-file>
         → parent.parent is repo root
    """
    if 'CAST_REPO_DIR' in os.environ:
        return Path(os.environ['CAST_REPO_DIR']).resolve()
    # scripts/cast-eval-runner.py → ../../ = repo root
    return Path(__file__).parent.parent.resolve()


def _get_eval_cases_dir() -> Path:
    """Resolve the evals/cases/ directory.

    Priority:
      1. CAST_EVAL_DIR env var (for tests and alternate layouts)
      2. <repo_root>/evals/cases
    """
    if 'CAST_EVAL_DIR' in os.environ:
        return Path(os.environ['CAST_EVAL_DIR']).resolve()
    return _get_repo_dir() / 'evals' / 'cases'


# ── YAML loading ───────────────────────────────────────────────────────────────

def _load_yaml_file(path: Path) -> dict:
    """Load a YAML file using PyYAML. Exits with error if PyYAML unavailable."""
    if not _HAS_YAML:
        print(
            'ERROR: PyYAML is not installed. Install with: pip install pyyaml',
            file=sys.stderr,
        )
        sys.exit(_EXIT_ERROR)
    with open(path, 'r') as fh:
        return yaml.safe_load(fh)


def _find_case_file(eval_id: str, cases_dir: Path) -> Optional[Path]:
    """Search for <eval_id>.yaml under cases_dir (any subdirectory depth)."""
    for yaml_file in cases_dir.rglob('*.yaml'):
        if yaml_file.stem == eval_id:
            return yaml_file
    return None


def _load_all_cases(cases_dir: Path) -> List[dict]:
    """Load all eval YAML files from cases_dir (sorted for determinism)."""
    cases = []
    for yaml_file in sorted(cases_dir.rglob('*.yaml')):
        try:
            data = _load_yaml_file(yaml_file)
            if isinstance(data, dict) and 'id' in data:
                cases.append(data)
        except Exception as exc:  # fake-success-ok — corrupt YAML files are skipped with a WARNING; caller gets partial list
            print(f'WARNING: skipping {yaml_file}: {exc}', file=sys.stderr)
    return cases


# ── Template substitution ─────────────────────────────────────────────────────

def _substitute(
    cmd: str,
    output_file: str,
    output: str,
    agent_run_id: str,
    session_id: str,
    agent: str = '',
    since: str = '',
) -> str:
    """Substitute template placeholders in a grader command.

    Security contract: substituted VALUES are shlex.quote()-escaped to prevent
    shell injection.  The command text itself is repo-trusted (comes from YAML
    files committed to the CAST repo).

    Available placeholders:
      {output_file}   — path to temp file containing captured agent response
      {output}        — agent response as a string (for LLM judge prompts)
      {agent_run_id}  — agent_runs.agent_id from live dispatch ('' in --output-file mode)
      {session_id}    — current CAST session ID
      {agent}         — the eval case's target agent name (e.g. 'code-writer')
      {since}         — run start time as ISO8601 UTC string (for time-windowed DB queries)

    Two template forms:
      '{placeholder}'  — YAML-author wrapped the token in single quotes;
                         replaced with shlex.quote(value) (strips the outer
                         template quotes and applies proper shell quoting)
      {placeholder}    — bare form; replaced with shlex.quote(value)

    The '{placeholder}' form is handled FIRST so the bare-form pass does not
    double-substitute.
    """
    substitutions = {
        'output_file': output_file,
        'output': output,
        'agent_run_id': agent_run_id,
        'session_id': session_id,
        'agent': agent,
        'since': since,
    }
    for key, value in substitutions.items():
        quoted = shlex.quote(value)
        # Replace YAML-quoted form first: '{key}' (including surrounding single quotes)
        # → shlex.quote(value).  The f-string f"'{{{key}}}'" evaluates to e.g.
        # "'{output_file}'" — exactly the token the YAML author writes.  Replacing the
        # WHOLE token (quotes + braces) with shlex.quote(value) means shlex.quote owns
        # all shell quoting; there is no residual bare {key} left for the pass below.
        cmd = cmd.replace(f"'{{{key}}}'", quoted)
        # Replace bare form: {key} → shlex.quote(value)
        # Handles templates that use {key} without surrounding single quotes.
        cmd = cmd.replace(f'{{{key}}}', quoted)
    return cmd


# ── Grader execution ───────────────────────────────────────────────────────────

def _run_grader(
    grader: dict,
    output_file: str,
    output: str,
    agent_run_id: str,
    session_id: str,
    agent: str,
    since: str,
    repo_dir: Path,
) -> dict:
    """Run one grader and return a result dict.

    Result keys: grader_id, status, output, duration_ms.

    Exit-code → status mapping:
      0    → pass
      1    → fail
      2    → DB/table absent; apply on_error policy (skip | error | fail)
      other → error

    Three-outcome discipline: an errored grader MUST NOT be recorded as fail.
    """
    grader_id = grader.get('id', 'unknown')
    grader_type = grader.get('type', 'programmatic')
    on_error = grader.get('on_error', 'error')

    if grader_type != 'programmatic':
        # Phase A: only programmatic graders implemented.
        return {
            'grader_id': grader_id,
            'status': _STATUS_SKIP,
            'output': f'grader type {grader_type!r} not implemented in Phase A (skipped)',
            'duration_ms': 0,
        }

    cmd_template = grader.get('command', '')
    if not cmd_template:
        return {
            'grader_id': grader_id,
            'status': _STATUS_ERROR,
            'output': 'grader has no command field',
            'duration_ms': 0,
        }

    cmd = _substitute(cmd_template, output_file, output, agent_run_id, session_id, agent, since)

    start = time.monotonic()
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            cwd=str(repo_dir),
            timeout=60,
        )
        elapsed_ms = int((time.monotonic() - start) * 1000)
        exit_code = result.returncode
        grader_output = (result.stdout + result.stderr).strip()

        if exit_code == 0:
            status = _STATUS_PASS
        elif exit_code == 1:
            status = _STATUS_FAIL
        elif exit_code == 2:
            # DB/table absent or infrastructure error: apply on_error policy.
            # Three-outcome discipline: error ≠ fail.
            policy_map = {
                'skip': _STATUS_SKIP,
                'error': _STATUS_ERROR,
                'fail': _STATUS_FAIL,
            }
            status = policy_map.get(on_error, _STATUS_ERROR)
        else:
            # Unexpected exit code → error (never fail without explicit grader verdict).
            status = _STATUS_ERROR

        return {
            'grader_id': grader_id,
            'status': status,
            'output': grader_output,
            'duration_ms': elapsed_ms,
        }

    except subprocess.TimeoutExpired:  # fake-success-ok — three-outcome discipline: timeout → error, never fail
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {
            'grader_id': grader_id,
            'status': _STATUS_ERROR,
            'output': 'grader timed out after 60s',
            'duration_ms': elapsed_ms,
        }
    except Exception as exc:  # fake-success-ok — three-outcome discipline: unexpected error → error status, never fail
        elapsed_ms = int((time.monotonic() - start) * 1000)
        return {
            'grader_id': grader_id,
            'status': _STATUS_ERROR,
            'output': f'grader execution error: {exc}',
            'duration_ms': elapsed_ms,
        }


def _worst_status(grader_results: List[dict]) -> str:
    """Worst-wins status roll-up: error > fail > skip > pass."""
    priority = {
        _STATUS_ERROR: 3,
        _STATUS_FAIL: 2,
        _STATUS_SKIP: 1,
        _STATUS_PASS: 0,
    }
    worst = _STATUS_PASS
    for r in grader_results:
        s = r.get('status', _STATUS_ERROR)
        if priority.get(s, 0) > priority.get(worst, 0):
            worst = s
    return worst


# ── DB recording ───────────────────────────────────────────────────────────────

def _record_eval_run(
    eval_case: dict,
    grader_results: List[dict],
    overall_status: str,
    agent_run_id: str,
    started_at: str,
    ended_at: str,
    duration_ms: int,
) -> None:
    """Write one eval_runs row. Degrades gracefully if DB absent or cast_db unavailable."""
    row = {
        'id': str(uuid.uuid4()),
        'eval_id': eval_case.get('id', ''),
        'agent': eval_case.get('agent', ''),
        'attempt': 1,
        'agent_run_id': agent_run_id,
        'status': overall_status,
        'grader_results': json.dumps(grader_results),
        'pass_at_k': 1.0 if overall_status == _STATUS_PASS else 0.0,
        'k': 1,
        'duration_ms': duration_ms,
        'started_at': started_at,
        'ended_at': ended_at,
        'model': '',
        'cost_tier': eval_case.get('cost_tier', ''),
    }

    if not _HAS_CAST_DB:  # fake-success-ok — intentional degradation: runner still prints result; DB write is best-effort
        print(
            'WARNING: cast_db not available — eval_runs row not written to DB',
            file=sys.stderr,
        )
        return

    db_path = _get_db_path()
    if not Path(db_path).exists():  # fake-success-ok — intentional degradation: DB absent is warned, not fatal
        print(
            f'WARNING: DB not found at {db_path!r} — eval_runs row not written',
            file=sys.stderr,
        )
        return

    success = cast_db.db_write('eval_runs', row)
    if not success:
        print('WARNING: db_write to eval_runs failed (check cast_db logs)', file=sys.stderr)


# ── Output formatting ──────────────────────────────────────────────────────────

def _print_result(eval_case: dict, grader_results: List[dict], overall_status: str) -> None:
    """Print a human-readable per-eval summary to stdout."""
    eval_id = eval_case.get('id', '?')
    agent = eval_case.get('agent', '?')
    print(f'\nEval: {eval_id}  (agent: {agent})')
    print('-' * 64)
    for r in grader_results:
        gid = r['grader_id']
        st = r['status'].upper()
        ms = r['duration_ms']
        out = r.get('output', '')
        print(f'  [{st}] {gid}  ({ms}ms)')
        if out:
            for line in out.splitlines()[:5]:  # cap at 5 lines to keep output readable
                print(f'         {line}')
    print('-' * 64)
    print(f'Overall: {overall_status.upper()}')


# ── Dry run ────────────────────────────────────────────────────────────────────

def _dry_run(eval_case: dict, cases_dir: Path, repo_dir: Path) -> int:
    """Validate the case and print would-run graders. Returns 0 (valid) or 1 (invalid)."""
    eval_id = eval_case.get('id', '?')
    print(f'DRY RUN: {eval_id}')
    print(f'  agent:        {eval_case.get("agent", "?")}')
    print(f'  cost_tier:    {eval_case.get("cost_tier", "?")}')
    print(f'  failure_type: {eval_case.get("failure_type", "?")}')

    # Invoke validate-eval-yaml.py if available.
    validate_script = repo_dir / 'scripts' / 'eval-graders' / 'validate-eval-yaml.py'
    yaml_file = _find_case_file(eval_id, cases_dir)
    if validate_script.exists() and yaml_file:
        result = subprocess.run(
            [sys.executable, str(validate_script), str(yaml_file)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print(f'  validation:   OK')
        else:
            print(f'  validation:   INVALID — {result.stderr.strip()}')
            return 1
    elif not validate_script.exists():
        print(f'  validation:   SKIPPED (validate-eval-yaml.py not found)')

    print(f'  graders (would run):')
    for grader in eval_case.get('graders', []):
        gid = grader.get('id', '?')
        gtype = grader.get('type', '?')
        print(f'    - {gid}  (type={gtype})')

    return 0


# ── Live dispatch ──────────────────────────────────────────────────────────────

def _live_dispatch(eval_case: dict, repo_dir: Path) -> Tuple[str, str]:
    """Attempt live dispatch via `cast dispatch --managed <agent> "<trigger>"`.

    Returns (agent_run_id, captured_output).

    IMPORTANT: live dispatch requires a Managed Agents API key and wired CAST
    infra.  This path is best-effort in Phase A.  The --output-file path is the
    PRIMARY deterministic path used by tests.  If dispatch fails, the runner
    exits with a clear message rather than silently recording a bad result.
    """
    import shutil as _shutil

    cast_bin = repo_dir / 'bin' / 'cast'
    if not cast_bin.exists():
        cast_path = _shutil.which('cast')
        if cast_path:
            cast_bin = Path(cast_path)
        else:
            print(
                'ERROR: Live dispatch requires the cast CLI.\n'
                '  Use --output-file <path> for deterministic, zero-cost runs.',
                file=sys.stderr,
            )
            sys.exit(_EXIT_ERROR)

    agent = eval_case.get('agent', '')
    trigger = eval_case.get('trigger', '').strip()

    print(f'Dispatching agent: {agent} ...', file=sys.stderr)
    try:
        result = subprocess.run(
            [str(cast_bin), 'dispatch', '--managed', agent, trigger],
            capture_output=True,
            text=True,
            timeout=150,
            cwd=str(repo_dir),
        )
        combined = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            print(
                f'WARNING: cast dispatch returned exit {result.returncode}.\n'
                f'  Live dispatch may be unavailable (no Managed Agent API key).\n'
                f'  Use --output-file for deterministic runs.',
                file=sys.stderr,
            )
        # fake-success-ok — return the output (even if dispatch errored); graders apply
        # on_error policy for DB-check graders.  The WARNING above surfaces the failure.
        return ('', combined)

    except subprocess.TimeoutExpired:
        print(
            'ERROR: Live dispatch timed out after 150s.\n'
            '  Use --output-file for deterministic runs.',
            file=sys.stderr,
        )
        sys.exit(_EXIT_ERROR)
    except Exception as exc:
        print(
            f'ERROR: Live dispatch failed: {exc}\n'
            f'  Use --output-file for deterministic runs.',
            file=sys.stderr,
        )
        sys.exit(_EXIT_ERROR)


# ── Run a single eval case ─────────────────────────────────────────────────────

def _run_case(
    eval_case: dict,
    output_file_path: Optional[str],
    dry_run: bool,
    repo_dir: Path,
    cases_dir: Path,
) -> Tuple[str, int]:
    """Run one eval case. Returns (overall_status, exit_code)."""
    now = datetime.now(timezone.utc)
    started_at = now.isoformat()
    # `since` uses a simple ISO8601-Z format for SQLite string comparison;
    # seeded rows with timestamps >= this value are within the eval window.
    since = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    start_time = time.monotonic()

    # The eval case's target agent name (e.g. 'code-writer', 'commit').
    eval_agent = eval_case.get('agent', '')

    if dry_run:
        exit_code = _dry_run(eval_case, cases_dir, repo_dir)
        return (_STATUS_PASS if exit_code == 0 else _STATUS_ERROR, exit_code)

    # ── Obtain agent output ────────────────────────────────────────────────────
    agent_run_id = ''
    tmp_file_path: Optional[str] = None

    if output_file_path:
        # Primary (deterministic) path: read agent output from a provided file.
        try:
            with open(output_file_path, 'r') as fh:
                captured_output = fh.read()
            actual_output_file = output_file_path
        except OSError as exc:
            print(
                f'ERROR: Cannot read output file {output_file_path!r}: {exc}',
                file=sys.stderr,
            )
            return (_STATUS_ERROR, _EXIT_ERROR)
    else:
        # Live dispatch path (best-effort in Phase A).
        agent_run_id, captured_output = _live_dispatch(eval_case, repo_dir)
        # Write captured output to a temp file so graders can use {output_file}.
        tmp = tempfile.NamedTemporaryFile(
            mode='w', suffix='.txt', delete=False, prefix='cast_eval_'
        )
        tmp.write(captured_output)
        tmp.close()
        tmp_file_path = tmp.name
        actual_output_file = tmp_file_path

    try:
        # ── Run graders ────────────────────────────────────────────────────────
        grader_results: List[dict] = []
        for grader in eval_case.get('graders', []):
            r = _run_grader(
                grader=grader,
                output_file=actual_output_file,
                output=captured_output,
                agent_run_id=agent_run_id,
                session_id=os.environ.get('CAST_SESSION_ID', ''),
                agent=eval_agent,
                since=since,
                repo_dir=repo_dir,
            )
            grader_results.append(r)

        overall_status = _worst_status(grader_results)
        ended_at = datetime.now(timezone.utc).isoformat()
        duration_ms = int((time.monotonic() - start_time) * 1000)

        _print_result(eval_case, grader_results, overall_status)
        _record_eval_run(
            eval_case, grader_results, overall_status, agent_run_id,
            started_at, ended_at, duration_ms,
        )

        exit_map = {
            _STATUS_PASS: _EXIT_PASS,
            _STATUS_FAIL: _EXIT_FAIL,
            _STATUS_SKIP: _EXIT_PASS,  # skip is non-failing at the run level
            _STATUS_ERROR: _EXIT_ERROR,
        }
        return (overall_status, exit_map.get(overall_status, _EXIT_ERROR))

    finally:
        if tmp_file_path and Path(tmp_file_path).exists():
            os.unlink(tmp_file_path)


# ── Subcommand: list ───────────────────────────────────────────────────────────

def cmd_list(args) -> int:
    """List available eval cases, with optional filters."""
    cases_dir = _get_eval_cases_dir()
    if not cases_dir.exists():
        print(
            f'ERROR: evals/cases/ directory not found at {cases_dir}\n'
            f'  Set CAST_EVAL_DIR env var or ensure evals/cases/ exists under repo root.',
            file=sys.stderr,
        )
        return _EXIT_ERROR

    cases = _load_all_cases(cases_dir)

    agent_filter = getattr(args, 'agent', None)
    ft_filter = getattr(args, 'failure_type', None)
    if agent_filter:
        cases = [c for c in cases if c.get('agent') == agent_filter]
    if ft_filter:
        cases = [c for c in cases if c.get('failure_type') == ft_filter]

    if not cases:
        print('No eval cases found matching filters.')
        return _EXIT_PASS

    hdr_id = 'ID'
    hdr_agent = 'AGENT'
    hdr_ft = 'FAILURE_TYPE'
    hdr_cost = 'COST'
    print(f'{hdr_id:<52} {hdr_agent:<22} {hdr_ft:<32} {hdr_cost}')
    print('-' * 116)
    for case in cases:
        print(
            f'{case.get("id",""):<52} '
            f'{case.get("agent",""):<22} '
            f'{case.get("failure_type",""):<32} '
            f'{case.get("cost_tier","")}'
        )
    print(f'\n{len(cases)} case(s) found.')
    return _EXIT_PASS


# ── Subcommand: run ────────────────────────────────────────────────────────────

def cmd_run(args) -> int:
    """Run one or all eval cases and return an overall exit code."""
    cases_dir = _get_eval_cases_dir()
    repo_dir = _get_repo_dir()

    if not cases_dir.exists():
        print(
            f'ERROR: evals/cases/ directory not found at {cases_dir}\n'
            f'  Set CAST_EVAL_DIR env var or ensure evals/cases/ exists under repo root.',
            file=sys.stderr,
        )
        return _EXIT_ERROR

    # Phase A: clamp k to 1.
    k = getattr(args, 'k', 1) or 1
    if k > 1:
        print(
            f'NOTE: k={k} requested — clamped to k=1 (pass@k>1 is Phase B, not yet implemented)',
            file=sys.stderr,
        )

    eval_id: str = args.eval_id
    output_file: Optional[str] = getattr(args, 'output_file', None)
    dry_run: bool = getattr(args, 'dry_run', False)

    if eval_id == '--all':
        cases = _load_all_cases(cases_dir)
        if not cases:
            print('No eval cases found.')
            return _EXIT_ERROR
    else:
        yaml_file = _find_case_file(eval_id, cases_dir)
        if yaml_file is None:
            print(
                f'ERROR: eval case {eval_id!r} not found in {cases_dir}',
                file=sys.stderr,
            )
            return _EXIT_ERROR
        cases = [_load_yaml_file(yaml_file)]

    overall_exit = _EXIT_PASS
    run_results: List[Tuple[str, str]] = []

    for case in cases:
        status, exit_code = _run_case(
            eval_case=case,
            output_file_path=output_file,
            dry_run=dry_run,
            repo_dir=repo_dir,
            cases_dir=cases_dir,
        )
        run_results.append((case.get('id', '?'), status))
        if exit_code > overall_exit:
            overall_exit = exit_code

    if len(cases) > 1:
        print(f'\n{"=" * 64}')
        print(f'{"EVAL ID":<52} STATUS')
        for eid, status in run_results:
            print(f'{eid:<52} {status.upper()}')
        passed = sum(1 for _, s in run_results if s in (_STATUS_PASS, _STATUS_SKIP))
        print(f'\n{passed}/{len(run_results)} passed')

    return overall_exit


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        prog='cast-eval-runner.py',
        description='CAST A3 eval harness runner — Phase A MVP',
    )
    sub = parser.add_subparsers(dest='subcmd')

    # cast eval run
    run_p = sub.add_parser('run', help='Run one or all eval cases')
    run_p.add_argument(
        'eval_id',
        help='Eval case ID (e.g. commit-missing-status-block) or --all',
    )
    run_p.add_argument(
        '--output-file', dest='output_file', metavar='PATH',
        help='Read agent output from this file (deterministic, zero-cost — '
             'primary path for tests and CI)',
    )
    run_p.add_argument(
        '--dry-run', dest='dry_run', action='store_true',
        help='Validate case and print graders; run nothing, write nothing to DB',
    )
    run_p.add_argument(
        '--k', type=int, default=1,
        help='Number of attempts (clamped to 1 in Phase A; pass@k>1 is Phase B)',
    )

    # cast eval list
    list_p = sub.add_parser('list', help='List available eval cases')
    list_p.add_argument('--agent', metavar='NAME', help='Filter by agent name')
    list_p.add_argument(
        '--failure-type', dest='failure_type', metavar='TYPE',
        help='Filter by failure_type (e.g. missing_status_block)',
    )

    args = parser.parse_args()

    if args.subcmd == 'run':
        return cmd_run(args)
    elif args.subcmd == 'list':
        return cmd_list(args)
    else:
        parser.print_help()
        return _EXIT_ERROR


if __name__ == '__main__':
    sys.exit(main())
