"""cast_claimed_work_verifier: extract_file_paths is linear, and equivalent to the pre-rewrite code.

Two quadratic spots, both reachable from untrusted agent output, against a ~15 s SubagentStop
hook timeout (the verifier runs in its stage 9):

* Pattern 2: the single regex
      ```json\\s+status[\\s\\S]*?"files_changed"\\s*:\\s*\\[([\\s\\S]*?)\\]
  retried from every "```json status" fence (and every `"files_changed": [` opener) and each lazy
  scan ran to EOF. _json_status_paths() is the exact-equivalent linear rewrite.
* Pattern 1: the two findalls over the `Files changed:` section start a match at every
  whitespace char and `\\s*` rescans the rest of the run (O(N^2) in the run length). The section
  is now squeezed (`\\s{16,}` -> two spaces) first.

These tests pin (a) equivalence against the pre-rewrite code embedded here as oracles (the whole of
HEAD's extract_file_paths, crafted + seeded fuzz) and (b) that adversarial 600 KB inputs finish
well inside the hook budget.

Pure functions only: no HOME, DB, or filesystem access.
"""
import importlib.util
import random
import re
import time
import unittest
from pathlib import Path

_SCRIPT = Path(__file__).parent.parent / 'scripts' / 'cast_claimed_work_verifier.py'

_spec = importlib.util.spec_from_file_location('cast_claimed_work_verifier_under_test', _SCRIPT)
verifier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verifier)

# Generous CI bound; the quadratic code needs tens of seconds on these inputs.
_BUDGET_SECONDS = 2.0
_SIZE = 600_000


def _old_pattern2_paths(text: str) -> set:
    """Oracle: the pre-rewrite Pattern 2, verbatim."""
    paths = set()
    json_match = re.search(
        r'```json\s+status[\s\S]*?"files_changed"\s*:\s*\[([\s\S]*?)\]', text)
    if json_match:
        array_text = json_match.group(1)
        paths.update(re.findall(r'"([^"]+\.[a-zA-Z0-9]+)"', array_text))
    return paths


def _old_extract_file_paths(response_text: str) -> list:
    """Oracle: HEAD's extract_file_paths (pre-linear-rewrite), verbatim.

    Only change: `_PROSE_FALSE_POSITIVES` is read from the module under test (that set is not
    touched by the rewrite).
    """
    _PROSE_FALSE_POSITIVES = verifier._PROSE_FALSE_POSITIVES
    paths = set()

    # Pattern 1: Files changed: section (markdown)
    m = re.search(r'(?:Files changed|files_changed)\s*:\s*([\s\S]+?)(?=\n\n|$)', response_text)
    if m:
        section = m.group(1)
        # Extract paths from the section (dash list, comma list, or paths)
        path_matches = re.findall(r'(?:^|\s)[-*]?\s*(/[a-zA-Z0-9_./\-]+\.[a-zA-Z0-9]+)\b', section, re.MULTILINE)
        paths.update(path_matches)
        # Also try relative paths (no leading slash)
        path_matches = re.findall(r'(?:^|\s)[-*]?\s*([a-zA-Z0-9_][a-zA-Z0-9_./\-]*\.[a-zA-Z0-9]+)\b', section, re.MULTILINE)
        paths.update(
            p for p in path_matches
            if p.lower() not in _PROSE_FALSE_POSITIVES
            and ('/' in p or p.endswith(('.sh', '.py', '.md', '.yml', '.yaml', '.json', '.bats', '.ts', '.js', '.rb')))
        )

    # Pattern 2: files_changed array in JSON status block
    json_match = re.search(r'```json\s+status[\s\S]*?"files_changed"\s*:\s*\[([\s\S]*?)\]', response_text)
    if json_match:
        array_text = json_match.group(1)
        json_paths = re.findall(r'"([^"]+\.[a-zA-Z0-9]+)"', array_text)
        paths.update(json_paths)

    return list(paths)


_CASES = {
    'no_fence': 'prose only\n"files_changed": ["a.py"]\n',
    'fence_and_array': '```json status\n{"files_changed": ["a.py", "b/c.sh"]}\n```\n',
    'files_changed_before_fence_only': '"files_changed": ["a.py"]\n```json status\n{"x": 1}\n```\n',
    'array_after_second_fence': (
        '```json status\n{"status": "DONE"}\n```\n'
        'more prose\n'
        '```json status\n{"files_changed": ["late.py"]}\n```\n'),
    'two_arrays_first_wins': (
        '```json status\n{"files_changed": ["first.py"], "files_changed": ["second.py"]}\n```\n'),
    'unclosed_array': '```json status\n{"files_changed": ["a.py", "b.py"\n',
    'bracket_only_before_array': '```json status\n] stray ] "x.py"\n{"files_changed": ["a.py"\n',
    'nested_text_between': (
        '```json status\n{"summary": "wrote [x.py] and \\"y.py\\"", "concerns": [],\n'
        ' "files_changed": ["real.py"]}\n```\n'),
    'whitespace_variants': (
        '```json   \n  status\n{"files_changed"  \n :\n  [\n  "a.py" ,\n "b.md"\n ]}\n```\n'),
    'pattern1_mixed': (
        'Files changed: scripts/p1.py\n\n'
        '```json status\n{"files_changed": ["p2.py"]}\n```\n'),
    'array_closed_only_after_later_fence': (
        '```json status\n{"files_changed": ["a.py"\n'
        '```json status\n{"files_changed": ["b.py"]}\n'),
    'empty_array': '```json status\n{"files_changed": []}\n',
    'non_extension_entries': '```json status\n{"files_changed": ["README", "dir/", "ok.txt"]}\n',
    'empty_text': '',
}


class JsonStatusPathsEquivalence(unittest.TestCase):
    def test_helper_matches_old_regex_on_crafted_inputs(self):
        for name, text in _CASES.items():
            with self.subTest(case=name):
                self.assertEqual(verifier._json_status_paths(text), _old_pattern2_paths(text))

    def test_oracle_cases_are_not_vacuous(self):
        # Guard against a degenerate corpus: at least several cases must yield paths,
        # and at least several must yield none, or equivalence proves little.
        nonempty = [n for n, t in _CASES.items() if _old_pattern2_paths(t)]
        empty = [n for n, t in _CASES.items() if not _old_pattern2_paths(t)]
        self.assertGreaterEqual(len(nonempty), 5, nonempty)
        self.assertGreaterEqual(len(empty), 4, empty)

    def test_first_array_wins(self):
        self.assertEqual(
            verifier._json_status_paths(_CASES['two_arrays_first_wins']), {'first.py'})

    def test_array_closed_by_bracket_in_later_text(self):
        # Old regex: first opener's lazy scan reaches the later ']' and captures both entries.
        text = _CASES['array_closed_only_after_later_fence']
        self.assertEqual(verifier._json_status_paths(text), _old_pattern2_paths(text))
        self.assertIn('a.py', verifier._json_status_paths(text))

    def test_extract_file_paths_includes_pattern2_and_pattern1(self):
        text = _CASES['pattern1_mixed']
        self.assertEqual(sorted(verifier.extract_file_paths(text)), ['p2.py', 'scripts/p1.py'])

    def test_extract_file_paths_is_superset_of_oracle(self):
        for name, text in _CASES.items():
            with self.subTest(case=name):
                self.assertTrue(
                    _old_pattern2_paths(text) <= set(verifier.extract_file_paths(text)))


def _whitespace_cases() -> dict:
    """Crafted Pattern-1 inputs around the `\\s{16,}` squeeze threshold (15/16/17 boundary)."""
    cases = {}
    for n in (1, 2, 14, 15, 16, 17, 18, 40):
        sp = ' ' * n
        cases[f'runs_between_paths_{n}'] = f'Files changed: a.py{sp}b.py{sp}- c/d.sh{sp}* e/f.md'
        cases[f'bullet_then_run_{n}'] = f'Files changed:\n-{sp}g.py\n*{sp}/abs/h.py\n- {sp}i.ts'
        cases[f'run_before_bullet_{n}'] = f'Files changed: a.py{sp}-j.py{sp}*k.py'
        cases[f'abs_path_after_run_{n}'] = f'Files changed: x.py{sp}/abs/l.py{sp}m.sh'
        cases[f'tabs_{n}'] = 'Files changed: a.py' + '\t' * n + 'b.py' + '\t' * n + '- c.py'
        cases[f'space_newline_runs_{n}'] = 'Files changed: a.py' + ' \n' * n + '- b.py' + ' \n' * n + 'c.py'
        cases[f'crlf_runs_{n}'] = 'Files changed:' + '\r\n' * n + '- a.py' + '\r\n' * n + '  b/c.py'
        cases[f'mixed_ws_run_{n}'] = 'Files changed: a.py' + (' \t\r\n' * n)[:n] + 'b.py\n- c.py'
        # path at line start (no whitespace before it) immediately after a newline inside a long run
        cases[f'line_start_after_run_{n}'] = f'Files changed: a.py{sp}\nb.py\n{sp}\nc.py'
        cases[f'bullet_at_line_start_{n}'] = f'Files changed: a.py{sp}\n-b.py\n{sp}\n*c.py'
        cases[f'leading_run_{n}'] = 'Files changed:' + sp + 'a.py'
        cases[f'trailing_run_{n}'] = 'Files changed: a.py' + sp
        cases[f'run_then_blank_line_{n}'] = f'Files changed: a.py{sp}\n\nb.py'
        cases[f'prose_fp_after_run_{n}'] = f'Files changed: next.js{sp}node.js{sp}real.js'
        cases[f'files_changed_key_{n}'] = f'files_changed:{sp}- a.py{sp}b.rb'
        cases[f'after_pattern2_{n}'] = (
            f'Files changed:{sp}p1.py\n\n```json status\n{{"files_changed": ["p2.py"{sp}]}}\n')
    cases['only_whitespace_after_colon'] = 'Files changed:' + ' ' * 50
    cases['x_run_y'] = 'Files changed: x' + ' ' * 50 + 'y'
    return cases


_WS_CASES = _whitespace_cases()

_FUZZ_FRAGMENTS = [
    'Files changed:', ' ', '\n', '\t', '- ', '* ', 'a/b.py', 'x.js', 'next.js', '\n\n',
    '```json status', '"files_changed": [', ']', '"c.md"', ',',
]
_FUZZ_COUNT = 6000
_FUZZ_SEED = 20261005


def _fuzz_string(rng: random.Random) -> str:
    target = rng.randint(20, 280)
    parts = []
    if rng.random() < 0.85:
        parts.append('Files changed:' if rng.random() < 0.8 else 'files_changed:')
    total = sum(len(p) for p in parts)
    while total < target:
        if rng.random() < 0.3:
            # whitespace run long enough to cross the 16-char squeeze threshold
            piece = ''.join(rng.choices(' \t\n\r', weights=[8, 2, 1, 1], k=rng.randint(10, 40)))
        else:
            piece = rng.choice(_FUZZ_FRAGMENTS)
        parts.append(piece)
        total += len(piece)
    return ''.join(parts)[:299]


class Pattern1WhitespaceSqueezeEquivalence(unittest.TestCase):
    def test_crafted_whitespace_cases_match_old_function(self):
        for name, text in _WS_CASES.items():
            with self.subTest(case=name):
                self.assertEqual(
                    sorted(verifier.extract_file_paths(text)),
                    sorted(_old_extract_file_paths(text)))

    def test_crafted_whitespace_cases_are_not_vacuous(self):
        nonempty = [n for n, t in _WS_CASES.items() if _old_extract_file_paths(t)]
        self.assertGreaterEqual(len(nonempty), len(_WS_CASES) * 3 // 4, len(nonempty))
        # and the squeeze really has something to squeeze in a large share of them
        squeezed = [n for n, t in _WS_CASES.items() if re.search(r'\s{16,}', t)]
        self.assertGreaterEqual(len(squeezed), len(_WS_CASES) // 2, len(squeezed))

    def test_known_squeezed_results(self):
        # Concrete expectations (not just old==new): runs of 40 between tokens, bullets kept.
        text = 'Files changed: a.py' + ' ' * 40 + '- c/d.sh' + ' ' * 40 + '* /abs/e.md'
        self.assertEqual(sorted(verifier.extract_file_paths(text)), ['/abs/e.md', 'a.py', 'c/d.sh'])
        text = 'Files changed: a.py' + ' ' * 20 + '\nb.py'
        self.assertEqual(sorted(verifier.extract_file_paths(text)), ['a.py', 'b.py'])

    def test_seeded_fuzz_matches_old_function(self):
        rng = random.Random(_FUZZ_SEED)
        affected = 0
        nonempty = 0
        for i in range(_FUZZ_COUNT):
            text = _fuzz_string(rng)
            self.assertLess(len(text), 300)
            new = sorted(verifier.extract_file_paths(text))
            old = sorted(_old_extract_file_paths(text))
            self.assertEqual(new, old, f'fuzz #{i}: {text!r}')
            m = re.search(r'(?:Files changed|files_changed)\s*:\s*([\s\S]+?)(?=\n\n|$)', text)
            if m and re.search(r'\s{16,}', m.group(1)):
                affected += 1
                if old:
                    nonempty += 1
        # Non-vacuous: the squeeze must actually fire inside Pattern 1 sections, with results.
        self.assertGreaterEqual(affected, 1000, affected)
        self.assertGreaterEqual(nonempty, 500, nonempty)


class ExtractFilePathsIsLinear(unittest.TestCase):
    def _timed(self, text: str) -> float:
        start = time.perf_counter()
        verifier.extract_file_paths(text)
        return time.perf_counter() - start

    def test_pattern1_long_space_run(self):
        text = 'Files changed: x' + ' ' * _SIZE + 'y'
        elapsed = self._timed(text)
        self.assertLess(elapsed, _BUDGET_SECONDS, f'{elapsed:.2f}s for {len(text)} bytes')

    def test_pattern1_space_newline_run(self):
        # ' \n' never forms '\n\n', so the section capture spans the whole run.
        text = 'Files changed: x' + ' \n' * (_SIZE // 2)
        elapsed = self._timed(text)
        self.assertLess(elapsed, _BUDGET_SECONDS, f'{elapsed:.2f}s for {len(text)} bytes')

    def test_many_fences_no_array(self):
        unit = '```json status\n'
        text = unit * (_SIZE // len(unit))
        self.assertGreaterEqual(len(text), _SIZE - len(unit))
        elapsed = self._timed(text)
        self.assertLess(elapsed, _BUDGET_SECONDS, f'{elapsed:.2f}s for {len(text)} bytes')

    def test_many_unclosed_openers(self):
        unit = '"files_changed": [ "a.py"\n'
        body = unit * (_SIZE // len(unit))
        text = '```json status\n' + body
        self.assertGreaterEqual(len(text), _SIZE - len(unit))
        elapsed = self._timed(text)
        self.assertLess(elapsed, _BUDGET_SECONDS, f'{elapsed:.2f}s for {len(text)} bytes')


if __name__ == '__main__':
    unittest.main()
