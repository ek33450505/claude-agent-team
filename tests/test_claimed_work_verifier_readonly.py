"""cast_claimed_work_verifier: read-only agents are skipped, write-capable agents still verified.

Read-only agents (code-reviewer, security) list files they REVIEWED under "Files changed", which
produced 50 of 69 7d [NOT FOUND] rows (measured 2026-10-14). Read-only is derived from the agent
definition's frontmatter `tools:` line (no Write, no Edit), not a hardcoded list. A missing or
unparseable definition fails toward verification.
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).parent.parent / 'scripts' / 'cast_claimed_work_verifier.py'

_RESPONSE = (
    'Reviewed the change set and everything looks reasonable overall, no blocking findings.\n\n'
    'Files changed: /nonexistent-cast-test-dir/ghost_file.py\n\n'
    'Status: DONE\n'
)


def _agent_def(tools_line):
    body = '---\nname: fixture\ndescription: "x"\n'
    if tools_line is not None:
        body += tools_line + '\n'
    return body + 'model: haiku\n---\n\nbody\n'


class VerifierReadOnlyTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        (self.home / '.claude' / 'agents').mkdir(parents=True)
        self.db = self.home / 'cast.db'
        sqlite3.connect(self.db).close()

    def tearDown(self):
        self._tmp.cleanup()

    def _define(self, name, tools_line):
        (self.home / '.claude' / 'agents' / f'{name}.md').write_text(_agent_def(tools_line))

    def _run(self, agent):
        env = {
            'PATH': os.environ.get('PATH', ''),
            'HOME': str(self.home),
            'CAST_DB_PATH': str(self.db),
            'CAST_AGENT_NAME': agent,
            'CAST_SESSION_ID': 'sess-test',
            'CAST_STOP_RESPONSE_TEXT': _RESPONSE,
            'CAST_REPO_ROOT': str(self.home),
        }
        proc = subprocess.run([sys.executable, '-I', str(_SCRIPT)], env=env,
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0)
        return proc.stderr

    def _rows(self):
        con = sqlite3.connect(self.db)
        try:
            return con.execute('SELECT agent_name, actual_value, verified FROM agent_hallucinations').fetchall()
        except sqlite3.OperationalError:
            return []
        finally:
            con.close()

    def test_read_only_agent_is_skipped(self):
        self._define('reviewer-fixture', 'tools: Read, Grep')
        err = self._run('reviewer-fixture')
        self.assertIn('[CAST-VERIFY] agent=reviewer-fixture skipped: read-only agent', err)
        self.assertEqual(self._rows(), [])

    def test_label_suffix_is_stripped_for_lookup(self):
        self._define('reviewer-fixture', 'tools: Read, Grep')
        err = self._run('reviewer-fixture__unit-3')
        self.assertIn('skipped: read-only agent', err)
        self.assertEqual(self._rows(), [])

    def test_write_capable_agent_is_still_flagged(self):
        self._define('writer-fixture', 'tools: Read, Write, Edit, Grep')
        err = self._run('writer-fixture')
        self.assertNotIn('skipped', err)
        self.assertEqual(self._rows(), [('writer-fixture', '[NOT FOUND]', 0)])

    def test_edit_only_agent_is_not_read_only(self):
        self._define('editor-fixture', 'tools: Read, Edit')
        self._run('editor-fixture')
        self.assertEqual(len(self._rows()), 1)

    def test_missing_definition_fails_toward_verification(self):
        err = self._run('no-such-agent')
        self.assertNotIn('skipped', err)
        self.assertEqual(self._rows(), [('no-such-agent', '[NOT FOUND]', 0)])

    def test_definition_without_tools_line_fails_toward_verification(self):
        self._define('toolless-fixture', None)
        self._run('toolless-fixture')
        self.assertEqual(len(self._rows()), 1)

    def test_non_bare_or_write_like_tools_value_is_verified(self):
        cases = {
            'scoped-fixture': 'tools: Read, Write(src/*)',
            'comment-fixture': 'tools: Read, Edit # note',
            'comment2-fixture': 'tools: Read # only reads',
            'flow-fixture': 'tools: [Read,',
            'flow2-fixture': 'tools: [Read, Grep]',
            'multiedit-fixture': 'tools: Read, MultiEdit',
            'notebook-fixture': 'tools: Read, NotebookEdit',
            'yamllist-fixture': 'tools:\n  - Read\n  - Grep',
            'empty-fixture': 'tools:',
            'emptytoken-fixture': 'tools: Read,, Grep',
        }
        for name, line in cases.items():
            with self.subTest(name=name):
                self._define(name, line)
                err = self._run(name)
                self.assertNotIn('skipped', err)
                self.assertEqual([r for r in self._rows() if r[0] == name],
                                 [(name, '[NOT FOUND]', 0)])

    def test_repo_copy_is_never_consulted(self):
        # Installed def has no tools line (inherits all tools); a planted repo copy says Read only.
        self._define('planted-fixture', None)
        core = self.home / 'agents' / 'core'
        core.mkdir(parents=True)
        (core / 'planted-fixture.md').write_text(_agent_def('tools: Read'))
        err = self._run('planted-fixture')
        self.assertNotIn('skipped', err)
        self.assertEqual(len(self._rows()), 1)

    def test_repo_copy_alone_does_not_make_agent_read_only(self):
        core = self.home / 'agents' / 'core'
        core.mkdir(parents=True)
        (core / 'repoonly-fixture.md').write_text(_agent_def('tools: Read'))
        err = self._run('repoonly-fixture')
        self.assertNotIn('skipped', err)
        self.assertEqual(len(self._rows()), 1)


if __name__ == '__main__':
    unittest.main()
