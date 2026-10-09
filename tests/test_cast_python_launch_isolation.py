#!/usr/bin/env python3
"""Unit F: CAST launches its own python scripts isolated from PYTHON* env and user site.

PR #421 (U6) moved most launches to `python3 -I`. The rest import sibling modules
(cast_db, ...) and cannot take `-I` (it drops the script dir from sys.path), so they use
`python3 -E -s`: -E ignores PYTHONPATH/PYTHONSTARTUP/... and -s drops the user site, while
the script's own directory stays on sys.path.

Two things are tested:
  1. A self-lint over every place CAST launches a `.py` file from a hook or launchd path
     (scripts/*.sh, macos/*.plist, managed-settings.d/*.json, plugin/hooks/hooks.json): each
     launch must carry `-I` or both `-E` and `-s`. Mutations are applied to a temp COPY of
     those files -- repo files are never modified.
  2. A behaviour probe under a throw-away HOME: a malicious json.py on PYTHONPATH must NOT
     run under `-E -s`, while sibling imports still resolve.
  3. `sys.executable` must not appear AT ALL (outside a comment) in scripts/*.py, scripts/*.sh
     (inline python) or bin/cast -- not as a spawn argv, not aliased (`exe = sys.executable`), not in
     a docstring (reword it): PYTHONEXECUTABLE overrides it even under `-I` /
     `-E -s` on Homebrew python, so the child would EXECUTE an attacker-chosen binary. Spawners use
     `sys._base_executable` (probe: unaffected by PYTHONEXECUTABLE, __PYVENV_LAUNCHER__, PYTHONHOME
     on Apple 3.9 and Homebrew 3.14, bare / `-E -s` / `-I`, system and venv parents).

The real ~/.claude is never touched.
"""
import os
import re
import shutil
import sqlite3
import io
import subprocess
import sys
import tempfile
import tokenize
import unittest
from pathlib import Path

_REPO = Path(__file__).parent.parent

# Globs scanned (relative to the repo root).
_SCAN_GLOBS = (
    'scripts/*.sh',
    'macos/*.plist',
    'managed-settings.d/*.json',
    'plugin/hooks/hooks.json',
    'settings.json',
)
# Files additionally scanned for subprocess-list launches (inline python in .sh, and .py hooks).
_LIST_GLOBS = ('scripts/*.sh', 'scripts/*.py')
# Files scanned for the `[sys.executable, ...]` spawn ban (bin/cast carries inline python heredocs).
_SYSEXE_GLOBS = _LIST_GLOBS + ('bin/cast',)

# Explicit, documented exceptions: (relative path, substring of the offending line) -> reason.
# Keep this list SHORT; every entry must say why the site is not a real launch.
_ALLOWLIST = {
    ('scripts/cast-db-init.sh', 'run: python3 ${_DROP_CHECK_HELPER}'):
        'user-facing WARN message text telling the operator what to type; not executed',
}

# `python3` as a command word (optionally /usr/bin/python3), followed by its argument tail.
_PY_CMD = re.compile(r'(?:^|[\s;&|(`"\'>])(?:/usr/bin/)?python3(?=(?P<tail>(?:\s+\S+)*))')
_PATHISH = re.compile(r'^[$~/.]|\.py\b')
# Flags that mean the interpreter runs inline code / a module, not a script file.
_INLINE_FLAG_CHARS = {'c', 'm'}


# subprocess-list launches: argv lists whose FIRST element is the interpreter, in inline python
# snippets inside scripts/*.sh and in scripts/*.py, e.g.
#   subprocess.run(['python3', '-E', '-s', os.path.join(d, 'x.py')], ...)
#   subprocess.run([sys.executable, '-I', str(script)], ...)
# Heuristic (documented, not a parser): `[` + first element `sys.executable` | 'python3' |
# '/usr/bin/python3' + `,` + the rest of the list up to the first `]`. The leading quoted
# `'-X'` elements are the interpreter flags; the launch passes only with the EXACT forms
# `-I` or `-E -s` (in that order). Lists whose first element is another variable (`[exe, ...]`)
# are not recognised, and a `]` inside the argv ends the list early (harmless: only the
# leading flags are read). Multi-line lists work because the whole file text is scanned.
# `--version`/`-V` probes are not launches.
_PY_LIST = re.compile(
    r"\[\s*(?:sys\.(?:_base_)?executable|['\"](?:/usr/bin/)?python3['\"])\s*,(?P<tail>[^\]]*)\]", re.S)
# Any occurrence of `sys.executable` in the code part of a line: banned outright (module docstring, 3).
# No allowlist: docstrings/prose that need to name it are reworded. Only COMMENTS are exempt:
# in .py files they are found with `tokenize` (so `['#', sys.executable]` and f'#{sys.executable}'
# are still flagged); in .sh / bin/cast a `#` starts a comment only at line start or after
# whitespace and outside single/double quotes. STRING tokens (docstrings) stay flagged.
_SYS_EXE_USE = re.compile(r"\bsys\.executable\b")
_LIST_FLAG = re.compile(r"^\s*['\"](-[A-Za-z-]+)['\"]\s*,?")


def _list_launch_violations(text):
    """(lineno, snippet) for each python argv-list launch lacking the exact `-I` / `-E -s`."""
    out = []
    for m in _PY_LIST.finditer(text):
        tail, flags = m.group('tail'), []
        while True:
            fm = _LIST_FLAG.match(tail)
            if not fm:
                break
            flags.append(fm.group(1))
            tail = tail[fm.end():]
        if flags and flags[0] in ('--version', '-V'):
            continue
        if not _isolated(flags):
            out.append((text.count('\n', 0, m.start()) + 1, ' '.join(m.group(0).split())[:120]))
    return out


def _shell_code_part(line):
    """`line` without a trailing shell/python-style comment: `#` at line start or after whitespace,
    outside quotes. Quote tracking is per line (an apostrophe inside prose BEFORE a `#` hides it:
    the conservative direction -- it can only over-flag)."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == '\\' and quote == '"':
                continue
            if ch == quote and (i == 0 or line[i - 1] != '\\'):
                quote = None
        elif ch in ('"', "'"):
            quote = ch
        elif ch == '#' and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def _py_code_lines(text):
    """Lines of python `text` with every COMMENT token blanked out (via `tokenize`), or None when the
    text does not tokenize (the caller then falls back to the shell rule)."""
    lines = text.split('\n')
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                row, col = tok.start
                lines[row - 1] = lines[row - 1][:col]
    except (tokenize.TokenError, SyntaxError):
        return None
    return lines


def _sys_executable_violations(text, kind='sh'):
    """(lineno, snippet) for each line whose code part uses `sys.executable`. `kind` is 'py' (comments
    found by tokenize) or 'sh' (shell rule; also used for bin/cast and inline python in .sh)."""
    lines = text.split('\n')
    code = _py_code_lines(text) if kind == 'py' else None
    if code is None:
        code = [_shell_code_part(line) for line in lines]
    return [(n, 'sys.executable (use sys._base_executable): ' + ' '.join(lines[n - 1].split())[:100])
            for n, c in enumerate(code, 1) if _SYS_EXE_USE.search(c)]


def _flag_chars(flags):
    chars = set()
    for f in flags:
        if f.startswith('--'):
            continue
        chars.update(f[1:])
    return chars


def _launches_of(line):
    """Every (flags, target) in `line` that launches a script file via python3."""
    line = line.replace('\\"', '"')  # JSON-escaped quotes
    found = []
    for m in _PY_CMD.finditer(line):
        toks = m.group('tail').split()
        flags = []
        while toks and toks[0].startswith('-') and toks[0] != '-':
            flags.append(toks.pop(0))
        if not toks:
            continue  # `python3 -c` with the snippet on the next line, or bare `python3`
        if _flag_chars(flags) & _INLINE_FLAG_CHARS:
            continue
        target = toks[0].strip('"\'')
        if target == '-' or not _PATHISH.search(target):
            continue  # stdin heredoc, or prose like "python3 not found"
        found.append((flags, target))
    return found


def _launch_of(line):
    """First launch in `line` or None (convenience for the classifier tests)."""
    found = _launches_of(line)
    return found[0] if found else None


def _isolated(flags):
    """Only the EXACT leading forms `-I` or `-E -s` (in that order) count.

    scripts/gen-plugin.sh rewrites only the literal `python3 -E -s ` prefix, so `-Es`, `-sE` or
    `-s -E` would pass a looser check yet silently skip the plugin path rewrite.
    """
    return flags[:1] == ['-I'] or flags[:2] == ['-E', '-s']


def find_violations(root):
    """Every non-isolated, non-allowlisted script launch under `root` as (rel, lineno, line)."""
    root = Path(root)
    out = []
    for pattern in _SCAN_GLOBS:
        for path in sorted(root.glob(pattern)):
            rel = path.relative_to(root).as_posix()
            is_sh = path.suffix == '.sh'
            for n, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
                if is_sh and line.lstrip().startswith('#'):
                    continue
                if all(_isolated(flags) for flags, _ in _launches_of(line)):
                    continue
                if any(rel == r and frag in line for (r, frag) in _ALLOWLIST):
                    continue
                out.append((rel, n, line.strip()))
    for pattern in _LIST_GLOBS:
        for path in sorted(root.glob(pattern)):
            rel = path.relative_to(root).as_posix()
            for n, snippet in _list_launch_violations(path.read_text(encoding='utf-8')):
                out.append((rel, n, snippet))
    for pattern in _SYSEXE_GLOBS:
        for path in sorted(root.glob(pattern)):
            rel = path.relative_to(root).as_posix()
            kind = 'py' if path.suffix == '.py' else 'sh'
            for n, snippet in _sys_executable_violations(path.read_text(encoding='utf-8'), kind):
                out.append((rel, n, snippet))
    return out


def _copy_scanned_tree(dst):
    dst = Path(dst)
    for pattern in _SCAN_GLOBS + _SYSEXE_GLOBS:
        for src in sorted(_REPO.glob(pattern)):
            target = dst / src.relative_to(_REPO)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
    return dst


class TestLaunchClassifier(unittest.TestCase):
    """The lint's own parser: it must see launches and ignore non-launches."""

    def test_flags_bare_launch(self):
        for line in ('python3 x.py', 'exec python3 "$D/x.py" --a', 'if /usr/bin/python3 "$X/y.py"; then',
                     'FOO=1 python3 "${H}/s.py" 2>&1', '"command": "python3 \\"${R}/s.py\\""'):
            launch = _launch_of(line)
            self.assertIsNotNone(launch, line)
            self.assertFalse(_isolated(launch[0]), line)

    def test_accepts_isolated_launch(self):
        for line in ('python3 -I x.py', 'python3 -E -s x.py', '/usr/bin/python3 -E -s "$H/x.py"',
                     'python3 -E -s -B x.py'):
            launch = _launch_of(line)
            self.assertIsNotNone(launch, line)
            self.assertTrue(_isolated(launch[0]), line)

    def test_only_exact_flag_forms_are_isolated(self):
        # gen-plugin.sh rewrites only the literal `python3 -E -s ` prefix.
        for line in ('python3 -Es x.py', 'python3 -sE x.py', 'python3 -s -E x.py',
                     'python3 -B -I x.py', 'python3 -Ib x.py'):
            launch = _launch_of(line)
            self.assertIsNotNone(launch, line)
            self.assertFalse(_isolated(launch[0]), line)

    def test_half_isolated_is_a_violation(self):
        for line in ('python3 -E x.py', 'python3 -s x.py', 'python3 -B x.py'):
            launch = _launch_of(line)
            self.assertFalse(_isolated(launch[0]), line)

    def test_second_launch_on_a_line_is_checked(self):
        line = 'x=$(a | python3 -E -s "$D/a.py" | python3 "$D/b.py")'
        self.assertEqual(len(_launches_of(line)), 2)
        self.assertFalse(all(_isolated(f) for f, _ in _launches_of(line)))

    def test_sees_launch_inside_xml_string(self):
        self.assertEqual(len(_launches_of('<string>exec /usr/bin/python3 /h/x.py</string>')), 1)

    def test_list_launch_classifier(self):
        bad = ["subprocess.run(['python3', os.path.join(d, 'x.py')], timeout=5)",
               "subprocess.run([sys.executable, str(script)])", "x = ['/usr/bin/python3', '-s', f]",
               "subprocess.run([sys.executable, '-c', code])", "['python3', '-Es', 'x.py']",
               "x = ['python3', os.path.join(scripts_dir, 'cast_ack.py'),\n 'ARG']",
               "['python3', '-E', os.path.join(d, 'x.py')]", "['python3', '-s', 'x.py']"]
        good = ["subprocess.run(['python3', '-E', '-s', os.path.join(d, 'x.py')])",
                "['python3', '-I', os.path.join(d, 'x.py')]",
                "[sys._base_executable, '-I', str(script), '--db', p]", '["python3", "-I", REDACT, "--x"]',
                "['python3', '--version']"]
        for text in bad:
            self.assertEqual(len(_list_launch_violations(text)), 1, text)
        for text in good:
            self.assertEqual(_list_launch_violations(text), [], text)

    def test_sys_executable_spawn_classifier(self):
        bad = ["subprocess.run([sys.executable, '-I', str(script)])",
               "x = [ sys.executable ,\n '-I', f]", "Popen([sys.executable, '-c', code])",
               "exe = sys.executable", "os.execv(sys.executable, argv)",
               "p = os.path.realpath(sys.executable)", '    \"\"\"NEVER sys.executable here\"\"\"',
               # a `#` that is NOT a comment must not hide a real use (both file kinds)
               "subprocess.run(['#', sys.executable, '-I', x])", "y = f'#{sys.executable}'",
               'z = "# " + sys.executable']
        good = ["subprocess.run([sys._base_executable, '-I', str(script)])",
                "    # [sys.executable, '-I', x] is banned", "exes[0] if exes else sys._base_executable",
                "x = 1  # sys.executable is banned", "y = sys._base_executable", "my_sys.executables = 1"]
        for kind in ('py', 'sh'):
            for text in bad:
                self.assertEqual(len(_sys_executable_violations(text, kind)), 1, (kind, text))
            for text in good:
                self.assertEqual(_sys_executable_violations(text, kind), [], (kind, text))
        # the flag check still sees the new spelling: stripped flags on _base_executable are caught
        self.assertEqual(len(_list_launch_violations("[sys._base_executable, str(s)]")), 1)

    def test_ignores_non_launches(self):
        for line in ('python3 -c "import os"', "python3 - <<'EOF'", 'command -v python3 >/dev/null',
                     'echo "python3 not found"', 'python3 -m json.tool', 'python3 --version'):
            self.assertIsNone(_launch_of(line), line)


class TestPythonLaunchIsolationLint(unittest.TestCase):
    def test_repo_has_no_unisolated_launches(self):
        self.assertEqual(find_violations(_REPO), [])

    def test_lint_actually_sees_launches(self):
        # Guard against a vacuous pass: EVERY scanned category must contribute launches,
        # otherwise a glob or the regex silently matches nothing for that file type
        # (the plist `<string>python3 ...` prefix was once invisible to this scan).
        for pattern in _SCAN_GLOBS:
            seen = 0
            for path in _REPO.glob(pattern):
                for line in path.read_text(encoding='utf-8').splitlines():
                    seen += len(_launches_of(line))
            self.assertGreater(seen, 0, pattern)
        plist_launches = sum(len(_launches_of(line)) for path in _REPO.glob('macos/*.plist')
                             for line in path.read_text(encoding='utf-8').splitlines())
        # Floor, not an inventory: this only guards against the scan going blind (the plist
        # `<string>python3 ...` prefix was once invisible). Adding a plist must not break it.
        self.assertGreaterEqual(plist_launches, 5)

    def test_allowlist_entries_still_exist(self):
        # An allowlist entry for a line that no longer exists is dead weight that could
        # later mask a real launch with the same text.
        for (rel, frag), reason in _ALLOWLIST.items():
            self.assertTrue(reason)
            self.assertIn(frag, (_REPO / rel).read_text(encoding='utf-8'), (rel, frag))

    def test_mutation_bare_launch_in_script_is_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = _copy_scanned_tree(tmp)
            self.assertEqual(find_violations(tree), [])
            with open(tree / 'scripts' / 'post-tool-hook.sh', 'a', encoding='utf-8') as fh:
                fh.write('\npython3 "$(dirname "$0")/evil.py"\n')
            found = find_violations(tree)
            self.assertEqual([v[0] for v in found], ['scripts/post-tool-hook.sh'])

    def test_mutation_stripped_flags_in_plist_are_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = _copy_scanned_tree(tmp)
            plist = tree / 'macos' / 'cast-db-prune.plist'
            text = plist.read_text(encoding='utf-8')
            self.assertIn('python3 -E -s ', text)
            plist.write_text(text.replace('python3 -E -s ', 'python3 '), encoding='utf-8')
            found = find_violations(tree)
            self.assertEqual([v[0] for v in found], ['macos/cast-db-prune.plist'])

    def test_mutation_stripped_flags_in_settings_and_plugin_are_caught(self):
        for rel in ('managed-settings.d/25-hooks-security.json', 'plugin/hooks/hooks.json', 'settings.json'):
            with tempfile.TemporaryDirectory() as tmp:
                tree = _copy_scanned_tree(tmp)
                path = tree / rel
                text = path.read_text(encoding='utf-8')
                self.assertIn('python3 -E -s ', text, rel)
                path.write_text(text.replace('python3 -E -s ', 'python3 '), encoding='utf-8')
                self.assertEqual([v[0] for v in find_violations(tree)], [rel])

    def test_mutation_stripped_flags_in_subprocess_lists_are_caught(self):
        # The three pinned real sites: strip the flags in a temp copy and the lint must fail.
        for rel in ('scripts/cast-events.sh', 'scripts/cast-memory-staleness-sweep.sh'):
            with tempfile.TemporaryDirectory() as tmp:
                tree = _copy_scanned_tree(tmp)
                path = tree / rel
                text = path.read_text(encoding='utf-8')
                n = text.count("['python3', '-E', '-s', ")
                self.assertGreaterEqual(n, 1, rel)
                path.write_text(text.replace("['python3', '-E', '-s', ", "['python3', "), encoding='utf-8')
                found = find_violations(tree)
                self.assertEqual({v[0] for v in found}, {rel})
                self.assertEqual(len(found), n, found)

    def test_repo_subprocess_list_launches_are_present_and_isolated(self):
        # Vacuity floors (not inventories): the list heuristic must still SEE the known sites
        # in both the shell snippets and the .py hooks, and find every one isolated.
        sh_seen = py_seen = 0
        for path in sorted(_REPO.glob('scripts/*.sh')) + sorted(_REPO.glob('scripts/*.py')):
            text = path.read_text(encoding='utf-8')
            n = len(_PY_LIST.findall(text))
            if path.suffix == '.sh':
                sh_seen += n
            else:
                py_seen += n
            self.assertEqual(_list_launch_violations(text), [], path.name)
        self.assertGreaterEqual(sh_seen, 3)
        self.assertGreaterEqual(py_seen, 8)

    def test_mutation_stripped_flags_in_py_hook_lists_are_caught(self):
        cases = {
            'scripts/cast-audit.py': ('["python3", "-I", REDACT_SCRIPT', '["python3", REDACT_SCRIPT'),
            'scripts/cast-pretool-dispatch.py': ('["python3", "-I", os.path.join(SCRIPT_DIR',
                                                 '["python3", os.path.join(SCRIPT_DIR'),
            'scripts/cast_subagent_stop.py': ('["python3", "-I", os.path.join(_HOOK_DIR',
                                              '["python3", os.path.join(_HOOK_DIR'),
            'scripts/cast-git-guard.py': ("['python3', '-E', '-s', os.path.join(scripts_dir",
                                          "['python3', os.path.join(scripts_dir"),
            'scripts/cast-db-prune.py': ("[sys._base_executable, '-I', str(backup_script)",
                                         "[sys._base_executable, str(backup_script)"),
        }
        for rel, (good, bad) in cases.items():
            with tempfile.TemporaryDirectory() as tmp:
                tree = _copy_scanned_tree(tmp)
                self.assertEqual(find_violations(tree), [], rel)
                path = tree / rel
                text = path.read_text(encoding='utf-8')
                self.assertIn(good, text, rel)
                path.write_text(text.replace(good, bad), encoding='utf-8')
                found = find_violations(tree)
                self.assertEqual({v[0] for v in found}, {rel}, (rel, found))

    def test_repo_spawns_use_base_executable(self):
        # Vacuity floor: the scan must still SEE the converted sites (9 in scripts/*.py, 4 in
        # scripts/*.sh inline python, 2 in bin/cast = 15 at the time of writing; the floor is lower so
        # adding or removing a site does not break it), and none uses sys.executable.
        seen = 0
        for pattern in _SYSEXE_GLOBS:
            for path in sorted(_REPO.glob(pattern)):
                text = path.read_text(encoding='utf-8')
                seen += len(re.findall(r"\[\s*sys\._base_executable\s*,", text))
                self.assertEqual(_sys_executable_violations(text, 'py' if path.suffix == '.py' else 'sh'),
                                 [], path.name)
        self.assertGreaterEqual(seen, 12)

    def test_mutation_sys_executable_spawn_is_caught_at_every_site(self):
        # Put `sys.executable` back at each converted site in a temp COPY: the lint must fail on
        # exactly that file, once per site.
        sites = {}
        for pattern in _SYSEXE_GLOBS:
            for path in sorted(_REPO.glob(pattern)):
                n = len(re.findall(r"\[\s*sys\._base_executable\s*,", path.read_text(encoding='utf-8')))
                if n:
                    sites[path.relative_to(_REPO).as_posix()] = n
        self.assertGreaterEqual(len(sites), 10, sites)
        for rel, n in sites.items():
            with tempfile.TemporaryDirectory() as tmp:
                tree = _copy_scanned_tree(tmp)
                self.assertEqual(find_violations(tree), [], rel)
                path = tree / rel
                text = path.read_text(encoding='utf-8')
                path.write_text(re.sub(r"(\[\s*)sys\._base_executable(\s*,)", r"\1sys.executable\2", text),
                                encoding='utf-8')
                found = find_violations(tree)
                self.assertEqual({v[0] for v in found}, {rel}, (rel, found))
                self.assertEqual(len(found), n, (rel, found))

    def test_mutation_aliased_or_bare_sys_executable_is_caught(self):
        # `exe = sys.executable` (an alias that the old `[sys.executable,` regex missed) planted in a
        # temp COPY of a .py spawner, an inline-python .sh and bin/cast must each fail the lint.
        for rel in ('scripts/cast-db-prune.py', 'scripts/agent-status-reader.sh', 'bin/cast'):
            with tempfile.TemporaryDirectory() as tmp:
                tree = _copy_scanned_tree(tmp)
                self.assertEqual(find_violations(tree), [], rel)
                with open(tree / rel, 'a', encoding='utf-8') as fh:
                    fh.write('\nexe = sys.executable\n')
                found = find_violations(tree)
                self.assertEqual([v[0] for v in found], [rel], (rel, found))

    def test_mutation_half_isolated_launch_is_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = _copy_scanned_tree(tmp)
            sh = tree / 'scripts' / 'write-guards.sh'
            text = sh.read_text(encoding='utf-8')
            self.assertIn('python3 -E -s ', text)
            sh.write_text(text.replace('python3 -E -s ', 'python3 -E '), encoding='utf-8')
            self.assertEqual([v[0] for v in find_violations(tree)], ['scripts/write-guards.sh'])


class TestIsolationBehaviour(unittest.TestCase):
    """Behaviour probe: a planted json.py on PYTHONPATH must not execute under -E -s."""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix='cast-pyiso-')
        self.addCleanup(shutil.rmtree, self._tmp, True)
        self.home = Path(self._tmp) / 'home'
        (self.home / '.claude').mkdir(parents=True)
        self.evil = Path(self._tmp) / 'evil'
        self.evil.mkdir()
        self.marker = Path(self._tmp) / 'PWNED'
        (self.evil / 'json.py').write_text(
            'import pathlib\npathlib.Path(%r).write_text("owned")\n' % str(self.marker),
            encoding='utf-8')
        self.env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': str(self.home),
            'CAST_DB_PATH': str(self.home / '.claude' / 'cast.db'),
            'PYTHONPATH': str(self.evil),
            'CAST_INPUT': '{}',
        }

    def _run(self, flags, script, stdin='{}'):
        # -B: never write .pyc into the repo scripts dir (and -E would ignore
        # PYTHONDONTWRITEBYTECODE anyway).
        return subprocess.run([sys.executable, '-B', *flags, str(script)], input=stdin,
                              capture_output=True, text=True, env=self.env,
                              cwd=self._tmp, timeout=60)

    def test_control_unisolated_launch_runs_the_planted_module(self):
        # Proves the probe can fail: without -E the planted json.py really executes.
        self._run([], _REPO / 'scripts' / 'cast-precompact-log.py')
        self.assertTrue(self.marker.exists(), 'probe is vacuous: PYTHONPATH injection did not fire')

    def test_dash_E_s_blocks_pythonpath_injection(self):
        r = self._run(['-E', '-s'], _REPO / 'scripts' / 'cast-precompact-log.py')
        self.assertFalse(self.marker.exists(), 'planted json.py ran under -E -s')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('ImportError', r.stderr)
        self.assertNotIn('ModuleNotFoundError', r.stderr)

    def test_dash_E_s_blocks_pythonpath_for_post_tool_script(self):
        r = self._run(['-E', '-s'], _REPO / 'scripts' / 'cast-post-tool.py')
        self.assertFalse(self.marker.exists(), 'planted json.py ran under -E -s')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_dash_E_s_keeps_script_dir_for_sibling_imports_but_dash_I_does_not(self):
        d = Path(self._tmp) / 'sib'
        d.mkdir()
        (d / 'sibling_mod.py').write_text('VALUE = 42\n', encoding='utf-8')
        main = d / 'main.py'
        main.write_text('import sibling_mod\nprint(sibling_mod.VALUE)\n', encoding='utf-8')
        ok = self._run(['-E', '-s'], main, stdin='')
        self.assertEqual((ok.returncode, ok.stdout.strip()), (0, '42'), ok.stderr)
        isolated = self._run(['-I'], main, stdin='')
        self.assertNotEqual(isolated.returncode, 0)
        self.assertIn('ModuleNotFoundError', isolated.stderr)


_BREW_PY = '/opt/homebrew/bin/python3'

# Loads a spawner script by path and runs its real backup-gate function (which spawns a child).
_PRUNE_HARNESS = (
    'import importlib.util, sys\n'
    'spec = importlib.util.spec_from_file_location("prune_mod", sys.argv[1])\n'
    'mod = importlib.util.module_from_spec(spec)\n'
    'sys.modules["prune_mod"] = mod\n'
    'spec.loader.exec_module(mod)\n'
    'sys.exit(mod._pre_prune_backup())\n'
)


class TestPythonExecutableOverride(unittest.TestCase):
    """F2: PYTHONEXECUTABLE overrides sys.executable even under `-I` / `-E -s` on Homebrew python.

    The real cast-db-prune.py backup gate runs under a throw-away HOME with PYTHONEXECUTABLE
    pointing at a marker-writing fake binary. It must spawn the REAL interpreter (the backup
    really happens) and never the fake. The control re-introduces `sys.executable` in a temp
    COPY and proves the probe can fail (the fake runs).
    """

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix='cast-pyexe-')
        self.addCleanup(shutil.rmtree, self._tmp, True)
        tmp = Path(self._tmp).resolve()
        self.tmp = tmp
        (tmp / 'home' / '.claude' / 'logs').mkdir(parents=True)
        self.marker = tmp / 'FAKE-RAN'
        self.fake = tmp / 'fake-python'
        self.fake.write_text('#!/bin/sh\necho ran >> "%s"\nexit 0\n' % self.marker, encoding='utf-8')
        self.fake.chmod(0o755)
        self.db = tmp / 'cast.db'
        sqlite3.connect(str(self.db)).close()
        self.backups = tmp / 'backups'
        self.env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': str(tmp / 'home'),
            'CAST_DB_PATH': str(self.db),
            'CAST_BACKUP_DIR': str(self.backups),
            'PYTHONEXECUTABLE': str(self.fake),
        }
        (tmp / 'cwd').mkdir()

    def _parents(self):
        seen, out = set(), []
        for exe in (_BREW_PY, '/usr/bin/python3', sys.executable):
            if os.path.exists(exe) and os.path.realpath(exe) not in seen:
                seen.add(os.path.realpath(exe))
                out.append(exe)
        return out

    def _run_gate(self, parent, script, flags):
        if self.marker.exists():
            self.marker.unlink()
        if self.backups.exists():
            shutil.rmtree(self.backups)
        return subprocess.run([parent, *flags, '-c', _PRUNE_HARNESS, str(script)], env=self.env,
                              cwd=str(self.tmp / 'cwd'), capture_output=True, text=True, timeout=120)

    def _backed_up(self):
        return self.backups.is_dir() and any(self.backups.iterdir())

    def _assert_real_child_ran(self, parent, flags, r):
        self.assertFalse(self.marker.exists(), '%s %s: the PYTHONEXECUTABLE fake was executed' % (parent, flags))
        self.assertEqual(r.returncode, 0, '%s %s\n%s\n%s' % (parent, flags, r.stdout, r.stderr[-600:]))
        # non-vacuous: the real interpreter ran the backup child (the fake writes no backup)
        self.assertTrue(self._backed_up(), '%s %s: no backup produced, so no real child ran' % (parent, flags))

    def test_spawner_never_executes_pythonexecutable_fake(self):
        script = _REPO / 'scripts' / 'cast-db-prune.py'
        for parent in self._parents():
            for flags in (('-E', '-s'), ('-I',)):
                with self.subTest(parent=parent, flags=flags):
                    self._assert_real_child_ran(parent, flags, self._run_gate(parent, script, flags))

    @unittest.skipUnless(os.path.exists(_BREW_PY), 'Homebrew python not installed')
    def test_spawner_from_a_homebrew_venv_parent(self):
        venv = self.tmp / 'venv'
        subprocess.run([_BREW_PY, '-m', 'venv', '--without-pip', str(venv)], check=True,
                       capture_output=True, timeout=120)
        script = _REPO / 'scripts' / 'cast-db-prune.py'
        for flags in (('-E', '-s'), ('-I',)):
            with self.subTest(flags=flags):
                parent = str(venv / 'bin' / 'python3')
                self._assert_real_child_ran(parent, flags, self._run_gate(parent, script, flags))

    @unittest.skipUnless(os.path.exists(_BREW_PY), 'Homebrew python not installed')
    def test_control_sys_executable_copy_runs_the_fake_on_homebrew(self):
        # Mutation: `sys.executable` put back in a temp COPY of the spawner. The same probe must
        # now FAIL (the fake runs), proving it discriminates the fixed code from the vulnerable one.
        mut = self.tmp / 'mutant'
        mut.mkdir()
        src = (_REPO / 'scripts' / 'cast-db-prune.py').read_text(encoding='utf-8')
        mutated = src.replace('[sys._base_executable,', '[sys.executable,')
        self.assertNotEqual(src, mutated)
        (mut / 'cast-db-prune.py').write_text(mutated, encoding='utf-8')
        shutil.copy2(_REPO / 'scripts' / 'cast-db-backup.py', mut / 'cast-db-backup.py')
        r = self._run_gate(_BREW_PY, mut / 'cast-db-prune.py', ('-E', '-s'))
        self.assertTrue(self.marker.exists(), 'probe is vacuous: sys.executable did not run the fake\n' + r.stderr[-400:])
        with self.assertRaises(AssertionError):
            self._assert_real_child_ran(_BREW_PY, ('-E', '-s'), r)


if __name__ == '__main__':
    unittest.main()
