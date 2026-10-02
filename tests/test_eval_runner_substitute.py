"""Tests for cast-eval-runner._substitute (audit S-8: single-pass substitution)."""
import importlib.util
import shlex
import unittest
from pathlib import Path

_SRC = Path(__file__).resolve().parent.parent / 'scripts' / 'cast-eval-runner.py'
_spec = importlib.util.spec_from_file_location('cast_eval_runner', _SRC)
runner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runner)


def _old_substitute(cmd, output_file, output, agent_run_id, session_id, agent='', since=''):
    """Reference: the pre-S-8 sequential whole-string replace algorithm."""
    subs = {
        'output_file': output_file, 'output': output, 'agent_run_id': agent_run_id,
        'session_id': session_id, 'agent': agent, 'since': since,
    }
    for key, value in subs.items():
        quoted = shlex.quote(value)
        cmd = cmd.replace(f"'{{{key}}}'", quoted)
        cmd = cmd.replace(f'{{{key}}}', quoted)
    return cmd


class SubstituteTests(unittest.TestCase):
    ARGS = dict(output_file='/tmp/o f.txt', output='hello world', agent_run_id='abc123',
                session_id='11111111-2222-3333-4444-555555555555',
                agent='backend-writer', since='2026-10-02T00:00:00Z')

    def test_equivalent_to_old_algorithm_for_normal_templates(self):
        templates = [
            "cat '{output_file}'",
            "cat {output_file}",
            "echo '{output}' {agent} '{since}'",
            "x '{session_id}' {session_id} '{session_id}' {agent_run_id}",
            "echo {foo} '{bar}' {output_file} {unknown}",
            "no placeholders here",
            "",
            "{{output}} '{output'",
        ]
        for t in templates:
            with self.subTest(template=t):
                self.assertEqual(runner._substitute(t, **self.ARGS),
                                 _old_substitute(t, **self.ARGS))

    def test_unknown_tokens_untouched(self):
        self.assertEqual(runner._substitute("echo {foo} '{bar}'", **self.ARGS),
                         "echo {foo} '{bar}'")

    def test_value_containing_tokens_is_not_resubstituted(self):
        evil_output = "pre {session_id} mid '{agent}' post"
        args = dict(self.ARGS, output=evil_output, session_id="x'; touch /tmp/pwn; '")
        cmd = runner._substitute("grader --resp '{output}' --sid {session_id}", **args)
        parts = shlex.split(cmd)
        self.assertEqual(parts, ['grader', '--resp', evil_output, '--sid', args['session_id']])

    def test_adversarial_bare_form(self):
        evil_output = "{session_id}'{agent}'"
        args = dict(self.ARGS, output=evil_output, session_id="x'; touch /tmp/pwn; '")
        parts = shlex.split(runner._substitute("g {output} {agent}", **args))
        self.assertEqual(parts, ['g', evil_output, 'backend-writer'])


if __name__ == '__main__':
    unittest.main()
