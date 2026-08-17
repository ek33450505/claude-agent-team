#!/usr/bin/env python3
"""Durable ratchet against CAST_DB_PATH isolation leaks across the Python
unit suite (CAST v10 unit C1e).

Root cause this guards against: `unittest discover` imports every test_*.py
module alphabetically BEFORE running any test, and two modules
(test_cast_audit.py, test_cast_record_review.py) set CAST_DB_PATH at
MODULE-IMPORT time to a private temp path so that importing the hyphenated
script under test never resolves against the real ~/.claude/cast.db. That
import-time value is expected to survive, untouched, for the rest of the
process — it is the suite's actual isolation guarantee, since nothing ever
re-sets CAST_DB_PATH back to "unset" on purpose.

A module whose tearDown does an unconditional `os.environ.pop('CAST_DB_PATH',
None)` (or `del os.environ['CAST_DB_PATH']`) destroys that guarantee for
every module that runs afterwards (alphabetically later in discovery order):
CAST_DB_PATH becomes unset, and any code that resolves it with a
`os.environ.get('CAST_DB_PATH', <default>)` fallback (e.g. cast_db.py)
silently falls back to the real ~/.claude/cast.db. That is exactly how the
Python unit suite was writing synthetic 'sess-mcp-1' / 'sess-order-1' rows
into the live routing_events table (measured delta: 2141 -> 2143 in one run)
and made test_cast_audit.py's own row-count assertion flaky.

This file is named `test_zz_...` so it sorts (and therefore both imports and
runs) LAST among tests/test_*.py. By the time its tests run, every other
module's setUp/tearDown has already executed, so it observes the final,
"whatever the rest of the suite left behind" state directly.

⚠️ EXPLICIT DEPENDENCY, don't refactor it away silently: TestCastDbPathSurvivesSuite
below is only meaningful in the context of a full `unittest discover` run, because it
relies on test_cast_audit.py or test_cast_record_review.py having already set
CAST_DB_PATH at import time (see above). It detects that context via sys.modules
and skips itself otherwise (see _SUITE_CONTEXT_MODULES). If a future change removes
the import-time CAST_DB_PATH set from BOTH of those modules, this guard's skip
condition will silently always trigger and it will stop testing anything — update
_SUITE_CONTEXT_MODULES to match whatever module still does it.

⚠️ Do NOT "improve" TestCastDbPathSurvivesSuite by having it query row counts in the
live ~/.claude/cast.db to detect pollution directly. That would make this ratchet
itself touch the real DB — exactly the thing this unit exists to stop. The env-var
check is a proxy for isolation, deliberately kept one level removed from the DB.
"""
import os
import re
import sys
import unittest
from pathlib import Path

_TESTS_DIR = Path(__file__).parent
_REAL_DEFAULT_DB = str((Path.home() / '.claude' / 'cast.db').resolve())

# The two modules known to set CAST_DB_PATH at MODULE-IMPORT time (see the
# module docstring). `unittest discover` may register an imported module under
# either the bare name or the `tests.`-qualified name depending on how the
# suite was invoked (`python3 -m unittest discover -s tests` vs invocation
# from inside tests/), so both spellings are checked.
_SUITE_CONTEXT_MODULES = (
    'test_cast_audit', 'tests.test_cast_audit',
    'test_cast_record_review', 'tests.test_cast_record_review',
)

# The exact bug pattern: a STANDALONE os.environ.pop('CAST_DB_PATH', ...) or
# del os.environ['CAST_DB_PATH'] (the value discarded, not saved) with no
# enclosing `if` guard and no earlier CAST_DB_PATH save (via `.get(`) in the
# same function — i.e. NOT one of the two correct idioms actually in use
# across this suite:
#
#   (a) guarded pop, restoring the prior value in the other branch
#       (tests/test_cast_pretool_dispatch.py:56-59,
#        tests/test_cast_db_sql_injection.py:112-115):
#           if self._orig_db_path is None:
#               os.environ.pop('CAST_DB_PATH', None)
#           else:
#               os.environ['CAST_DB_PATH'] = self._orig_db_path
#
#   (b) pop-to-save: the popped value is captured in a variable for a later
#       restore rather than discarded (tests/test_cast_db_sql_injection.py:104):
#           old_path = os.environ.pop('CAST_DB_PATH', None)
#
# A prior explicit `.get('CAST_DB_PATH')` save earlier in the same function
# (tests/test_cast_record_review.py:37,40 — save via .get() in setUp, clear
# unconditionally, restore in tearDown) also makes a later unconditional pop
# safe, so that's treated as guarded too.
#
# Known limitation, accepted rather than chased: a pop/del split across
# multiple lines (e.g. `os.environ\n    .pop('CAST_DB_PATH', None)`) is a
# false negative here. Text-scanning six known call sites plus the runtime
# assertion above is the right amount of engineering for this bug class; a
# real AST/control-flow walk would be over-engineering. False negatives are
# accepted; false positives are not.
_POP_RE = re.compile(r"""os\.environ\.pop\(\s*['"]CAST_DB_PATH['"]""")
_ASSIGNED_POP_RE = re.compile(r"""=\s*os\.environ\.pop\(\s*['"]CAST_DB_PATH['"]""")
_DEL_RE = re.compile(r"""del\s+os\.environ\[\s*['"]CAST_DB_PATH['"]\s*\]""")
_IF_LINE_RE = re.compile(r'^\s*(if|elif)\b.*:\s*$|^\s*else\s*:\s*$')
_GET_RE = re.compile(r"""\.get\(\s*['"]CAST_DB_PATH['"]""")
_DEF_LINE_RE = re.compile(r'^\s*def\s+\w+')


def _find_unguarded_kill_lines(lines):
    """Scan a list of source lines and return (1-based lineno, stripped text)
    for every unconditional discard of CAST_DB_PATH — either
    `os.environ.pop('CAST_DB_PATH', ...)` (return value unused) or
    `del os.environ['CAST_DB_PATH']` — that isn't guarded by one of the
    correct idioms documented above.

    Pulled out as a standalone function (rather than inlined in the test
    method) so it can be exercised directly against synthetic in-memory
    fixtures — see TestFindUnguardedKillLines below — without ever writing a
    file matching the offending pattern into tests/, which would make the
    lint flag its own fixture and fail the ratchet on itself.
    """
    offenders = []
    for i, line in enumerate(lines):
        is_pop = bool(_POP_RE.search(line))
        is_del = bool(_DEL_RE.search(line))
        if not (is_pop or is_del):
            continue
        if is_pop and _ASSIGNED_POP_RE.search(line):
            continue  # pop-to-save idiom — value captured, not discarded
        if i > 0 and _IF_LINE_RE.match(lines[i - 1]):
            continue  # immediately guarded by an if/elif/else branch
        # Same-function earlier save: scan back to the nearest `def` at or
        # before this line and look for a prior `.get('CAST_DB_PATH'`.
        def_start = 0
        for j in range(i, -1, -1):
            if _DEF_LINE_RE.match(lines[j]):
                def_start = j
                break
        if any(_GET_RE.search(w) for w in lines[def_start:i]):
            continue  # value was saved earlier in this function
        offenders.append((i + 1, line.strip()))
    return offenders


class TestCastDbPathSurvivesSuite(unittest.TestCase):
    """After the full alphabetical test_*.py run, CAST_DB_PATH must still be
    set and must NOT resolve to the real ~/.claude/cast.db.

    A PASSING run while the bug is present looks identical to a FAILING run
    while the bug is fixed only if this assertion is wrong about what
    "healthy" looks like — it isn't: test_cast_audit.py and
    test_cast_record_review.py set CAST_DB_PATH at import time and nothing
    in a correct suite ever unsets it again, so a healthy run always leaves
    it set to one of those private temp paths, never unset and never the
    real default.

    This assertion is ONLY meaningful when run as part of the full suite. Run
    in isolation (e.g. `python3 -m unittest tests.test_zz_db_isolation_guard`),
    neither test_cast_audit.py nor test_cast_record_review.py has been
    imported, CAST_DB_PATH was never set by anyone, and "unset" is the
    correct, healthy state — asserting non-None there would be a false
    alarm, not a real failure. See _SUITE_CONTEXT_MODULES: the test skips
    itself when it can't detect suite context, rather than reporting a
    result it can't actually back up.
    """

    def test_cast_db_path_still_isolated_after_full_suite(self):
        if not any(name in sys.modules for name in _SUITE_CONTEXT_MODULES):
            self.skipTest(
                'Not running inside the full test_*.py suite: neither '
                'test_cast_audit nor test_cast_record_review (the two modules '
                'that set CAST_DB_PATH at import time) is in sys.modules. This '
                "assertion depends on that import-time side effect and can't "
                'distinguish "unset because nothing set it" (fine, running '
                'standalone) from "unset because a teardown popped it" (the '
                'actual bug) without it — skipping rather than reporting a '
                'false alarm. Run the full suite '
                "(`python3 -m unittest discover -s tests -p 'test_*.py'`) to "
                'exercise this assertion for real.'
            )
        current = os.environ.get('CAST_DB_PATH')
        self.assertIsNotNone(
            current,
            'CAST_DB_PATH is unset after the full test_*.py run. This means '
            "some earlier module's tearDown ran an unconditional "
            "os.environ.pop('CAST_DB_PATH', None) (or del os.environ[...]) "
            'instead of restoring the prior value, clobbering isolation for '
            'every module that runs after it alphabetically. Grep test_*.py '
            'for `os.environ.pop(\'CAST_DB_PATH\'` and `del os.environ[\''
            'CAST_DB_PATH\']` and fix the offending teardown to '
            'save-in-setUp/restore-in-tearDown, matching '
            'tests/test_cast_pretool_dispatch.py.',
        )
        resolved = str(Path(current).resolve()) if current else None
        self.assertNotEqual(
            resolved,
            _REAL_DEFAULT_DB,
            f'CAST_DB_PATH resolves to the real {_REAL_DEFAULT_DB} after the '
            'full test_*.py run — the suite is no longer isolated from the '
            'live cast.db. Likely cause: an unconditional '
            "os.environ.pop('CAST_DB_PATH', None) in some module's "
            'tearDown ran after the module that legitimately set this path, '
            'and something downstream re-resolved the default.',
        )


class TestNoUnconditionalPop(unittest.TestCase):
    """Lint-style ratchet: scan sibling test files for the literal
    unconditional-discard pattern (bare pop or del) so a future regression is
    caught by grep, not just by drift in the live DB (which the previous test
    alone would only catch as a downstream symptom).

    Deliberately narrow and easy to reason about (regex + a same-function
    scan, see _find_unguarded_kill_lines) rather than a real AST walk, since a
    full control-flow analysis of "is this discard actually reachable
    unconditionally" is a much bigger and more brittle undertaking than this
    bug class warrants. False negatives (a cleverly-disguised or multi-line
    discard) are acceptable; false positives are not — an early version of
    this check keyed on the literal substring "is None" in the two lines
    above the pop, which false-flagged both `if old_path is not None:`
    (sql_injection) and `if self.orig_path:` (record_review), two
    already-correct idioms phrased differently. The current version instead
    accepts any of: (a) the pop's return value is assigned to a variable (a
    save, not a discard), (b) an `if ...:` / `elif ...:` / `else:` line
    immediately precedes it (any condition, any phrasing — record_review's
    else-branch pop is exactly this shape), or (c) the enclosing function
    already saved the value via `.get('CAST_DB_PATH'` earlier in its own
    body.
    """

    def test_no_bare_pop_cast_db_path_in_sibling_modules(self):
        offenders = []
        for path in sorted(_TESTS_DIR.glob('test_*.py')):
            if path.name == Path(__file__).name:
                continue
            lines = path.read_text().splitlines()
            for lineno, text in _find_unguarded_kill_lines(lines):
                offenders.append(f'{path.name}:{lineno}: {text}')

        self.assertEqual(
            offenders,
            [],
            'Found unconditional CAST_DB_PATH discard(s) (os.environ.pop(...) '
            'or del os.environ[...], no guard) in: ' + '; '.join(offenders) +
            '. This clobbers CAST_DB_PATH for every test_*.py module that '
            'runs after it alphabetically. Fix by saving the prior value in '
            'setUp and restoring it in tearDown, matching '
            'tests/test_cast_pretool_dispatch.py:44-59.',
        )


class TestFindUnguardedKillLines(unittest.TestCase):
    """Unit-tests _find_unguarded_kill_lines directly against synthetic
    in-memory line lists — NOT a fixture file under tests/, since a file
    matching the offending pattern living in tests/ would itself be flagged
    by TestNoUnconditionalPop above and fail the ratchet on its own fixture.
    """

    def test_detects_bare_pop(self):
        lines = [
            "    def tearDown(self):",
            "        os.unlink(self._tmp.name)",
            "        os.environ.pop('CAST_DB_PATH', None)",
        ]
        offenders = _find_unguarded_kill_lines(lines)
        self.assertEqual(offenders, [(3, "os.environ.pop('CAST_DB_PATH', None)")])

    def test_detects_bare_del(self):
        lines = [
            "    def tearDown(self):",
            "        os.unlink(self._tmp.name)",
            "        del os.environ['CAST_DB_PATH']",
        ]
        offenders = _find_unguarded_kill_lines(lines)
        self.assertEqual(offenders, [(3, "del os.environ['CAST_DB_PATH']")])

    def test_guarded_del_is_not_flagged(self):
        lines = [
            "    def tearDown(self):",
            "        if self._orig_db_path is None:",
            "            del os.environ['CAST_DB_PATH']",
            "        else:",
            "            os.environ['CAST_DB_PATH'] = self._orig_db_path",
        ]
        self.assertEqual(_find_unguarded_kill_lines(lines), [])

    def test_guarded_pop_is_not_flagged(self):
        lines = [
            "    def tearDown(self):",
            "        if self._orig_db_path is None:",
            "            os.environ.pop('CAST_DB_PATH', None)",
            "        else:",
            "            os.environ['CAST_DB_PATH'] = self._orig_db_path",
        ]
        self.assertEqual(_find_unguarded_kill_lines(lines), [])

    def test_pop_to_save_is_not_flagged(self):
        lines = [
            "    def setUp(self):",
            "        old_path = os.environ.pop('CAST_DB_PATH', None)",
        ]
        self.assertEqual(_find_unguarded_kill_lines(lines), [])

    def test_prior_get_save_in_same_function_is_not_flagged(self):
        lines = [
            "    def setUp(self):",
            "        self.orig_path = os.environ.get('CAST_DB_PATH')",
            "        os.environ.pop('CAST_DB_PATH', None)",
        ]
        self.assertEqual(_find_unguarded_kill_lines(lines), [])


if __name__ == '__main__':
    unittest.main()
