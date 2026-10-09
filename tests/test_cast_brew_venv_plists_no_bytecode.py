#!/usr/bin/env python3
"""The launchd jobs that run Homebrew venv tools must not write .pyc files.

looptrip (com.cast.looptrip-scan) and misfire (com.cast.misfire-audit) are Homebrew
python-3.13 venvs. looptrip loads ~/.claude/scripts/cast_db.py by path, which drops
__pycache__/cast_db.cpython-313.pyc; cast-install-integrity.py has no 3.13 candidate,
so that pyc raised a `pyc-unverified` alarm daily. PYTHONDONTWRITEBYTECODE=1 in the
job environment stops the pyc being written at all (the candidate list is intentionally
NOT widened).
"""
import plistlib
import unittest
from pathlib import Path

_MACOS = Path(__file__).parent.parent / 'macos'
_PLISTS = ('cast-looptrip-scan.plist', 'cast-misfire-audit.plist')


class BrewVenvPlistEnvTests(unittest.TestCase):
    def test_plists_disable_bytecode_writing(self):
        for name in _PLISTS:
            with self.subTest(plist=name):
                with open(_MACOS / name, 'rb') as fh:
                    data = plistlib.load(fh)
                env = data['EnvironmentVariables']
                self.assertEqual(env.get('PYTHONDONTWRITEBYTECODE'), '1')
                # the pre-existing env must survive
                self.assertIn('PATH', env)
                self.assertIn('HOME', env)


if __name__ == '__main__':
    unittest.main()
