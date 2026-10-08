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

The real ~/.claude is never touched.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_REPO = Path(__file__).parent.parent

# Globs scanned (relative to the repo root).
_SCAN_GLOBS = (
    'scripts/*.sh',
    'macos/*.plist',
    'managed-settings.d/*.json',
    'plugin/hooks/hooks.json',
)
# Files additionally scanned for subprocess-list launches (inline python in .sh, and .py hooks).
_LIST_GLOBS = ('scripts/*.sh', 'scripts/*.py')

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
    r"\[\s*(?:sys\.executable|['\"](?:/usr/bin/)?python3['\"])\s*,(?P<tail>[^\]]*)\]", re.S)
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
    return out


def _copy_scanned_tree(dst):
    dst = Path(dst)
    for pattern in _SCAN_GLOBS + _LIST_GLOBS:
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
                "[sys.executable, '-I', str(script), '--db', p]", '["python3", "-I", REDACT, "--x"]',
                "['python3', '--version']"]
        for text in bad:
            self.assertEqual(len(_list_launch_violations(text)), 1, text)
        for text in good:
            self.assertEqual(_list_launch_violations(text), [], text)

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
        self.assertGreaterEqual(plist_launches, 7)

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
        for rel in ('managed-settings.d/25-hooks-security.json', 'plugin/hooks/hooks.json'):
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
            'scripts/cast-db-prune.py': ("[sys.executable, '-I', str(backup_script)",
                                         "[sys.executable, str(backup_script)"),
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


if __name__ == '__main__':
    unittest.main()
