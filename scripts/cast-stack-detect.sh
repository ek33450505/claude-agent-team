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
  python3 -I -c "
import json, sys
from datetime import datetime, timezone
print(json.dumps({'language':'unknown','framework':'unknown','build_cmd':'',
    'test_cmd':'','lint_cmd':'','deploy_style':'dev-server',
    'inferred_at':datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'inferred_by':'cast-stack-detect.sh'}))
"
  exit 0
fi

# ── --write target gate (bash half) ────────────────────────────────────────
# --write persists <REPO_ROOT>/.claude/cast.json, so REPO_ROOT must be a real git work-tree
# top-level. Ask git (via the hardened cast_git_safe: REPO_ROOT is caller/agent-steerable and
# repo config can otherwise make git run programs) for the top-level of REPO_ROOT; the Python
# half compares it with REPO_ROOT and also refuses ~/.claude and $HOME. Any failure to load the
# lib or run git leaves GIT_TOPLEVEL empty, which the Python half treats as "do not write".
GIT_TOPLEVEL=""
GATE_NOTE=""
if [[ "$WRITE_FLAG" == "--write" ]]; then
  _SD_DIR="$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)" || _SD_DIR=""
  _SD_LIB="$_SD_DIR/cast-hook-lib.sh"
  # unset first: an inherited _CAST_HOOK_LIB_LOADED / exported function must not stand in for the lib
  unset -f cast_git_safe 2>/dev/null || true
  unset _CAST_HOOK_LIB_LOADED
  _SD_LIB_OK=0
  # (-r first: bash 3.2 exits the shell silently on a failed `source` of a missing file.)
  if [[ -n "$_SD_DIR" && -r "$_SD_LIB" ]]; then
    # shellcheck source=cast-hook-lib.sh
    # shellcheck source-path=SCRIPTDIR
    if source "$_SD_LIB" 2>/dev/null && declare -F cast_git_safe >/dev/null 2>&1; then
      _SD_LIB_OK=1
    fi
  fi
  if [[ "$_SD_LIB_OK" == "1" ]]; then
    GIT_TOPLEVEL="$(cast_git_safe "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" || GIT_TOPLEVEL=""
    [[ -n "$GIT_TOPLEVEL" ]] || GATE_NOTE="git could not report a work-tree top-level for the target"
  else
    GATE_NOTE="cast-hook-lib.sh could not be loaded (cannot verify the target is a git work tree)"
  fi
fi

# Run detection and optional persist via Python stdlib (env-var pattern per python.md)
REPO_ROOT="$REPO_ROOT" \
WRITE_FLAG="$WRITE_FLAG" \
FORCE_FLAG="$FORCE_FLAG" \
GIT_TOPLEVEL="$GIT_TOPLEVEL" \
GATE_NOTE="$GATE_NOTE" \
python3 -I << 'PYTHON_BLOCK'
import errno, json, os, re, stat, sys, glob
from datetime import datetime, timezone

REPO_ROOT  = os.environ.get('REPO_ROOT', '')
WRITE_FLAG = os.environ.get('WRITE_FLAG', '')
FORCE_FLAG = os.environ.get('FORCE_FLAG', '')
GIT_TOPLEVEL = os.environ.get('GIT_TOPLEVEL', '')
GATE_NOTE = os.environ.get('GATE_NOTE', '')

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
def _home_refusal(path):
    """Reason when `path` (a realpath) is $HOME or inside ~/.claude, else ''."""
    home = os.path.realpath(os.path.expanduser('~'))
    claude_home = os.path.join(home, '.claude')
    if path == home or path == claude_home or path.startswith(claude_home + os.sep):
        return 'target is $HOME or under ~/.claude'
    return ''


def write_refusal():
    """Why --write must not persist, or '' when REPO_ROOT is acceptable. It is acceptable only
    when it is the top-level of a real git work tree AND is not ~/.claude (or anything under
    it) or $HOME itself. A repo subdirectory (scripts/, managed-settings.d/) has a different
    git top-level, so it is refused. Fails closed: no top-level => refusal."""
    if not GIT_TOPLEVEL:
        return GATE_NOTE or 'git could not report a work-tree top-level for the target'
    real = os.path.realpath(REPO_ROOT)
    if os.path.realpath(GIT_TOPLEVEL) != real:
        return 'target is not a git work-tree top-level (it is a subdirectory or not the repo root)'
    return _home_refusal(real)


def profile_core(d):
    """The stack profile minus its timestamp: what 'changed' means for a rewrite."""
    return {k: v for k, v in d.items() if k != 'inferred_at'}


_refusal = write_refusal() if WRITE_FLAG == '--write' else ''
if _refusal:
    print(f'cast-stack-detect: --write skipped: {_refusal}', file=sys.stderr)

class Refuse(Exception):
    """--write must not touch the target; str(e) is the one-line reason."""


# RESIDUAL TOCTOU: the bash git-toplevel gate (cast_git_safe rev-parse) and this write are
# separate steps. Swapping an ANCESTOR of the repo root (for a symlink) between them could
# redirect the write, but that needs write access above the repo root, which an agent confined
# to the repo does not have. Everything below the resolved root is fd-relative and O_NOFOLLOW.
def persist_stack(real_root):
    """Write <real_root>/.claude/cast.json without ever following a planted link.

    The repo is agent-writable, so `.claude` and `cast.json` can be symlinks into ~/.claude
    (config/policies.json, scripts/, ...), or hardlinks. Rules: `.claude` must be a real
    directory (O_NOFOLLOW); cast.json, if present, a regular file with one link; the new
    content is staged in a tmp file created inside that directory (O_EXCL|O_NOFOLLOW) and
    renamed over cast.json, all relative to an O_NOFOLLOW directory fd, so a swap after the
    checks cannot redirect the write. real_root is the realpath resolved ONCE by the caller.
    """
    cast_dir = os.path.join(real_root, '.claude')
    try:
        dst = os.lstat(cast_dir)
    except FileNotFoundError:
        dst = None
    if dst is not None and (stat.S_ISLNK(dst.st_mode) or not stat.S_ISDIR(dst.st_mode)):
        raise Refuse('<repo>/.claude is a symlink or not a directory')
    reason = _home_refusal(os.path.realpath(cast_dir))
    if reason:
        raise Refuse(reason)

    def open_dir():
        try:
            return os.open(cast_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as e:
            if e.errno in (errno.ELOOP, errno.ENOTDIR):
                raise Refuse('<repo>/.claude is a symlink or not a directory')
            raise

    dir_fd = open_dir() if dst is not None else None
    try:
        existing = {}
        mode = None  # None => new file: created 0o666 & ~umask by open(2) itself
        if dir_fd is not None:
            # Classify BEFORE opening: opening a FIFO read-only blocks until a writer appears
            # (a planted FIFO named cast.json would hang the CwdChanged hook), and a device
            # node can have side effects. lstat-style, relative to the verified directory fd.
            try:
                pre = os.stat('cast.json', dir_fd=dir_fd, follow_symlinks=False)
            except FileNotFoundError:
                pre = None
            if pre is not None:
                if stat.S_ISLNK(pre.st_mode):
                    raise Refuse('<repo>/.claude/cast.json is a symlink')
                if not stat.S_ISREG(pre.st_mode):
                    raise Refuse('<repo>/.claude/cast.json is not a regular file')
                # O_NONBLOCK: if the name is swapped for a FIFO after the check, open() must
                # not block; the fstat re-check below then refuses it.
                try:
                    fd = os.open('cast.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=dir_fd)
                except OSError as e:
                    if e.errno == errno.ELOOP:
                        raise Refuse('<repo>/.claude/cast.json is a symlink')
                    raise
                with os.fdopen(fd) as f:
                    st = os.fstat(f.fileno())
                    if not stat.S_ISREG(st.st_mode):
                        raise Refuse('<repo>/.claude/cast.json is not a regular file')
                    if st.st_nlink > 1:
                        raise Refuse('<repo>/.claude/cast.json has multiple hard links')
                    os.set_blocking(f.fileno(), True)  # clear O_NONBLOCK before reading
                    mode = stat.S_IMODE(st.st_mode)
                    existing = json.load(f)

        stack = existing.get('stack', {})
        # Respect _manual guard
        if stack.get('_manual'):
            return

        # 7-day age check (bypassed when --force)
        if FORCE_FLAG != '--force' and stack.get('inferred_at'):
            try:
                last = datetime.fromisoformat(stack['inferred_at'].replace('Z', '+00:00'))
                if (datetime.now(timezone.utc) - last).days < 7:
                    return
            except Exception:
                pass

        # Unchanged profile (ignoring the timestamp): do not rewrite - a bare
        # inferred_at bump only churns the tracked .claude/cast.json.
        if stack and profile_core(stack) == profile_core(result):
            return

        existing['stack'] = result
        if dir_fd is None:
            os.mkdir(cast_dir, 0o755)
            dir_fd = open_dir()
        tmp_name = '.cast.json.tmp-%d-%s' % (os.getpid(), os.urandom(6).hex())
        tmp_fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o666, dir_fd=dir_fd)
        try:
            with os.fdopen(tmp_fd, 'w') as f:
                if mode is not None:  # existing file: keep its mode (new file: umask applied)
                    os.fchmod(f.fileno(), mode)
                json.dump(existing, f, indent=2)
                f.write('\n')
            os.replace(tmp_name, 'cast.json', src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except BaseException:
            try:
                os.unlink(tmp_name, dir_fd=dir_fd)
            except OSError:
                pass
            raise
    finally:
        if dir_fd is not None:
            os.close(dir_fd)


if WRITE_FLAG == '--write' and not _refusal:
    try:
        # Resolve the root ONCE and write only through the resolved path
        persist_stack(os.path.realpath(REPO_ROOT))
    except Refuse as e:
        print(f'cast-stack-detect: --write skipped: {e}', file=sys.stderr)
    except Exception:
        pass  # best-effort - never crash the caller

print(json.dumps(result))
PYTHON_BLOCK

exit 0
