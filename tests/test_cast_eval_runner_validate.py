"""F2 follow-up: cast-eval-runner._validate_case_file (dry-run YAML validation).

With PyYAML importable in the parent, validation runs IN-PROCESS (a child spawned from
sys._base_executable under -I would miss a PyYAML that lives only in the parent's venv).
Without PyYAML it spawns `sys._base_executable -I` -- never sys.executable (PYTHONEXECUTABLE).
"""
import gc
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import warnings
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).resolve().parent.parent
_SRC = _REPO / 'scripts' / 'cast-eval-runner.py'
_VALIDATOR = _REPO / 'scripts' / 'eval-graders' / 'validate-eval-yaml.py'
_spec = importlib.util.spec_from_file_location('cast_eval_runner_validate_under_test', _SRC)
runner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runner)

try:
    import yaml  # noqa: F401
    _HAVE_YAML = True
except ImportError:
    _HAVE_YAML = False


def _good_case():
    """A real, valid eval case from the repo (first one that the validator accepts)."""
    for p in sorted((_REPO / 'evals' / 'cases').glob('*/*.yaml')):
        r = subprocess.run([sys.executable, '-B', str(_VALIDATOR), str(p)], capture_output=True, text=True)
        if r.returncode == 0:
            return p
    raise unittest.SkipTest('no valid eval case found')


class ValidateCaseFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='cast-evalval-')).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    @unittest.skipUnless(_HAVE_YAML, 'PyYAML not installed')
    def test_in_process_path_accepts_valid_and_never_spawns(self):
        good = _good_case()
        with mock.patch.object(runner, '_HAS_YAML', True), \
                mock.patch.object(runner.subprocess, 'run', side_effect=AssertionError('spawned')) as run:
            rc, err = runner._validate_case_file(_VALIDATOR, good)
        self.assertEqual((rc, err), (0, ''))
        run.assert_not_called()

    @unittest.skipUnless(_HAVE_YAML, 'PyYAML not installed')
    def test_in_process_path_reports_invalid(self):
        bad = self.tmp / 'bad.yaml'
        bad.write_text('id: x\n', encoding='utf-8')          # missing required keys
        notyaml = self.tmp / 'broken.yaml'
        notyaml.write_text('a: [unclosed\n', encoding='utf-8')  # YAML parse error -> validator sys.exit(1)
        with mock.patch.object(runner, '_HAS_YAML', True), \
                mock.patch.object(runner.subprocess, 'run', side_effect=AssertionError('spawned')):
            rc, err = runner._validate_case_file(_VALIDATOR, bad)
            self.assertEqual(rc, 1)
            self.assertIn('INVALID', err)
            rc2, err2 = runner._validate_case_file(_VALIDATOR, notyaml)
            self.assertEqual(rc2, 1)
            self.assertIn('INVALID', err2)

    @unittest.skipUnless(_HAVE_YAML, 'PyYAML not installed')
    def test_in_process_path_writes_no_pyc_next_to_the_validator(self):
        # Work on a COPY in a fresh dir (no pre-existing __pycache__) and force bytecode writing ON:
        # an importlib-style load would create <copy dir>/__pycache__; compile+exec must not.
        copy_dir = self.tmp / 'validator-copy'
        copy_dir.mkdir()
        copy = copy_dir / 'validate-eval-yaml.py'
        shutil.copy2(_VALIDATOR, copy)
        good = _good_case()
        # `_validate_case_file` captures stderr, so a stray finalizer message from an EARLIER test's
        # unclosed sqlite connection (ResourceWarning, "Exception ignored while finalizing ...") that
        # happens to be collected mid-call lands in `err` (order-dependent in full discover, 1/1929).
        # Collect first, keep the cycle GC off for the call, and ignore warnings: the assertions stay
        # strict about the validator's own output.
        gc.collect()
        gc.disable()
        try:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                with mock.patch.object(runner, '_HAS_YAML', True), \
                        mock.patch.object(sys, 'dont_write_bytecode', False):
                    rc, err = runner._validate_case_file(copy, good)
        finally:
            gc.enable()
        self.assertEqual(rc, 0, err)
        self.assertEqual(err, '', 'validator wrote to stderr: %r' % err)
        self.assertEqual(list(copy_dir.rglob('*.pyc')), [])
        self.assertFalse((copy_dir / '__pycache__').exists(), list(copy_dir.iterdir()))

    @unittest.skipUnless(_HAVE_YAML, 'PyYAML not installed')
    def test_in_process_validator_crash_is_invalid_not_an_exception(self):
        crashing = self.tmp / 'crashing-validator.py'
        crashing.write_text("def validate(p):\n    raise RuntimeError('boom')\n", encoding='utf-8')
        with mock.patch.object(runner, '_HAS_YAML', True):
            rc, err = runner._validate_case_file(crashing, self.tmp / 'x.yaml')
        self.assertEqual(rc, 1)
        self.assertIn('validator crashed', err)
        self.assertIn('boom', err)

    def test_without_yaml_it_spawns_the_base_interpreter_isolated(self):
        done = subprocess.CompletedProcess([], 0, stdout='', stderr='')
        # Distinct sentinels so a regression to sys.executable cannot pass by being equal to it.
        with mock.patch.object(runner, '_HAS_YAML', False), \
                mock.patch.object(sys, '_base_executable', '/sentinel/base-python'), \
                mock.patch.object(sys, 'executable', '/sentinel/planted-python'), \
                mock.patch.object(runner.subprocess, 'run', return_value=done) as run:
            rc, err = runner._validate_case_file(_VALIDATOR, self.tmp / 'x.yaml')
        self.assertEqual((rc, err), (0, ''))
        argv = run.call_args.args[0]
        self.assertEqual(argv[:2], ['/sentinel/base-python', '-I'])
        self.assertEqual(argv[2:], [str(_VALIDATOR), str(self.tmp / 'x.yaml')])

    def test_without_yaml_nonzero_child_is_invalid_with_stderr(self):
        failed = subprocess.CompletedProcess([], 1, stdout='', stderr='INVALID: nope\n')
        with mock.patch.object(runner, '_HAS_YAML', False), \
                mock.patch.object(runner.subprocess, 'run', return_value=failed):
            self.assertEqual(runner._validate_case_file(_VALIDATOR, self.tmp / 'x.yaml'), (1, 'INVALID: nope\n'))

    @unittest.skipUnless(_HAVE_YAML and os.path.exists('/opt/homebrew/bin/python3'),
                         'needs PyYAML and Homebrew python')
    def test_dry_run_with_pythonexecutable_fake_prints_ok_and_runs_no_fake(self):
        # End to end on both paths: the real _dry_run under a hook-like parent with
        # PYTHONEXECUTABLE planted. With yaml (in-process) and without (spawn) the fake never runs.
        marker = self.tmp / 'FAKE-RAN'
        fake = self.tmp / 'fake-python'
        fake.write_text('#!/bin/sh\necho ran >> "%s"\nexit 0\n' % marker, encoding='utf-8')
        fake.chmod(0o755)
        harness = (
            'import importlib.util, sys\n'
            'from pathlib import Path\n'
            'spec = importlib.util.spec_from_file_location("r", sys.argv[1])\n'
            'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
            'm._HAS_YAML = (sys.argv[3] == "yaml")\n'
            'sys.exit(m._dry_run({"id": sys.argv[4]}, Path(sys.argv[2]) / "evals" / "cases", Path(sys.argv[2])))\n'
        )
        case = _good_case()
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(self.tmp),
               'PYTHONEXECUTABLE': str(fake)}
        for mode in ('yaml', 'noyaml'):
            with self.subTest(mode=mode):
                if marker.exists():
                    marker.unlink()
                r = subprocess.run(['/opt/homebrew/bin/python3', '-E', '-s', '-B', '-c', harness, str(_SRC),
                                    str(_REPO), mode, case.stem], env=env, cwd=str(self.tmp),
                                   capture_output=True, text=True, timeout=120)
                self.assertFalse(marker.exists(), 'PYTHONEXECUTABLE fake was executed')
                # the spawn path is the one that could have run the fake; the real child must say OK
                self.assertIn('validation:   OK', r.stdout, r.stdout + r.stderr[-400:])


if __name__ == '__main__':
    unittest.main()
