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
import ast
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
_IF_LINE_RE = re.compile(r'^\s*(if|elif)\b.*:\s*$|^\s*else\s*:\s*$')
_DEF_LINE_RE = re.compile(r'^\s*def\s+\w+')


def _kill_regexes(var):
    """(pop, assigned-pop, del, get) regexes for env var `var`; both quote
    styles are matched. Parametrized so the same scanner covers CAST_DB_PATH
    and HOME (HOME unset => os.path.expanduser of a tilde path resolves via
    the passwd db to the REAL home directory for every later module)."""
    v = re.escape(var)
    return (
        re.compile(r"""os\.environ\.pop\(\s*['"]""" + v + r"""['"]"""),
        re.compile(r"""=\s*os\.environ\.pop\(\s*['"]""" + v + r"""['"]"""),
        re.compile(r"""del\s+os\.environ\[\s*['"]""" + v + r"""['"]\s*\]"""),
        re.compile(r"""\.get\(\s*['"]""" + v + r"""['"]"""),
    )


# HOME assign-without-restore: `os.environ['HOME'] = <tmp>` inside a function
# in a file that never saves/restores HOME anywhere. Detected with stdlib `ast`
# (Assign / AugAssign / AnnAssign whose target is the Subscript os.environ[
# 'HOME'], nested in a FunctionDef/AsyncFunctionDef), so string literals --
# single-line or triple-quoted fixture source, e.g.
# test_cast_git_guard_worktree_prune.py's 'os.environ["HOME"] = sys.argv[2]' --
# and comments are excluded by construction; module-level (import-time)
# assignments are out of scope. The unit-level helpers return [] for source
# that does not parse (fragment inputs); the real sibling scans instead FAIL
# CLOSED on an unparseable file (see _load_sibling_sources).
#
# Known limits (all false negatives, accepted -- false positives are not):
#  * The restore marker is FILE-level: one correct save/restore in a file
#    clears every other bare assign in it. Per-function matching is not viable
#    because the save lives in setUp and the restore in tearDown.
#  * The marker is textual: it is not checked that the save is actually used
#    to restore.
#  * ANY one marker anywhere in the file (os.environ.copy() and
#    patch.dict(os.environ ...) included -- both legitimate restore idioms)
#    clears ALL HOME assignments in that file. Deliberate: narrowing the
#    marker set risks false positives.
_HOME_RESTORE_RES = (
    # `(?<![=!<>])` keeps `==` / `!=` / `<=` / `>=` comparisons from counting.
    re.compile(r"""(?<![=!<>])=\s*os\.environ\.get\(\s*['"]HOME['"]"""),
    re.compile(r"""os\.environ\.copy\(\)"""),
    re.compile(r"""patch\.dict\(\s*os\.environ"""),  # also matches mock.patch.dict
)


def _is_environ_home_subscript(node):
    """True for the AST of `os.environ['HOME']` (either quote style)."""
    return (
        isinstance(node, ast.Subscript)
        and isinstance(node.value, ast.Attribute)
        and node.value.attr == 'environ'
        and isinstance(node.value.value, ast.Name)
        and node.value.value.id == 'os'
        and isinstance(node.slice, ast.Constant)
        and node.slice.value == 'HOME'
    )


def _parse_or_none(lines):
    try:
        return ast.parse('\n'.join(lines))
    except (SyntaxError, ValueError):
        return None


def _split_source(text):
    """Split source into lines on '\\n' ONLY. str.splitlines() also splits on
    \\x0b, \\x0c, \\x1c-\\x1e, \\x85, \\u2028 and \\u2029, which may legally
    appear inside string literals; re-joining such lines with '\\n' then
    corrupts the source and silently turns the ast-based checks OFF."""
    return text.split('\n')


def _load_sibling_sources(testcase):
    """[(filename, lines)] for every sibling tests/test_*.py (this file
    excluded). FAILS CLOSED: a sibling that does not parse fails `testcase`
    naming the file, rather than being silently skipped (which would disable
    the ast checks for it)."""
    sources, unparseable = [], []
    for path in sorted(_TESTS_DIR.glob('test_*.py')):
        if path.name == Path(__file__).name:
            continue
        lines = _split_source(path.read_text())
        if _parse_or_none(lines) is None:
            unparseable.append(path.name)
        sources.append((path.name, lines))
    testcase.assertEqual(
        unparseable,
        [],
        'Sibling test file(s) do not parse as Python, so the ast-based '
        'isolation scans cannot cover them: ' + ', '.join(unparseable),
    )
    return sources


def _multiline_string_lines(tree):
    """1-based line numbers covered by any string constant spanning more than
    one line (triple-quoted fixtures/docstrings, implicit concatenations).
    Known false negative: a real statement sharing a line with such a span."""
    covered = set()
    if tree is None:
        return covered
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and node.end_lineno is not None
            and node.end_lineno > node.lineno
        ):
            covered.update(range(node.lineno, node.end_lineno + 1))
    return covered


def _find_home_assign_without_restore(lines):
    """Return (1-based lineno, stripped text) for every
    `os.environ['HOME'] = ...` executed inside a function when the file
    contains no HOME save/restore marker at all. Empty list if any marker is
    present or the source does not parse."""
    if any(r.search(line) for line in lines for r in _HOME_RESTORE_RES):
        return []
    tree = _parse_or_none(lines)
    if tree is None:
        return []
    offenders = []

    def visit(node, in_func):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            in_func = True
        if in_func:
            if isinstance(node, ast.Assign):
                targets = node.targets
            elif isinstance(node, (ast.AugAssign, ast.AnnAssign)):
                targets = [node.target]
            else:
                targets = []
            if any(_is_environ_home_subscript(t) for t in targets):
                offenders.append((node.lineno, lines[node.lineno - 1].strip()))
        for child in ast.iter_child_nodes(node):
            visit(child, in_func)

    visit(tree, False)
    return offenders


def _find_unguarded_kill_lines(lines, var='CAST_DB_PATH'):
    """Scan a list of source lines and return (1-based lineno, stripped text)
    for every unconditional discard of env var `var` (default CAST_DB_PATH;
    also used for HOME) — either `os.environ.pop('<var>', ...)` (return value
    unused) or `del os.environ['<var>']` — that isn't guarded by one of the
    correct idioms documented above.

    Pulled out as a standalone function (rather than inlined in the test
    method) so it can be exercised directly against synthetic in-memory
    fixtures — see TestFindUnguardedKillLines below — without ever writing a
    file matching the offending pattern into tests/, which would make the
    lint flag its own fixture and fail the ratchet on itself.
    """
    pop_re, assigned_pop_re, del_re, get_re = _kill_regexes(var)
    in_string = _multiline_string_lines(_parse_or_none(lines))
    offenders = []
    for i, line in enumerate(lines):
        if (i + 1) in in_string:
            continue  # inside a multi-line string literal (fixture source/docstring)
        is_pop = bool(pop_re.search(line))
        is_del = bool(del_re.search(line))
        if not (is_pop or is_del):
            continue
        if is_pop and assigned_pop_re.search(line):
            continue  # pop-to-save idiom — value captured, not discarded
        if i > 0 and _IF_LINE_RE.match(lines[i - 1]):
            continue  # immediately guarded by an if/elif/else branch
        # Same-function earlier save: scan back to the nearest `def` at or
        # before this line and look for a prior `.get('<var>'`.
        def_start = 0
        for j in range(i, -1, -1):
            if _DEF_LINE_RE.match(lines[j]):
                def_start = j
                break
        if any(get_re.search(w) for w in lines[def_start:i]):
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
        for name, lines in _load_sibling_sources(self):
            for lineno, text in _find_unguarded_kill_lines(lines):
                offenders.append(f'{name}:{lineno}: {text}')

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

    def test_no_bare_pop_home_in_sibling_modules(self):
        offenders = []
        for name, lines in _load_sibling_sources(self):
            for lineno, text in _find_unguarded_kill_lines(lines, var='HOME'):
                offenders.append(f'{name}:{lineno}: {text}')

        self.assertEqual(
            offenders,
            [],
            "Found unconditional HOME discard(s) (os.environ.pop('HOME') or "
            "del os.environ['HOME'], no guard) in: " + '; '.join(offenders) +
            '. This leaves HOME unset for every later test_*.py module, so '
            'expanduser of a tilde path resolves via the passwd db to the '
            'REAL home directory (the live runtime). Fix by saving the prior '
            'value in setUp and restoring it in tearDown, matching '
            'tests/test_cast_ack.py:45-58.',
        )

    def test_home_assign_has_restore_in_sibling_modules(self):
        offenders = []
        for name, lines in _load_sibling_sources(self):
            for lineno, text in _find_home_assign_without_restore(lines):
                offenders.append(f'{name}:{lineno}: {text}')

        self.assertEqual(
            offenders,
            [],
            "Found os.environ['HOME'] = ... inside a function in a file with "
            "no HOME save/restore (= os.environ.get('HOME'), "
            'os.environ.copy(), or patch.dict(os.environ, ...)): ' +
            '; '.join(offenders) +
            '. The redirected HOME leaks into every later test_*.py module. '
            'Save in setUp, restore in tearDown, matching '
            'tests/test_cast_ack.py:45-58.',
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

    def test_home_bare_pop_flagged_both_quote_styles(self):
        for q in ("'", '"'):
            stmt = f"os.environ.pop({q}HOME{q}, None)"
            lines = ["    def tearDown(self):", "        " + stmt]
            self.assertEqual(
                _find_unguarded_kill_lines(lines, var='HOME'), [(2, stmt)]
            )

    def test_home_bare_del_flagged(self):
        lines = ["    def tearDown(self):", '        del os.environ["HOME"]']
        self.assertEqual(
            _find_unguarded_kill_lines(lines, var='HOME'),
            [(2, 'del os.environ["HOME"]')],
        )

    def test_home_guarded_pop_not_flagged(self):
        lines = [
            "    def tearDown(self):",
            "        if self._orig_home is None:",
            "            os.environ.pop('HOME', None)",
            "        else:",
            "            os.environ['HOME'] = self._orig_home",
        ]
        self.assertEqual(_find_unguarded_kill_lines(lines, var='HOME'), [])

    def test_home_saved_pop_not_flagged(self):
        for lines in (
            ["    def setUp(self):", "        old = os.environ.pop('HOME', None)"],
            [
                "    def setUp(self):",
                '        self._orig_home = os.environ.get("HOME")',
                '        os.environ.pop("HOME", None)',
            ],
        ):
            self.assertEqual(_find_unguarded_kill_lines(lines, var='HOME'), [])

    def test_var_scans_are_independent(self):
        db = ["    def tearDown(self):", "        os.environ.pop('CAST_DB_PATH', None)"]
        home = ["    def tearDown(self):", "        os.environ.pop('HOME', None)"]
        self.assertEqual(_find_unguarded_kill_lines(db, var='HOME'), [])
        self.assertEqual(_find_unguarded_kill_lines(home), [])

    def test_home_assign_without_restore_flagged(self):
        for q in ("'", '"'):
            stmt = f"os.environ[{q}HOME{q}] = self._tmpdir"
            lines = ["class T:", "    def setUp(self):", "        " + stmt]
            self.assertEqual(_find_home_assign_without_restore(lines), [(3, stmt)])

    def test_home_augassign_and_annassign_flagged(self):
        for stmt in ("os.environ['HOME'] += '/x'", "os.environ['HOME']: str = '/x'"):
            lines = ["def f():", "    " + stmt]
            self.assertEqual(_find_home_assign_without_restore(lines), [(2, stmt)])

    def test_home_assign_with_restore_marker_not_flagged(self):
        assign = "    os.environ['HOME'] = '/x'"
        for marker in (
            "    orig = os.environ.get('HOME')",
            "    saved = os.environ.copy()",
            "    p = patch.dict(os.environ, {})",
            "    p = mock.patch.dict(os.environ, {})",
        ):
            lines = ["def f():", marker, assign]
            self.assertEqual(_find_home_assign_without_restore(lines), [], marker)

    def test_home_equality_comparison_is_not_a_restore_marker(self):
        lines = [
            "def f():",
            "    ok = x == os.environ.get('HOME')",
            "    os.environ['HOME'] = '/x'",
        ]
        self.assertEqual(
            _find_home_assign_without_restore(lines),
            [(3, "os.environ['HOME'] = '/x'")],
        )

    def test_home_assign_in_string_comment_or_module_level_not_flagged(self):
        for body in (
            ["def f():", "    src = 'x; os.environ[\"HOME\"] = y'"],
            ["def f():", "    # os.environ['HOME'] = tmp"],
            ["os.environ['HOME'] = '/import-time'"],
            ["def f():", "    assert os.environ['HOME'] == x"],
            ["def f():", "    y = os.environ['HOME']"],
        ):
            self.assertEqual(_find_home_assign_without_restore(body), [], body)

    def test_home_assign_in_triple_quoted_fixture_not_flagged(self):
        lines = [
            "def test_x(self):",
            '    src = textwrap.dedent("""',
            "        os.environ['HOME'] = sys.argv[2]",
            '    """)',
        ]
        self.assertEqual(_find_home_assign_without_restore(lines), [])
        # ...and a real assignment after the fixture is still flagged.
        lines.append("    os.environ['HOME'] = '/real'")
        self.assertEqual(
            _find_home_assign_without_restore(lines),
            [(5, "os.environ['HOME'] = '/real'")],
        )

    def test_home_assign_in_unparseable_source_skipped(self):
        self.assertEqual(
            _find_home_assign_without_restore(["def f(:", "    os.environ['HOME'] = 1"]),
            [],
        )

    def test_triple_quoted_fixture_pop_and_del_not_flagged(self):
        for var, pop, dele in (
            ('HOME', "os.environ.pop('HOME', None)", "del os.environ['HOME']"),
            ('CAST_DB_PATH', "os.environ.pop('CAST_DB_PATH', None)",
             "del os.environ['CAST_DB_PATH']"),
        ):
            lines = [
                "def test_x(self):",
                '    src = textwrap.dedent("""',
                "        " + pop,
                "        " + dele,
                '    """)',
            ]
            self.assertEqual(_find_unguarded_kill_lines(lines, var=var), [], var)
            # ...and a real bare pop after the fixture is still flagged.
            lines.append("    " + pop)
            self.assertEqual(
                _find_unguarded_kill_lines(lines, var=var), [(6, pop)], var
            )


    def test_split_source_keeps_formfeed_in_string_so_file_parses(self):
        text = (
            "def f():\n"
            "    s = 'a\x0cb'\n"
            "    t = 'c\x1cd\u2028e'\n"
            "    os.environ['HOME'] = '/real'\n"
        )
        lines = _split_source(text)
        self.assertIsNotNone(_parse_or_none(lines))
        self.assertEqual(
            _find_home_assign_without_restore(lines),
            [(4, "os.environ['HOME'] = '/real'")],
        )
        # The splitlines() form corrupts the string literals and fails to
        # parse -- the silent fail-open this helper exists to prevent.
        self.assertIsNone(_parse_or_none(text.splitlines()))


if __name__ == '__main__':
    unittest.main()
