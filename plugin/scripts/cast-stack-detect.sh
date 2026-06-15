#!/usr/bin/env bash
# cast-stack-detect.sh — Detect per-repo stack profile and optionally persist to cast.json
# Usage: cast-stack-detect.sh <repo_root> [--write] [--force]
# Output: compact JSON on stdout (always exits 0)
# SUBPROCESS-guarded (CAST hook contract)
set -euo pipefail

# Subprocess bypass
if [[ "${CLAUDE_SUBPROCESS:-}" == "1" ]]; then
  exit 0
fi

REPO_ROOT="${1:-}"
WRITE_FLAG="${2:-}"
FORCE_FLAG="${3:-}"

# ── REPO_ROOT validation (bash-level guard) ────────────────────────────────
# Reject empty values and non-absolute paths (catches the common misparse where
# $1 is a flag like "--write" instead of a repo path, which would make the
# --write logic write relative to cwd). Print the same unknown-fallback shape
# the Python block emits on detection failure, then exit 0.
if [[ -z "$REPO_ROOT" ]] || [[ "${REPO_ROOT:0:1}" != "/" ]]; then
  python3 -c "
import json, sys
from datetime import datetime, timezone
print(json.dumps({'language':'unknown','framework':'unknown','build_cmd':'',
    'test_cmd':'','lint_cmd':'','deploy_style':'dev-server',
    'inferred_at':datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'inferred_by':'cast-stack-detect.sh'}))
"
  exit 0
fi

# Run detection and optional persist via Python stdlib (env-var pattern per python.md)
REPO_ROOT="$REPO_ROOT" \
WRITE_FLAG="$WRITE_FLAG" \
FORCE_FLAG="$FORCE_FLAG" \
python3 << 'PYTHON_BLOCK'
import json, os, re, sys, glob
from datetime import datetime, timezone

REPO_ROOT  = os.environ.get('REPO_ROOT', '')
WRITE_FLAG = os.environ.get('WRITE_FLAG', '')
FORCE_FLAG = os.environ.get('FORCE_FLAG', '')

now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

result = {
    'language':     'unknown',
    'framework':    'unknown',
    'build_cmd':    '',
    'test_cmd':     '',
    'lint_cmd':     '',
    'deploy_style': 'dev-server',
    'inferred_at':  now_iso,
    'inferred_by':  'cast-stack-detect.sh',
}

try:
    def fexists(rel):
        return os.path.isfile(os.path.join(REPO_ROOT, rel))

    # ── Step 0: BATS check first (CAST-specific) ──────────────────────────
    # tests/run.sh takes precedence; fall back to any *.bats file in tests/
    if fexists('tests/run.sh'):
        result['test_cmd'] = 'bash tests/run.sh'
    elif glob.glob(os.path.join(REPO_ROOT, 'tests', '*.bats')):
        result['test_cmd'] = 'bats tests/'

    # ── Step 1: package.json ───────────────────────────────────────────────
    if fexists('package.json'):
        try:
            with open(os.path.join(REPO_ROOT, 'package.json')) as f:
                pkg = json.load(f)
        except Exception:
            pkg = {}

        scripts = pkg.get('scripts', {})
        deps = {}
        deps.update(pkg.get('dependencies', {}))
        deps.update(pkg.get('devDependencies', {}))

        if scripts.get('build'):
            result['build_cmd'] = 'npm run build'
        if scripts.get('lint'):
            result['lint_cmd'] = 'npm run lint'
        # Only set test_cmd from package.json if BATS wasn't already detected
        if scripts.get('test') and not result['test_cmd']:
            result['test_cmd'] = 'npm test'

        # Detect language
        if 'typescript' in deps or '@types/node' in deps:
            result['language'] = 'typescript'
        else:
            result['language'] = 'javascript'

        # Detect framework (precedence: next > react-scripts > vite > express)
        if 'next' in deps:
            result['framework'] = 'next'
        elif 'react-scripts' in deps:
            result['framework'] = 'cra'
        elif 'vite' in deps:
            # vite + typescript → vite-ts; vite without typescript → vite-react
            result['framework'] = 'vite-ts' if result['language'] == 'typescript' else 'vite-react'
        elif 'express' in deps and 'react' not in deps:
            result['framework'] = 'express'

    # ── Step 1b: vite.config / vitest.config detection ───────────────────
    # Presence of a vite/vitest config file confirms the framework even when
    # package.json deps were absent or ambiguous.
    # Note: include: extraction uses best-effort regex, NOT a JS parser —
    # the test_glob field is omitted entirely when not found; never fabricated.
    _vite_configs = ['vite.config.js', 'vite.config.ts', 'vitest.config.js', 'vitest.config.ts']
    _vite_cfg = next((vc for vc in _vite_configs if fexists(vc)), None)
    if _vite_cfg:
        if result['framework'] == 'unknown':
            result['framework'] = 'vite-ts' if result['language'] == 'typescript' else 'vite-react'
        if 'vitest' in _vite_cfg:
            try:
                with open(os.path.join(REPO_ROOT, _vite_cfg)) as f:
                    _cfg_text = f.read()
                _m = re.search(r'include\s*:\s*\[\s*[\'"]([^\'"]+)[\'"]', _cfg_text)
                if _m:
                    result['test_glob'] = _m.group(1)
            except Exception:
                pass  # best-effort regex only — never fabricate

    # Apply -bats suffix when tests/run.sh AND a known JS/TS framework coexist
    if result['test_cmd'] == 'bash tests/run.sh' and result['framework'] not in ('unknown', 'cast-shell'):
        result['framework'] = result['framework'] + '-bats'

    # ── Step 2: pyproject.toml or setup.py ────────────────────────────────
    if result['language'] == 'unknown':
        if fexists('pyproject.toml') or fexists('setup.py'):
            result['language'] = 'python'
            if fexists('pyproject.toml'):
                try:
                    with open(os.path.join(REPO_ROOT, 'pyproject.toml')) as f:
                        content = f.read()
                    if 'pytest' in content and not result['test_cmd']:
                        result['test_cmd'] = 'pytest'
                    if 'ruff' in content and not result['lint_cmd']:
                        result['lint_cmd'] = 'ruff check .'
                except Exception:
                    pass

    # ── Step 3: Makefile ──────────────────────────────────────────────────
    if fexists('Makefile'):
        try:
            with open(os.path.join(REPO_ROOT, 'Makefile')) as f:
                mf = f.read()
            if not result['test_cmd']  and re.search(r'^test:',  mf, re.MULTILINE):
                result['test_cmd']  = 'make test'
            if not result['build_cmd'] and re.search(r'^build:', mf, re.MULTILINE):
                result['build_cmd'] = 'make build'
            if not result['lint_cmd']  and re.search(r'^lint:',  mf, re.MULTILINE):
                result['lint_cmd']  = 'make lint'
        except Exception:
            pass

    # ── Step 4: CAST-specific fallback ────────────────────────────────────
    if result['framework'] == 'unknown':
        cast_scripts = glob.glob(os.path.join(REPO_ROOT, 'scripts', 'cast-*.sh'))
        if cast_scripts:
            result['framework'] = 'cast-shell'
            if result['language'] == 'unknown':
                result['language'] = 'bash'

except Exception:
    # Never crash — fall back to unknown
    result['language']  = 'unknown'
    result['framework'] = 'unknown'

# ── --write: persist to cast.json (best-effort, never crash) ──────────────
if WRITE_FLAG == '--write':
    try:
        cast_json_dir  = os.path.join(REPO_ROOT, '.claude')
        cast_json_path = os.path.join(cast_json_dir, 'cast.json')

        existing = {}
        if os.path.isfile(cast_json_path):
            with open(cast_json_path) as f:
                existing = json.load(f)

        stack = existing.get('stack', {})

        # Respect _manual guard
        if not stack.get('_manual'):
            should_write = True

            # 7-day age check (bypassed when --force)
            if FORCE_FLAG != '--force' and stack.get('inferred_at'):
                try:
                    last_str = stack['inferred_at'].replace('Z', '+00:00')
                    last = datetime.fromisoformat(last_str)
                    age_days = (datetime.now(timezone.utc) - last).days
                    if age_days < 7:
                        should_write = False
                except Exception:
                    pass

            if should_write:
                existing['stack'] = result
                os.makedirs(cast_json_dir, exist_ok=True)
                with open(cast_json_path, 'w') as f:
                    json.dump(existing, f, indent=2)
                    f.write('\n')
    except Exception:
        pass  # best-effort — never crash the caller

print(json.dumps(result))
PYTHON_BLOCK

exit 0
