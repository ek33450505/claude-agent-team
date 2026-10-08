#!/usr/bin/env python3
"""U6c-1: child interpreters launched via sys.executable run isolated (`-I`).

A bare `[sys.executable, script]` child inherits PYTHONPATH (and the user site) from the
hook/launchd environment, so a planted `json.py` / `sqlite3.py` on that path executes in the
child. `-I` ignores PYTHON* env and drops the user site. (`-I` also drops the script's own dir
from sys.path, so every isolated child must be stdlib-only -- cast-db-backup.py and
cast-db-rollup.py are; validate-eval-yaml.py only needs PyYAML from the system site.)

  1. Behaviour  - control: a planted sqlite3.py/json.py on PYTHONPATH IS executed by the real
                  backup child when launched bare; then each parent's launch function runs
                  with that PYTHONPATH exported and must NOT execute it, and must still
                  succeed (the child really ran).
  2. Static     - every `[sys.executable, ...]` launch in scripts/ and bin/ carries `-I`.

The parents run under `python3 -E` (ignores PYTHONPATH for themselves) with cwd = a scratch
dir, so only the CHILD launch is exposed to the planted modules. Everything lives in a temp
HOME / CAST_DB_PATH; the real ~/.claude and cast.db are never touched.
"""
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / 'scripts'

# name of the launch function in each parent, and the call expression to run it
_SITES = {
    'cast-migrate.py': '_pre_migration_backup(os.environ["CAST_DB_PATH"])',
    'cast-db-prune.py': '_pre_prune_backup()',
    'cast-snapshot.py': '_invoke_db_backup()',
    'cast-memory-consolidate.py': '_pre_consolidate_backup(os.environ["CAST_DB_PATH"])',
    'cast-recost-agent-runs.py': '_backup_gate()',
}

_PLANT = 'import os\nopen(os.environ["CAST_PLANT_MARKER"], "a").write(__file__ + " argv0=" + __import__("sys").argv[0] + "\\n")\n'

_HARNESS = textwrap.dedent('''
    import importlib.util, os, sys
    sys.path.insert(0, os.path.dirname(sys.argv[1]))  # parent's own sibling imports (cast_guard...)
    spec = importlib.util.spec_from_file_location("parent_mod", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    sys.modules["parent_mod"] = mod
    spec.loader.exec_module(mod)
    ns = {"os": os, **vars(mod)}
    rc = eval(sys.argv[2], ns)
    # _invoke_db_backup returns a dict (error key on failure); the others return an int rc
    ok = (rc == 0) if isinstance(rc, int) else ("error" not in rc)
    sys.exit(0 if ok else 3)
''')


class ChildIsolationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name).resolve()
        self.home = self.tmp / 'home'
        (self.home / '.claude' / 'logs').mkdir(parents=True)
        self.plant = self.tmp / 'plant'
        self.plant.mkdir()
        (self.plant / 'json.py').write_text(_PLANT)
        (self.plant / 'sqlite3.py').write_text(_PLANT)
        self.marker = self.tmp / 'marker'
        self.cwd = self.tmp / 'cwd'
        self.cwd.mkdir()
        self.db = self.tmp / 'cast.db'
        con = sqlite3.connect(str(self.db))
        con.execute('CREATE TABLE t (x)')
        con.commit()
        con.close()
        self.env = {
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'HOME': str(self.home),
            'CAST_DB_PATH': str(self.db),
            'CAST_BACKUP_DIR': str(self.tmp / 'backups'),
            'CAST_PLANT_MARKER': str(self.marker),
            'PYTHONPATH': str(self.plant),
        }

    def _marker(self):
        return self.marker.read_text() if self.marker.exists() else ''

    def test_control_planted_module_executes_in_bare_child(self):
        """Proves the plant is live: the real backup child, launched bare, imports it."""
        subprocess.run([sys.executable, str(SCRIPTS / 'cast-db-backup.py')], env=self.env,
                       cwd=str(self.cwd), capture_output=True, text=True, timeout=60)
        self.assertIn('plant', self._marker(), 'control failed: planted module was not imported')

    def test_parents_launch_children_isolated(self):
        for script, call in _SITES.items():
            with self.subTest(parent=script):
                if self.marker.exists():
                    self.marker.unlink()
                r = subprocess.run(
                    [sys.executable, '-E', '-c', _HARNESS, str(SCRIPTS / script), call],
                    env=self.env, cwd=str(self.cwd), capture_output=True, text=True, timeout=120)
                self.assertEqual(self._marker(), '',
                                 f'{script}: child imported a planted module from PYTHONPATH')
                # non-vacuous: the isolated child really ran and the backup succeeded
                self.assertEqual(r.returncode, 0, f'{script}: launch failed\n{r.stdout}\n{r.stderr[-800:]}')


class StaticLaunchTests(unittest.TestCase):
    def test_every_sys_executable_launch_is_isolated(self):
        files = [p for p in list(SCRIPTS.glob('*.py')) + list(SCRIPTS.glob('*.sh')) + [REPO / 'bin' / 'cast']
                 if p.is_file()]
        launch = re.compile(r'\[\s*sys\.executable\s*,\s*(?P<next>[^,\]]+)')
        sites, offenders = 0, []
        for p in files:
            for n, line in enumerate(p.read_text(errors='replace').splitlines(), 1):
                if line.lstrip().startswith('#'):
                    continue
                for m in launch.finditer(line):
                    sites += 1
                    if m.group('next').strip().strip('"\'') != '-I':
                        offenders.append(f'{p.relative_to(REPO)}:{n}: {line.strip()}')
        self.assertGreater(sites, 5, 'scan is vacuous: too few sys.executable launch sites found')
        self.assertEqual(offenders, [], 'sys.executable child launched without -I')


if __name__ == '__main__':
    unittest.main()
