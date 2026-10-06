#!/usr/bin/env python3
"""Spelling / indirection bypasses of the Bash git guard (2026-10-06 security fix, High).

`scripts/cast-git-guard.py::evaluate("Bash")` ALLOWED (rc 0 on main) every one of these, all of
which the shell executes as a real guarded git command:

    bash -c 'git push origin main'      (also sh / zsh / dash / ksh, -lc, /bin/bash, env, sudo ...)
    eval "git push"                     echo $(git push)        echo `git push`
    GIT push   (APFS is case-insensitive)     $'git' push     $"git" push     git${IFS}push

Every BLOCK pattern anchors on `(^|\\s)git`, and `_normalize_git_segment` only ran when the
segment's first token had basename exactly `git`. The fix is ADDITIVE: `_executed_code` extracts
the code a command hands to a nested shell and `_executable_segments` re-evaluates it as extra
virtual segments through the same engine; `_normalize_git_segment` learns the spellings.

What is pinned here:
  * every spelling x {push, commit, reset --hard} BLOCKS, nested and in the extra forms;
  * no new false positives (`rg "git push" docs/`, single-quoted data, quoted-heredoc commit
    messages, comments, `bash -c 'git status'` ...) - those verdicts must stay ALLOW;
  * a hatch is scoped to its own (virtual) segment, and `$IFS` cannot forge one;
  * the scanner is ONE lexer that fails CLOSED: input it cannot model with certainty (unterminated
    quote / substitution, a quote in arithmetic, `<<$'EOF'`, ...) is a `_Refusal` (BLOCK) when git
    is mentioned after it, and the lexer desyncs security found (an apostrophe in an unquoted
    heredoc body, `#` after a non-blank, `${x//(/y}`, `$$'a\\'`, `$((1<<'2'))`) block (classes
    TestA1 .. TestA9 follow the task's items, each also exercised inside `$(...)`);
  * the scanner is bounded (step / code-count / depth caps fail CLOSED) and is fast on 400 KB of
    nested padding and on 5 MB of every padding shape;
  * real segments are yielded first and unchanged (additive).

The verb is assembled (`G`) so no literal guarded command sits in this file. HOME is redirected
to a temp dir and `_record_hatch` is mocked, as in tests/test_cast_git_guard_perf.py. The
hyphenated module is loaded via importlib, same pattern as the other git-guard tests.
"""
import importlib.util
import os
import random
import shlex
import shutil
import signal
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent

_spec = importlib.util.spec_from_file_location(
    'cast_git_guard_spellings', str(_REPO / 'scripts' / 'cast-git-guard.py'))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

G = 'gi' + 't'
BOUND_SECS = 1.0
TRIPWIRE_SECS = 4.0
# The three destructive verbs the task pins; each is a different BLOCK family.
VERBS = ('push origin main', 'commit -m x', 'reset --hard')


class _TooSlow(BaseException):
    """BaseException on purpose: evaluate() ends in `except Exception: return 0, ''`."""


class _Base(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-gitspell-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_PUSH_OK', 'CAST_COMMIT_AGENT', 'CAST_RESET_OK', 'CLAUDE_SUBPROCESS'):
            os.environ.pop(k, None)
        rec = mock.patch.object(gg, '_record_hatch')
        rec.start()
        self.addCleanup(rec.stop)

    def verdict(self, cmd):
        return gg.evaluate('Bash', {'command': cmd})

    def timed(self, cmd):
        """(code, msg, elapsed); fails the test past TRIPWIRE_SECS (a regression, not a hang)."""
        def _alarm(signum, frame):
            raise _TooSlow()
        have_alarm = hasattr(signal, 'setitimer') and hasattr(signal, 'SIGALRM')
        previous = signal.signal(signal.SIGALRM, _alarm) if have_alarm else None
        t0 = time.perf_counter()
        try:
            if have_alarm:
                signal.setitimer(signal.ITIMER_REAL, TRIPWIRE_SECS)
            code, msg = gg.evaluate('Bash', {'command': cmd})
        except _TooSlow:
            self.fail(f'git guard still running after {TRIPWIRE_SECS} s on a {len(cmd)}-char command')
        finally:
            if have_alarm:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
        return code, msg, time.perf_counter() - t0

    def assertBlocks(self, cmd):
        code, msg = self.verdict(cmd)
        self.assertEqual(code, 2, f'ALLOWED, must block: {cmd!r}')
        self.assertTrue(msg and '[CAST]' in msg, f'{cmd!r}: block without a CAST message: {msg!r}')

    def assertAllows(self, cmd):
        code, msg = self.verdict(cmd)
        self.assertEqual((code, msg), (0, ''), f'BLOCKED, must allow: {cmd!r}: {msg!r}')


def _wrap(template, cmd):
    return template.replace('@C@', cmd)


# Templates: `@C@` is the full guarded command (`git push origin main`).
SHELL_C = (
    "bash -c '@C@'", "sh -c '@C@'", "zsh -c '@C@'", "dash -c '@C@'", "ksh -c '@C@'", "ash -c '@C@'",
    "bash -lc '@C@'", "bash -ec '@C@'", "bash -xc '@C@'", "bash -c \"@C@\"", "/bin/bash -c '@C@'",
    "/usr/bin/env bash -c '@C@'", "env bash -c '@C@'", "env -i FOO=1 bash -c '@C@'",
    "sudo bash -c '@C@'", "sudo -u root sh -c '@C@'", "env bash -c '@C@'", "BASH -c '@C@'",
    "FOO=1 bash -c '@C@'", "command bash -c '@C@'", "exec bash -c '@C@'", "nohup bash -c '@C@'",
    "nice -n 5 bash -c '@C@'", "time bash -c '@C@'", "timeout 5 bash -c '@C@'",
    "bash -o pipefail -c '@C@'", "bash --norc -c '@C@'", "bash -c -- '@C@'",
    "'bash' -c '@C@'", "bash -c '@C@' _ arg",
    "bash -c '@C@ && echo done'", "bash -c '@C@; ls'", "bash -c 'ls | @C@'",
    "if true; then bash -c '@C@'; fi", "ls && bash -c '@C@'",
)
EVAL = ('eval "@C@"', "eval '@C@'", 'eval @C@', "eval 'g'i't push'", "builtin eval '@C@'")
SUBST = (
    'echo $(@C@)', 'echo `@C@`', '"$(@C@)"', 'echo "$(@C@)"', 'echo "`@C@`"', 'echo x$(@C@)y',
    'echo $(ls; @C@)', 'echo $(@C@; ls)', 'echo $(ls | @C@)', 'echo $(echo $(@C@))', 'x=$(@C@)',
    'diff <(@C@) /dev/null', '(@C@)', '( @C@ )', 'echo $( @C@ )', 'echo ${x:-$(@C@)}',
    'echo "a $(ls) b $(@C@) c"',
)
NESTED = (
    "bash -c \"eval '@C@'\"", "$(bash -c '@C@')", "eval \"bash -c '@C@'\"", "bash -c 'echo $(@C@)'",
    "bash -c \"echo `@C@`\"", "echo $(eval '@C@')", "echo \"$(bash -c '@C@')\"",
    "bash -c \"bash -c '@C@'\"",
)


class TestExecutedCodeIsExtracted(_Base):
    """(a) `-c` unwrap, (b) eval, (c) substitution extraction: each family has its own tests, so
    reverting any one of them fails exactly its own cases."""

    def _each(self, templates):
        for verb in VERBS:
            cmd = G + ' ' + verb
            for t in templates:
                with self.subTest(template=t, verb=verb):
                    self.assertBlocks(_wrap(t, cmd))

    def test_shell_dash_c_strings_block(self):
        self._each(SHELL_C)

    def test_eval_blocks(self):
        self._each(EVAL)

    def test_command_substitution_subshell_and_backticks_block(self):
        self._each(SUBST)

    def test_nested_forms_block(self):
        self._each(NESTED)

    def test_unquoted_heredoc_body_is_executed_by_the_shell(self):
        # `<<EOF` (unquoted delimiter) expands `$(...)` and backticks in the body.
        self.assertBlocks('cat <<EOF\n$(' + G + ' push origin main)\nEOF')
        self.assertBlocks('cat <<EOF\nx `' + G + ' push origin main` y\nEOF')

    def test_a_comment_apostrophe_cannot_desync_the_scan(self):
        # `#` starts a comment only at word start, as in the shell, so a quote inside it is inert.
        self.assertBlocks("# don't do that\nbash -c '" + G + " push origin main'")
        self.assertBlocks("echo hi # it's\necho $(" + G + " push origin main)")

    def test_ansi_c_and_locale_quoted_operands(self):
        self.assertBlocks("bash -c $'" + G + " push origin main'")
        self.assertBlocks('bash -c $"' + G + ' push origin main"')
        self.assertBlocks("echo $(echo $'a\\'b'); bash -c '" + G + " push origin main'")

    def test_a_heredoc_commit_message_does_not_hide_a_later_command(self):
        cmd = ('CAST_COMMIT_AGENT=1 ' + G + ' commit -m "$(cat <<\'EOF\'\ndon\'t `x`\nEOF\n)"'
               "; bash -c '" + G + " push origin main'")
        self.assertBlocks(cmd)

    def test_three_levels_of_nesting_are_followed(self):
        inner = G + ' push origin main'
        cmd = inner
        for _ in range(3):
            cmd = 'bash -c ' + shlex.quote(cmd)
        code, msg = self.verdict(cmd)
        self.assertEqual(code, 2)
        self.assertIn('Raw `' + G + ' push` blocked', msg)    # reached the real push verdict

    def test_four_levels_with_git_are_refused_fail_closed(self):
        cmd = G + ' status'
        for _ in range(4):
            cmd = 'bash -c ' + shlex.quote(cmd)
        code, msg = self.verdict(cmd)
        self.assertEqual(code, 2)
        self.assertIn('nested', msg)

    def test_deep_nesting_without_git_is_not_scanned_at_all(self):
        cmd = 'echo hello'
        for _ in range(6):
            cmd = 'bash -c ' + shlex.quote(cmd)
        self.assertAllows(cmd)


class TestSpellings(_Base):
    """(d) `_normalize_git_segment`: case, ANSI-C / locale quotes, `$IFS` as the separator."""

    @staticmethod
    def _spellings(verb):
        rest = verb
        ifs = verb.replace(' ', '${IFS}')
        return (
            'GIT ' + rest, 'Git ' + rest, 'gIT ' + rest, '/usr/bin/GIT ' + rest, '/USR/BIN/Git ' + rest,
            "$'" + G + "' " + rest, '$"' + G + '" ' + rest, "g$'i't " + rest, "$'g'it " + rest,
            "g$''it " + rest, 'FOO=1 GIT ' + rest, 'FOO=1 $\'' + G + '\' ' + rest,
            G + '${IFS}' + ifs, G + '$IFS ' + rest,
            G + '${IFS}-C${IFS}/tmp${IFS}' + ifs, 'GIT${IFS}' + ifs,
            "'" + G + "'${IFS}" + ifs.replace("'", ''),
        )

    def test_every_spelling_of_every_verb_blocks(self):
        for verb in VERBS:
            for cmd in self._spellings(verb):
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_spellings_also_block_inside_executed_strings(self):
        for verb in VERBS:
            for cmd in (self._spellings(verb)[0], self._spellings(verb)[5], self._spellings(verb)[12]):
                for wrapped in ('bash -c ' + shlex.quote(cmd), 'eval ' + shlex.quote(cmd), 'echo $(' + cmd + ')'):
                    with self.subTest(wrapped=wrapped):
                        self.assertBlocks(wrapped)

    def test_normalisation_renders_the_canonical_form(self):
        self.assertEqual(gg._normalize_git_segment('GIT push'), G + ' push')
        self.assertEqual(gg._normalize_git_segment("$'" + G + "' push"), G + ' push')
        self.assertEqual(gg._normalize_git_segment('$"' + G + '" push'), G + ' push')
        self.assertEqual(gg._normalize_git_segment(G + '${IFS}push'), G + ' push')
        self.assertEqual(gg._normalize_git_segment(G + '$IFS push'), G + ' push')
        # A variable that merely STARTS with IFS is a different variable: not a separator.
        self.assertIsNone(gg._normalize_git_segment(G + '$IFSx push'))

    def test_a_non_git_command_is_still_not_normalised(self):
        for seg in ('rg "' + G + ' push" docs/', 'echo $IFS', 'mygit push', './' + G + 'x push', 'GITHUB push'):
            with self.subTest(seg=seg):
                self.assertIsNone(gg._normalize_git_segment(seg))

    def test_ifs_split_never_touches_the_assignment_prefix(self):
        # `CAST_PUSH_OK=1$IFS git push` assigns "1 \t\n" in real bash - it is NOT the hatch, and
        # the normaliser must not turn it into one (a rewrite may add a block, never remove one).
        self.assertBlocks('CAST_PUSH_OK=1$IFS ' + G + ' push origin main')
        self.assertBlocks('CAST_PUSH_OK=1${IFS} ' + G + ' push origin main')

    def test_a_legitimate_hatch_still_works_with_a_spelled_verb(self):
        # Honouring a real hatch is unchanged: the hatch is `=1` and the verb is spelled oddly.
        self.assertAllows('CAST_PUSH_OK=1 ' + G + '${IFS}push origin main')
        self.assertAllows("CAST_PUSH_OK=1 $'" + G + "' push origin main")


class TestNoNewFalsePositives(_Base):
    """These ALLOWED before the fix and must still ALLOW: data that merely mentions a verb."""

    ALLOW = (
        'rg "' + G + ' push" docs/',
        'gh pr create --body "' + G + ' push guard added"',
        "echo '$(" + G + " push)'",
        "echo '`" + G + " push`'",
        "echo '" + G + " push'",
        "bash -c '" + G + " status'",
        "bash -c 'echo hello'",
        "bash -c 'echo " + G + "'",
        'echo $(' + G + ' rev-parse HEAD)',
        G + ' log --oneline | head',
        "sh -c 'ls -la'",
        'echo "$(' + G + ' rev-parse --short HEAD)"',
        G + ' -C "$(' + G + ' rev-parse --show-toplevel)" status',
        "eval 'echo " + G + " status'",
        'echo hi # $(' + G + ' push origin main)',
        'echo hi # `' + G + ' push origin main`',
        "# don't\necho " + G + " status",
        'echo a#b $(' + G + ' diff)',
        "cat <<'EOF'\n$(" + G + " push origin main)\nEOF",
        "cat <<'EOF'\nrun `" + G + " push` later, don't forget\nEOF",
        "cat <<\"EOF\"\n`" + G + " push`\nEOF",
        "bash script.sh -c '" + G + " push origin main'",          # -c AFTER the script is its arg
        "bash -c 'echo $((1+2))'",
        "echo ${#PATH} $# " + '"$(' + G + ' status)"',
        "x=$'" + G + " push origin main'",                        # a quoted assignment value
        "echo $'" + G + " push origin main'",
        "ls; env | grep " + G,
        'sudo ls ' + G,
    )

    def test_data_and_harmless_commands_still_allow(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_a_quoted_heredoc_commit_message_with_backticks_and_apostrophes_allows(self):
        for body in ('fix `' + G + ' push` guard', "don't break the " + G + " log", "`x` it's `y`"):
            cmd = ('CAST_COMMIT_AGENT=1 ' + G + ' commit -m "$(cat <<\'EOF\'\n' + body + '\nEOF\n)"')
            with self.subTest(body=body):
                self.assertAllows(cmd)

    def test_a_giant_git_free_segment_next_to_a_small_git_command_still_allows(self):
        code, msg, elapsed = self.timed(';'.join(['echo ' + 'x' * 100000] * 10) + '; ' + G + ' status')
        self.assertEqual((code, msg), (0, ''))
        self.assertLess(elapsed, BOUND_SECS * 2)


class TestHatchScoping(_Base):
    def test_a_hatch_before_a_shell_wrapper_does_not_reach_the_executed_string(self):
        self.assertBlocks("CAST_PUSH_OK=1 bash -c '" + G + " push origin main'")
        self.assertBlocks("CAST_PUSH_OK=1 eval '" + G + " push origin main'")
        self.assertBlocks('CAST_PUSH_OK=1 echo $(' + G + ' push origin main)')

    def test_a_hatch_inside_a_dash_c_string_is_still_refused_as_before(self):
        # UNCHANGED from before the fix (verified against HEAD): the OUTER segment's raw text
        # carries ` git push` with no leading hatch, and every `*_ALLOW` anchors at a segment start.
        self.assertBlocks("bash -c 'CAST_PUSH_OK=1 " + G + " push origin main'")

    def test_the_hatch_still_works_directly_and_in_a_substitution_argument(self):
        self.assertAllows('CAST_PUSH_OK=1 ' + G + ' push origin main')
        self.assertAllows('CAST_COMMIT_AGENT=1 ' + G + ' commit -m "$(cat msgfile)"')
        self.assertAllows('CAST_COMMIT_AGENT=1 ' + G + ' commit -m "$(date +%F)"')

    def test_a_hatch_on_one_segment_does_not_unblock_an_executed_string(self):
        self.assertBlocks('CAST_PUSH_OK=1 ' + G + " push origin main && bash -c '" + G + " push origin main'")
        self.assertBlocks('CAST_COMMIT_AGENT=1 ' + G + ' commit -m x; echo $(' + G + ' push origin main)')

    def test_a_hatch_is_honoured_inside_its_own_virtual_segment(self):
        # The engine, not the wrapper: a virtual segment that STARTS with a hatch is evaluated as
        # its own segment and is honoured (`_executable_segments` yields it; `evaluate` decides).
        segs = [s.strip() for s in gg._executable_segments("bash -c 'CAST_PUSH_OK=1 " + G + " push origin main'")]
        self.assertIn('CAST_PUSH_OK=1 ' + G + ' push origin main', segs)
        self.assertTrue(gg._PUSH_ALLOW.search('CAST_PUSH_OK=1 ' + G + ' push origin main'))


P = "bash -c '" + G + " push'"          # the payload every repro below must make the guard see
_NON_BLANK_SPACES = ('\xa0', '\x0b', '\x0c', '\r', '\x1c', '\x1d', '\x1e', '\x1f', '\x85',
                     ' ', ' ')


class TestSecurityRepros(_Base):
    """Security round 1 (H1): lexer desyncs that hid a later command. Every one must BLOCK."""

    def test_unquoted_heredoc_bodies_with_quote_like_characters(self):
        for body in ("don't", '5" pipe', 'see (note', "it's `ok`", '# not a comment'):
            with self.subTest(body=body):
                self.assertBlocks('cat <<EOF\n' + body + '\nEOF\n' + P)
        self.assertBlocks('cat <<EOF\n$(' + G + ' push)\nEOF')

    def test_non_blank_whitespace_does_not_start_a_comment(self):
        for ch in _NON_BLANK_SPACES:
            with self.subTest(ch=repr(ch)):
                self.assertBlocks('echo a' + ch + '#; ' + P)

    def test_parameter_expansion_with_an_unbalanced_paren(self):
        for expansion in ('${x//(/y}', '${x:-(}', '${x#(}', '${x%)}'):
            with self.subTest(expansion=expansion):
                self.assertBlocks('echo ' + expansion + '; ' + P)

    def test_dollar_dollar_then_a_quote(self):
        self.assertBlocks("echo $$'a\\'; " + P)
        self.assertBlocks("echo $(echo \\$'a\\'); " + P)

    def test_arithmetic_shift_is_not_a_heredoc(self):
        self.assertBlocks("echo $((1<<'2'))\n" + P)
        self.assertBlocks("(( x=1<<'2' ))\n" + P)

    def test_heredoc_delimiters_that_cannot_be_quote_removed_with_certainty(self):
        for delim in ("$'EOF'", '$"EOF"', '"E\'F"', '"a\\"b"'):
            with self.subTest(delim=delim):
                self.assertBlocks('cat <<' + delim + '\nx\nEOF\n' + P)


class TestExtractor(_Base):
    """`_executed_code` / `_shell_payloads` directly."""

    @staticmethod
    def code(text):
        return gg._executed_code(text, [10 ** 6, 10 ** 6])

    def test_dash_c_operands(self):
        c = self.code
        self.assertEqual(c("bash -c 'a; b'"), ['a; b'])
        self.assertEqual(c("bash -o pipefail -c 'x'"), ['x'])
        self.assertEqual(c("bash -c -- 'x'"), ['x'])
        self.assertEqual(c("sudo -u root bash -c 'x'"), ['x'])
        self.assertEqual(c("timeout 5 sh -c 'x y'"), ['x y'])
        self.assertEqual(c("FOO=1 BAR='a b' bash -ec \"x\""), ['x'])
        self.assertEqual(c("if true; then bash -c 'x'; fi"), ['x'])
        self.assertEqual(c("bash script.sh -c 'x'"), [])
        self.assertEqual(c("bash -c"), [])
        self.assertEqual(c("rg bash -c 'x'"), [])
        self.assertEqual(c("echo bash -c 'x'"), [])

    def test_eval_arguments_are_joined(self):
        self.assertEqual(self.code("eval 'a' b \"c d\""), ['a b c d'])
        self.assertEqual(self.code('eval'), [])

    def test_substitutions_are_outermost_only(self):
        # nested ones are found when that body is scanned one level down
        self.assertEqual(self.code('echo $(a $(b) c) `d` "$(e)"'), ['a $(b) c', 'd', 'e'])
        self.assertEqual(self.code('echo "$(echo "$(deep)")"'), ['echo "$(deep)"'])
        self.assertEqual(self.code('`echo \\`inner\\``'), ['echo `inner`'])
        self.assertEqual(self.code('echo <(x) >(y) (z)'), ['x', 'y', 'z'])

    def test_quotes_escapes_and_comments(self):
        c = self.code
        self.assertEqual(c("echo '$(f)' \\$(g)"), ['g'])               # `\$` is a literal dollar...
        self.assertEqual(c('echo "a\\$(b)"'), [])                       # ...and so inside double quotes
        self.assertEqual(c("echo a#b `x` # `y` it's\nbash -c 'z'"), ['x', 'z'])
        self.assertEqual(c('echo ${#a} $# `q`'), ['q'])
        self.assertEqual(c('echo $(a # ) b\n c)'), ['a # ) b\n c'])

    def test_quoted_heredoc_bodies_are_skipped_unquoted_ones_are_not(self):
        c = self.code
        self.assertEqual(c("cat <<'EOF'\n$(x) `y` don't\nEOF\nbash -c 'after'"), ['after'])
        self.assertEqual(c("cat <<-'EOF'\n\t$(x)\n\tEOF\nbash -c 'after'"), ['after'])
        self.assertEqual(c("cat <<EOF\n$(x)\nEOF\nbash -c 'after'"), ['x', 'after'])
        self.assertEqual(c("bash <<< 'x'; bash -c y"), ['y'])
        self.assertEqual(c('m="$(cat <<\'EOF\'\ndon\'t `x`\nEOF\n)"; bash -c \'z\''),
                         ["cat <<'EOF'\ndon't `x`\nEOF\n", 'z'])

    def test_unresolved_input_without_git_after_it_returns_what_was_found_before_it(self):
        # Nothing from the unresolved construct to the end can spell git, so the codes extracted
        # before it are complete and are returned (the refinement of the fail-closed rule).
        c = self.code
        self.assertEqual(c("echo 'unterminated; bash -c 'x'"), [])
        self.assertEqual(c("echo $(unterminated; bash -c 'x'"), [])
        self.assertEqual(c("bash -c 'x' $(unterm"), ['x'])      # a command already complete is kept
        self.assertEqual(c('echo "unterminated $(x'), [])
        self.assertEqual(c("echo $(" + G + " status) 'unterminated"), [G + ' status'])

    def test_the_scanner_only_ever_raises_its_own_signals(self):
        rng = random.Random(20261006)
        alphabet = ["'", '"', '`', '$', '(', ')', '\\', '<', '<<', '<<-', '\n', ';', '|', '&', ' ', '#', 'a',
                    'bash', ' -c ', 'eval', G, 'EOF', '-', '$(', "$'", "<<'EOF'", '\t', '${', '}', '((', '))',
                    '$((', '>', '>&', 'case', ' in ', 'esac', ';;', '\r']
        for _ in range(8000):
            s = ''.join(rng.choice(alphabet) for _ in range(rng.randint(0, 28)))
            try:
                out = self.code(s)
            except gg._LexUncertain:
                out = []
            self.assertIsInstance(out, list, repr(s))
            self.assertTrue(all(isinstance(x, str) for x in out), repr(s))
            segs = list(gg._executable_segments(s))         # never raises: a Refusal instead
            self.assertTrue(all(isinstance(x, (str, gg._Refusal)) for x in segs), repr(s))

    def test_real_segments_come_first_and_are_unchanged(self):
        for cmd in ("bash -c '" + G + " push; ls'", 'echo $(' + G + ' status) && ls\nls', G + ' status | head',
                    'a; b || c\nd \\\ne'):
            real = list(gg._scannable_segments(cmd))
            self.assertEqual(list(gg._executable_segments(cmd))[:len(real)], real, cmd)

    def test_text_without_git_is_never_scanned(self):
        # nested code is a de-quoted rewrite of its parent: no `g..i..t` spelling, nothing to find
        calls = []
        with mock.patch.object(gg, '_executed_code', side_effect=lambda *a: calls.append(a) or []):
            list(gg._executable_segments("bash -c 'echo $(ls)' ; eval 'ls'"))
        self.assertEqual(calls, [])

    def test_a_scanner_crash_fails_closed_not_open(self):
        with mock.patch.object(gg, '_executed_code', side_effect=RuntimeError('boom')):
            code, msg = self.verdict('echo hi; ' + G + ' status')
            self.assertEqual(code, 2)
            self.assertEqual(msg, gg._LEX_UNCERTAIN_MSG)
            self.assertAllows('echo hi; ls')                # no git mention: the scanner never runs
            segs = list(gg._executable_segments('echo hi; ' + G + ' status'))
            self.assertEqual(segs[:2], ['echo hi', ' ' + G + ' status'])    # real segments first
            self.assertIsInstance(segs[-1], gg._Refusal)
            self.assertBlocks(G + ' push origin main')      # and the real segments still decide


def _code(text):
    return gg._executed_code(text, [10 ** 6, 10 ** 6])


def _commands(text):
    """The words of every simple command the lexer builds, as lists of (text, is-redirection-operator)
    pairs - captured from the `_shell_payloads` calls (the only consumer of the words)."""
    calls = []
    with mock.patch.object(gg, '_shell_payloads',
                           side_effect=lambda w: calls.append([(str(x), x.redir) for x in w]) or []):
        _code(text)
    return calls


class TestA1FailsClosedOnUncertainty(_Base):
    """A1: every place the scanner cannot model the input raises `_LexUncertain`, and
    `_executable_segments` turns that into a `_Refusal` - a command that mentions git AFTER the
    unresolved construct is BLOCKED, never silently allowed."""

    UNRESOLVED = {
        'unterminated single quote': "echo 'x; " + G + ' status',
        'unterminated double quote': 'echo "x $(echo y) ; ' + G + ' status',
        'unterminated backtick': 'echo `x; ' + G + ' status',
        'unterminated ANSI-C quote': "echo $'x\\'; " + G + ' status',
        'unclosed $(': 'echo $(x; ' + G + ' status',
        'unclosed (': '(x; ' + G + ' status',
        'unclosed ${': 'echo ${x:-y; ' + G + ' status',
        'unclosed $((': 'echo $((1+2; ' + G + ' status',
        'unclosed ((': '((1+2; ' + G + ' status',
        'heredoc word is a variable': 'cat <<$x\n' + G + ' status\n',
        'heredoc word missing': 'cat <<\n' + G + ' status\n',
        'heredoc delimiter line missing': 'cat <<EOF\n' + G + ' status\n',
        'old $[ arithmetic': 'echo $[1+2]; ' + G + ' status',
        'quote in arithmetic': 'echo $(( "1" + 2 )); ' + G + ' status',
        'quote in ${} in double quotes': 'echo "${x:-\'y\'}"; ' + G + ' status',
        'nested past the limit': '$(' * (gg._MAX_LEX_NEST + 5) + G + ' status',
    }

    def test_each_unresolved_construct_raises_and_is_refused(self):
        for label, cmd in self.UNRESOLVED.items():
            with self.subTest(label):
                with self.assertRaises(gg._LexUncertain):
                    _code(cmd)
                segs = list(gg._executable_segments(cmd))
                self.assertIsInstance(segs[-1], gg._Refusal)
                self.assertEqual(segs[-1].msg, gg._LEX_UNCERTAIN_MSG)
                code, msg = self.verdict(cmd)
                self.assertEqual(code, 2)
                self.assertIn('could not parse', msg)

    def test_the_same_constructs_inside_a_substitution_are_refused_too(self):
        for label, cmd in self.UNRESOLVED.items():
            if label.startswith(('nested', 'unclosed', 'unterminated')):
                continue            # these end the enclosing substitution too: not a distinct case
            wrapped = 'echo $(' + cmd + '\n)'
            with self.subTest(label):
                code, msg = self.verdict(wrapped)
                self.assertEqual(code, 2, wrapped)

    def test_no_git_after_the_unresolved_construct_returns_the_codes_found_before_it(self):
        self.assertEqual(_code("bash -c 'x' $(unterm"), ['x'])
        self.assertEqual(_code('bash -c "y"; echo "unterminated'), ['y'])
        self.assertEqual(_code("bash -c 'x'; cat <<EOF\nbody"), ['x'])
        # ... and a harmless git command BEFORE it is still evaluated (and allowed)
        self.assertAllows('echo $(' + G + " status) 'unterminated")

    def test_git_after_the_construct_blocks_even_a_harmless_command(self):
        self.assertBlocks("echo 'unterminated; " + G + ' status')
        self.assertBlocks('echo $(unterminated ' + G + ' status')

    def test_the_earliest_unresolved_construct_is_used(self):
        # The git mention sits between the open `"` and the inner unterminated `'`: judged from the
        # innermost construct it would look clear, from the earliest open one it is not.
        self.assertBlocks('echo "' + G + " status $(echo 'x")

    def test_a_scanner_crash_is_a_refusal_not_an_allow(self):
        with mock.patch.object(gg, '_Lexer', side_effect=ValueError('boom')):
            self.assertEqual(self.verdict('echo hi; ' + G + ' status')[1], gg._LEX_UNCERTAIN_MSG)


class TestA2BlanksAreOnlySpaceTabNewline(_Base):
    """A2: in bash `\\r`, `\\xa0`, `\\x0b`, `\\x0c`, `\\x1c`-`\\x1f`, `\\x85` are WORD characters
    (Python's `\\s` and `str.split()` treat them as blanks), so `echo a<ch>#; P` is no comment."""

    CHARS = ('\r', '\xa0', '\x0b', '\x0c', '\x1c', '\x1d', '\x1e', '\x1f', '\x85', '\u2003', '\u2028')

    def test_a_hash_after_a_non_blank_is_part_of_the_word(self):
        for ch in self.CHARS:
            with self.subTest(ch=repr(ch)):
                self.assertEqual(_code('echo a' + ch + "#; bash -c 'x'"), ['x'])
                self.assertEqual(_code('echo ' + ch + "#; bash -c 'x'"), ['x'])

    def test_a_hash_after_a_real_blank_starts_a_comment(self):
        for sep in (' ', '\t', '  ', ' \t '):
            with self.subTest(sep=repr(sep)):
                self.assertEqual(_code('echo a' + sep + "#; bash -c 'x'"), [])
        self.assertEqual(_code("echo a\n# bash -c 'x'\nbash -c 'y'"), ['y'])
        self.assertEqual(_code("echo a;# bash -c 'x'\nbash -c 'y'"), ['y'])

    def test_a_non_blank_does_not_split_words(self):
        self.assertEqual(_commands('a\xa0b c\rd'), [[('a\xa0b', False), ('c\rd', False)]])

    def test_inside_a_substitution_too(self):
        for ch in self.CHARS:
            with self.subTest(ch=repr(ch)):
                self.assertBlocks('echo $(echo a' + ch + '#; ' + P + ')')
                self.assertBlocks('echo "$(echo a' + ch + '#; ' + P + ')"')

    def test_the_real_space_comment_is_still_a_comment_inside_a_substitution(self):
        self.assertAllows('echo $(echo a #; ' + P + '\n)')
        # (a comment runs to the end of the LINE: a `)` after it on that line is swallowed, so bash -
        # and the lexer - find the substitution unclosed)
        self.assertBlocks('echo $(echo a #; ' + P + ')')


class TestContinuationsAreTheLexersBusiness(_Base):
    """The scan reads the RAW command: `\\<newline>` is a continuation outside quotes but not in a
    comment or single quotes. (Pre-joining merged a comment line with the next one and hid a
    command: found by the real-bash oracle fuzz.)"""

    def test_a_backslash_newline_in_a_comment_does_not_extend_the_comment(self):
        self.assertEqual(_code("echo hi # c \\\nbash -c 'x'"), ['x'])
        self.assertBlocks("echo x # it's \\\n" + P)
        self.assertBlocks("echo x # it's ; (){ :; } ; echo a\\\nb; echo `" + G + ' push`')
        self.assertBlocks('echo $(echo hi # c \\\n' + P + '\n)')

    def test_in_single_quotes_it_is_literal_and_outside_quotes_it_joins(self):
        self.assertEqual(_code("echo 'a\\\nb'; bash -c 'x'"), ['x'])
        self.assertEqual(_commands('ec\\\nho a'), [[('echo', False), ('a', False)]])
        self.assertEqual(_commands('echo "a\\\nb"'), [[('echo', False), ('ab', False)]])
        self.assertEqual(_commands('echo a\\\n b'), [[('echo', False), ('a', False), ('b', False)]])

    def test_a_git_spelled_across_a_continuation_is_still_seen(self):
        self.assertBlocks('bash -c "gi\\\nt push"')
        self.assertBlocks('echo $(gi\\\nt push)')
        self.assertTrue(gg._git_mentioned('gi\\\nt'))
        self.assertFalse(gg._git_mentioned('gi\\\nx'))
        self.assertTrue(gg._git_mentioned('xx gi\\\nt', 3))


class TestA3Heredocs(_Base):
    def test_every_pending_heredoc_of_a_line_is_tracked_in_order(self):
        text = "cat <<A <<'B' <<C\n$(x)\nA\n$(y)\nB\n$(z)\nC\nbash -c 'after'"
        self.assertEqual(_code(text), ['x', 'z', 'after'])         # B is quoted: its body is data
        self.assertEqual(_code("cat <<'A' <<'B'\n$(x)\nA\n$(y)\nB\nbash -c 'after'"), ['after'])

    def test_an_unquoted_body_is_double_quote_like(self):
        # `'`, `"`, `(`, `#` are literal data there; the next line still runs
        for body in ("don't", '5" pipe', 'see (note', '# not a comment', "a ' b \" c (", "it's `x` don't"):
            with self.subTest(body=body):
                out = _code('cat <<EOF\n' + body + "\nEOF\nbash -c 'after'")
                self.assertEqual(out[-1], 'after')

    def test_an_unquoted_body_expands_substitutions_but_honours_escapes(self):
        self.assertEqual(_code('cat <<EOF\n$(x) and `y` and ${z:-$(w)}\nEOF'), ['x', 'y', 'w'])
        self.assertEqual(_code('cat <<EOF\n\\$(x) \\`y\\` \\\\$(w)\nEOF'), ['w'])

    def test_a_dash_heredoc_strips_leading_tabs_from_body_and_delimiter(self):
        self.assertEqual(_code("cat <<-EOF\n\t$(x)\n\t\tEOF\nbash -c 'after'"), ['x', 'after'])
        self.assertEqual(_code("cat <<-'EOF'\n\t$(x)\n\tEOF\nbash -c 'after'"), ['after'])
        # without `-` a tab-indented delimiter does NOT end the body
        self.assertEqual(_code("cat <<EOF\n$(x)\n\tEOF\nEOF\nbash -c 'after'"), ['x', 'after'])

    def test_quoted_delimiters_make_the_body_literal(self):
        for word in ("'EOF'", '"EOF"', '\\EOF', 'E"O"F', "E'O'F", 'EO\\F', '"E""O"F'):
            with self.subTest(word=word):
                self.assertEqual(_code('cat <<' + word + "\n$(x)\nEOF\nbash -c 'after'"), ['after'])
        self.assertEqual(_code("cat <<EOF\n$(x)\nEOF\nbash -c 'after'"), ['x', 'after'])

    def test_a_delimiter_that_cannot_be_quote_removed_with_certainty_is_uncertain(self):
        for word in ("$'EOF'", '$"EOF"', '"E\'F"', '"a\\"b"', '$x', '`x`', '"$x"', '"a\\b"', '(', ';'):
            with self.subTest(word=word):
                with self.assertRaises(gg._LexUncertain):
                    _code('cat <<' + word + '\nx\nEOF\n' + P)

    def test_a_herestring_is_not_a_heredoc(self):
        self.assertEqual(_code("bash <<< 'x'; bash -c y"), ['y'])
        self.assertEqual(_code('cat <<< $(x)\nbash -c y'), ['x', 'y'])
        self.assertEqual(_code('cat <<<$(x); bash -c y'), ['x', 'y'])

    def test_a_missing_delimiter_line_is_uncertain_only_with_git_after_it(self):
        with self.assertRaises(gg._LexUncertain):
            _code('cat <<EOF\n' + G + ' status')
        self.assertEqual(_code("bash -c 'x'; cat <<EOF\nbody"), ['x'])

    def test_a_heredoc_inside_a_substitution(self):
        text = 'x="$(cat <<EOF\nit\'s "quoted" (x\nEOF\n)"; bash -c \'after\''
        self.assertEqual(_code(text), ['cat <<EOF\nit\'s "quoted" (x\nEOF\n', 'after'])
        self.assertBlocks('echo "$(cat <<EOF\nit\'s (x\nEOF\n)"; ' + P)
        self.assertBlocks('echo $(cat <<EOF\n$(' + G + ' push)\nEOF\n)')

    def test_the_delimiter_line_must_match_exactly(self):
        self.assertEqual(_code("cat <<EOF\nEOF \nEOFX\n$(x)\nEOF\nbash -c 'after'"), ['x', 'after'])


class TestA4ParameterExpansion(_Base):
    def test_parens_inside_are_literal(self):
        for exp in ('${x//(/y}', '${x:-(}', '${x#(}', '${x%)}', '${x//)/(}', '${x:+((}'):
            with self.subTest(exp=exp):
                self.assertEqual(_code('echo ' + exp + "; bash -c 'x'"), ['x'])

    def test_nested_expansions_are_extracted(self):
        self.assertEqual(_code('echo ${x:-$(a)}'), ['a'])
        self.assertEqual(_code('echo ${x:-`b`}'), ['b'])
        self.assertEqual(_code('echo ${x:-${y:-$(c)}}'), ['c'])
        self.assertEqual(_code('echo ${x:-$((1+2))}'), ['1+2'])

    def test_the_first_unescaped_brace_closes_it(self):
        self.assertEqual(_code('echo ${x:-a}}; bash -c y'), ['y'])
        self.assertEqual(_code('echo ${x:-\\}}; bash -c y'), ['y'])
        self.assertEqual(_code("echo ${x:-'}'}; bash -c y"), ['y'])
        self.assertEqual(_code('echo ${x:-"}"}; bash -c y'), ['y'])
        self.assertEqual(_code("echo ${x:-$'}'}; bash -c y"), ['y'])

    def test_quotes_inside_a_double_quoted_expansion_are_uncertain_except_ansi_c(self):
        for cmd in ('echo "${x:-\'a\'}"', 'echo "${x:-"a"}"', 'echo "${x//\'/y}"'):
            with self.subTest(cmd=cmd):
                with self.assertRaises(gg._LexUncertain):
                    _code(cmd + '; ' + G + ' status')
        # bash's default `extquote`: `$'..'` IS performed inside "${...}"
        self.assertEqual(_code('echo "${x%$\'\\n\'}"; bash -c y'), ['y'])
        self.assertAllows('x="${y%$\'\\n\'}"; ' + G + ' status')

    def test_inside_a_substitution_too(self):
        for exp in ('${x//(/y}', '${x:-(}', '${x#(}'):
            with self.subTest(exp=exp):
                self.assertBlocks('echo $(echo ' + exp + '); ' + P)
                self.assertBlocks('echo $(echo ' + exp + '; ' + P + ')')


class TestA5DollarForms(_Base):
    def test_special_parameters_are_units_so_a_following_quote_is_ordinary(self):
        for unit in ('$$', '$?', '$#', '$!', '$@', '$*', '$-', '$0', '$9', '$name', '$_x1'):
            with self.subTest(unit=unit):
                self.assertEqual(_code('echo ' + unit + "'a\\'; bash -c 'x'"), ['x'])

    def test_an_escaped_dollar_is_literal_everywhere(self):
        self.assertEqual(_code("echo \\$'a\\'; bash -c 'x'"), ['x'])
        self.assertEqual(_code("echo $(echo \\$'a\\'); bash -c 'x'"), ["echo \\$'a\\'", 'x'])
        self.assertEqual(_code('echo "\\$(y)"; bash -c x'), ['x'])

    def test_ansi_c_quotes_honour_escaped_quotes(self):
        self.assertEqual(_code("echo $'a\\'b'; bash -c 'x'"), ['x'])
        self.assertEqual(_code("echo $'a\\\\'; bash -c 'x'"), ['x'])
        with self.assertRaises(gg._LexUncertain):
            _code("echo $'a\\'; " + G + ' status')

    def test_a_lone_dollar_is_literal(self):
        self.assertEqual(_code('echo $ x; echo "$"; echo $; bash -c y'), ['y'])
        self.assertEqual(_code("echo '$'\"$\"; bash -c y"), ['y'])

    def test_old_arithmetic_brackets_are_uncertain(self):
        with self.assertRaises(gg._LexUncertain):
            _code('echo $[1+2]; ' + G + ' status')
        self.assertEqual(_code('echo $[1+2]; ls'), [])          # git-free: nothing to refuse

    def test_inside_a_substitution_too(self):
        self.assertBlocks("echo $(echo $$'a\\'); " + P)
        self.assertBlocks("echo $(echo $#'a\\'; " + P + ')')
        self.assertBlocks("echo \"$(echo \\$'a\\'; " + P + ')"')


class TestA6Arithmetic(_Base):
    def test_a_shift_is_not_a_heredoc(self):
        self.assertEqual(_code("echo $((1<<2)); bash -c 'x'"), ['1<<2', 'x'])
        self.assertEqual(_code("(( x=1<<2 ))\nbash -c 'x'"), [' x=1<<2 ', 'x'])
        self.assertEqual(_code("echo $((1>>2)); bash -c 'x'"), ['1>>2', 'x'])
        self.assertEqual(_code("for ((i=0;i<3;i++)); do bash -c 'x'; done"), ['i=0;i<3;i++', 'x'])
        self.assertEqual(_code("if (( a<<1 )); then bash -c 'x'; fi"), [' a<<1 ', 'x'])

    def test_the_body_is_emitted_as_code_and_substitutions_in_it_are_found_through_it(self):
        self.assertEqual(_code('echo $(( $(a) + `b` ))'), [' $(a) + `b` '])
        self.assertBlocks('echo $(( $(' + G + ' push) + 1 ))')
        self.assertBlocks('(( x = $(' + G + ' push) ))')
        self.assertBlocks('echo $(( ' + G + ' push ))')          # bash's `((` vs `( (` ambiguity

    def test_a_lone_paren_closer_is_a_nested_subshell_not_arithmetic(self):
        self.assertEqual(_code('x=$((echo a); echo b)'), ['(echo a); echo b'])
        self.assertEqual(_code('((echo a) | (echo b)); bash -c y'), ['(echo a) | (echo b)', 'y'])
        self.assertBlocks('x=$((' + G + ' push); true)')

    def test_parens_nest(self):
        self.assertEqual(_code('echo $(( (1+2)*(3) )); bash -c y'), [' (1+2)*(3) ', 'y'])
        self.assertEqual(_code('echo $(((1+2))); bash -c y'), ['(1+2)', 'y'])

    def test_any_quote_directly_in_arithmetic_is_uncertain(self):
        for cmd in ("echo $((1<<'2'))", "(( x=1<<'2' ))", 'echo $(( "1" ))', "(( 'a' ))", 'echo $(( 1 + "2" ))'):
            with self.subTest(cmd=cmd):
                with self.assertRaises(gg._LexUncertain):
                    _code(cmd + '\n' + G + ' status')

    def test_a_quote_inside_a_nested_substitution_is_fine(self):
        self.assertEqual(_code("echo $(( $(echo '1') + 1 )); bash -c y"), [" $(echo '1') + 1 ", 'y'])

    def test_inside_a_substitution_too(self):
        self.assertBlocks("echo $(echo $((1<<'2'))\n" + P + ')')
        self.assertBlocks("echo $((1<<'2'))\n" + P)
        self.assertBlocks("echo $( (( x=1<<'2' ))\n" + P + ' )')


class TestA7OneLexer(_Base):
    """A7: a `$(...)` body is lexed by the SAME routine as the top level, so every rule above holds
    in it. Each repro blocks bare, in `$(...)`, in `"$(...)"` and in a subshell."""

    REPROS = (
        'echo a\xa0#; ' + P,
        'echo ${x//(/y}; ' + P,
        'echo ${x:-(}; ' + P,
        "echo $$'a\\'; " + P,
        "echo \\$'a\\'; " + P,
        'cat <<EOF\ndon\'t\nEOF\n' + P,
        'cat <<EOF\n5" pipe\nEOF\n' + P,
        'cat <<EOF\nsee (note\nEOF\n' + P,
        "echo $((1<<'2'))\n" + P,
        "(( x=1<<'2' ))\n" + P,
        "cat <<$'EOF'\nx\nEOF\n" + P,
        'echo "${x:-"y"}"; ' + P,
        'echo $[1]; ' + P,
    )

    def test_every_repro_blocks_in_every_context(self):
        for r in self.REPROS:
            for tmpl in ('@', 'echo $(@\n)', 'echo "$(@\n)"', '(@\n)', 'x=`@`'):
                cmd = tmpl.replace('@', r)
                if '`' in tmpl:
                    cmd = tmpl.replace('@', r.replace('\\', '\\\\').replace('`', '\\`').replace('$', '\\$'))
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_case_patterns_do_not_close_a_substitution(self):
        text = "x=$(case $y in a) echo 1;; b|c) echo 2;; esac); bash -c 'after'"
        self.assertEqual(_code(text), ['case $y in a) echo 1;; b|c) echo 2;; esac', 'after'])
        self.assertEqual(_code('x=$(case $y in (a) echo 1;; (b) echo 2;; esac); bash -c z'),
                         ['case $y in (a) echo 1;; (b) echo 2;; esac', 'z'])
        self.assertEqual(_code('x=$(case a in a) case b in b) echo 1;; esac;; esac); bash -c z')[-1], 'z')
        self.assertEqual(_code('x=$(case a in a) echo esac;; esac); bash -c z')[-1], 'z')
        self.assertEqual(_code('x=$(case a in a) echo 1\nesac); bash -c z')[-1], 'z')
        self.assertEqual(_code('x=$(if true; then case a in a) echo 1;; esac; fi); bash -c z')[-1], 'z')
        self.assertEqual(_code('"$(case a in "a)") echo 1;; esac)"; bash -c z')[-1], 'z')

    def test_case_in_a_substitution_with_git_inside_allows_and_blocks_correctly(self):
        self.assertAllows('x=$(case $y in a) ' + G + ' status;; esac)')
        self.assertAllows('x=$(case "$(' + G + ' rev-parse HEAD)" in a*) echo 1;; *) echo 2;; esac); ls')
        self.assertBlocks('x=$(case $y in a) ' + G + ' push origin main;; esac)')
        self.assertBlocks('x=$(case $y in a) echo 1;; esac); ' + P)

    def test_a_case_at_top_level_is_tracked_the_same_way(self):
        self.assertEqual(_code("case a in a) bash -c 'x';; b) bash -c 'y';; esac; bash -c z"), ['x', 'y', 'z'])


class TestA8Redirections(_Base):
    def test_ampersand_inside_a_redirection_is_not_a_separator(self):
        self.assertEqual(_commands('echo hi 2>&1 | cat'),
                         [[('echo', False), ('hi', False), ('2>&', True), ('1', False)], [('cat', False)]])
        self.assertEqual(_commands('echo a >&2; echo b'),
                         [[('echo', False), ('a', False), ('>&', True), ('2', False)], [('echo', False), ('b', False)]])
        self.assertEqual(_commands('cat <&0'), [[('cat', False), ('<&', True), ('0', False)]])
        self.assertEqual(_commands('echo a &>f; echo b'),
                         [[('echo', False), ('a', False), ('&>', True), ('f', False)], [('echo', False), ('b', False)]])
        self.assertEqual(_commands('echo a &>>f'), [[('echo', False), ('a', False), ('&>>', True), ('f', False)]])

    def test_real_separators_still_separate(self):
        self.assertEqual(_commands('a & b'), [[('a', False)], [('b', False)]])
        self.assertEqual(_commands('a && b || c'), [[('a', False)], [('b', False)], [('c', False)]])
        self.assertEqual(_commands('a |& b'), [[('a', False)], [('b', False)]])      # `|&` is a pipe
        self.assertEqual(_commands('a | b'), [[('a', False)], [('b', False)]])

    def test_every_operator_is_its_own_token(self):
        for op in ('>', '>>', '<', '<>', '>|', '>&', '<&'):
            with self.subTest(op=op):
                self.assertEqual(_commands('cat ' + op + 'f'), [[('cat', False), (op, True), ('f', False)]])

    def test_a_digit_word_right_before_an_operator_is_the_fd(self):
        self.assertEqual(_commands('echo 2>f'), [[('echo', False), ('2>', True), ('f', False)]])
        self.assertEqual(_commands('echo 12>>f'), [[('echo', False), ('12>>', True), ('f', False)]])
        self.assertEqual(_commands('echo a2>f'), [[('echo', False), ('a2', False), ('>', True), ('f', False)]])
        self.assertEqual(_commands("echo '2'>f"), [[('echo', False), ('2', False), ('>', True), ('f', False)]])
        self.assertEqual(_commands('echo 2 >f'), [[('echo', False), ('2', False), ('>', True), ('f', False)]])

    def test_heredoc_and_herestring_operators_are_tokens_with_their_word(self):
        self.assertEqual(_commands('cat <<EOF\nx\nEOF'), [[('cat', False), ('<<', True), ('EOF', False)]])
        self.assertEqual(_commands('cat <<-"E"\nx\nE'), [[('cat', False), ('<<-', True), ('"E"', False)]])
        self.assertEqual(_commands('cat <<< "a b"'), [[('cat', False), ('<<<', True), ('a b', False)]])
        self.assertEqual(_commands('cat 3<<EOF\nx\nEOF'), [[('cat', False), ('3<<', True), ('EOF', False)]])

    def test_words_carry_their_raw_span(self):
        text = "echo 'a b' x\"y\" 2>&1 >out"
        spans = []
        with mock.patch.object(gg, '_shell_payloads',
                               side_effect=lambda w: spans.extend((str(x), text[x.start:x.end]) for x in w) or []):
            _code(text)
        self.assertEqual(spans, [('echo', 'echo'), ('a b', "'a b'"), ('xy', 'x"y"'), ('2>&', '2>&'),
                                 ('1', '1'), ('>', '>'), ('out', 'out')])

    def test_process_substitution_is_a_word_and_its_body_is_code(self):
        self.assertEqual(_code('diff <(a) >(b) c'), ['a', 'b'])
        self.assertEqual(_commands('diff <(a b) x')[0], [('diff', False), ('<(a b)', False), ('x', False)])

    def test_inside_a_substitution_too(self):
        self.assertBlocks('x=$(cat <&0 | ' + P + ' 2>&1)')
        self.assertBlocks('echo $(echo a &>/dev/null; ' + P + ')')
        self.assertBlocks('echo "$(echo a >&2 | ' + P + ')"')
        self.assertBlocks('echo $(cat <<A <<\'B\'\n$(' + G + ' push)\nA\ntext\nB\n)')

    def test_a_shell_after_a_redirection_still_hands_over_its_payload(self):
        self.assertEqual(_code("bash -c 'x' 2>&1"), ['x'])
        self.assertEqual(_code("bash -c 'x' >/dev/null 2>&1 &"), ['x'])


class TestA9Budget(_Base):
    def test_a_huge_unquoted_heredoc_next_to_one_git_mention_is_not_refused(self):
        # Security L2: this went ALLOW -> BLOCK on the step cap when the body was lexed word by word.
        body = ('lorem ipsum dolor sit amet, consectetur $x adipiscing elit sed do eiusmod\n' * 22000)[:1_600_000]
        cmd = 'cat > f <<EOF\n' + body + '\nEOF\n' + G + ' log'
        code, msg, elapsed = self.timed(cmd)
        self.assertEqual((code, msg), (0, ''))
        self.assertLess(elapsed, BOUND_SECS * 2)

    def test_a_huge_quoted_heredoc_next_to_one_git_mention_is_not_refused(self):
        body = ('lorem ipsum dolor sit amet, consectetur $x `y` adipiscing elit sed do eiusmod\n' * 22000)[:1_600_000]
        code, msg, elapsed = self.timed("cat > f <<'EOF'\n" + body + '\nEOF\n' + G + ' log')
        self.assertEqual((code, msg), (0, ''))
        self.assertLess(elapsed, BOUND_SECS * 2)

    def test_the_cap_is_far_above_any_hand_written_command(self):
        # 2,000 commands of a dozen words each - well past anything typed - stays under the cap
        cmd = '\n'.join(['echo a b c d e f g h i j k $(echo l) "m n" \'o p\''] * 2000) + '\n' + G + ' status'
        budget = [gg._MAX_EXEC_SCAN_STEPS, gg._MAX_EXEC_CODES]
        gg._executed_code(cmd, budget)
        self.assertGreater(budget[0], gg._MAX_EXEC_SCAN_STEPS // 2)
        self.assertAllows(cmd)

    def test_padded_input_is_refused_fast_not_scanned_to_the_end(self):
        # RESIDUAL (documented): more words/metacharacters than the cap AND a git mention = refused,
        # in bounded time - the scanner itself, on 5 MB of every padding shape, is far under the
        # dispatcher's 2 s (the cap is ~250k steps; a step is a few microseconds).
        lorem = 'lorem ipsum dolor sit amet, consectetur $x adipiscing elit sed do eiusmod\n'
        shapes = {
            'short lines': ('x y z\n' * 800_000) + G + ' status',
            'words, two huge lines': ('w ' * 1_250_000 + '\n') * 2 + G + ' status',
            'blanks': (' ' * 5_000_000) + G + ' status',
            'metacharacters': (';' * 5_000_000) + G + ' status',
            'double quotes': ('"a" ' * 1_250_000) + G + ' status',
            'substitutions': ('$(a) ' * 1_000_000) + G + ' status',
            'heredoc dollars': 'cat <<EOF\n' + ('$x $y $z\n' * 500_000) + 'EOF\n' + G + ' log',
            'heredoc backticks': 'cat <<EOF\n' + ('`a` `b`\n' * 600_000) + 'EOF\n' + G + ' log',
            'double-quoted string': '"' + ('a $(b) ' * 700_000) + '" ' + G + ' status',
            'comments': ('# a b c\n' * 600_000) + G + ' status',
        }
        for name, cmd in shapes.items():
            with self.subTest(shape=name, length=len(cmd)):
                t0 = time.perf_counter()
                with self.assertRaises(gg._ExecOverBudget):
                    gg._executed_code(cmd, [gg._MAX_EXEC_SCAN_STEPS, gg._MAX_EXEC_CODES])
                self.assertLess(time.perf_counter() - t0, BOUND_SECS, name)

    def test_padded_input_is_blocked_end_to_end_within_the_budget(self):
        for name, cmd in {'metacharacters': (';' * 1_000_000) + G + ' status',
                          'substitutions': ('$(a) ' * 200_000) + G + ' status'}.items():
            with self.subTest(shape=name):
                code, msg, elapsed = self.timed(cmd)
                self.assertEqual(code, 2)
                self.assertLess(elapsed, 2.0, f'{name}: {elapsed:.2f} s')

    def test_a_failing_arithmetic_attempt_is_retried_as_a_subshell_but_stays_bounded(self):
        # Each `$((` is first read as arithmetic and, when it closes with a lone `)`, again as a
        # subshell: nested, that doubles per level. The shared step cap bounds it (fail closed).
        inner = G + ' status'
        for _ in range(40):
            inner = '$((' + inner + ' x); y)'
        code, msg, elapsed = self.timed(inner)
        self.assertEqual(code, 2)
        self.assertLess(elapsed, 2.0, f'{elapsed:.2f} s')

    def test_over_the_cap_the_refusal_says_so(self):
        with mock.patch.object(gg, '_MAX_EXEC_SCAN_STEPS', 100):
            code, msg = self.verdict(' '.join(['a b c'] * 200) + '\n' + G + ' status')
        self.assertEqual(code, 2)
        self.assertIn('far more', msg)

    def test_deep_nesting_is_refused_not_a_stack_overflow(self):
        for n in (100, 5000, 130000):
            with self.subTest(depth=n):
                code, msg, elapsed = self.timed('$(' * n + G + ' status')
                self.assertEqual(code, 2)
                self.assertLess(elapsed, BOUND_SECS)


class TestBounds(_Base):
    def test_more_nested_code_than_the_cap_is_refused(self):
        many = ' '.join(['echo $(' + G + ' status)'] * (gg._MAX_EXEC_CODES + 1))
        code, msg = self.verdict(many)
        self.assertEqual(code, 2)
        self.assertIn('nests far more', msg)
        self.assertAllows(' '.join(['echo $(' + G + ' status)'] * 100))

    def test_scanner_steps_are_capped(self):
        with mock.patch.object(gg, '_MAX_EXEC_SCAN_STEPS', 50):
            code, msg = self.verdict(' '.join(['echo a b c d $(' + G + ' status)'] * 40))
        self.assertEqual(code, 2)
        self.assertIn('nests far more', msg)

    def test_the_generator_yields_a_refusal_not_an_exception_when_out_of_budget(self):
        out = list(gg._executable_segments("bash -c '" + G + " status'", [0, 10]))
        self.assertTrue(any(isinstance(s, gg._Refusal) for s in out))
        self.assertTrue(all(isinstance(s, (str, gg._Refusal)) for s in out))

    def test_400kb_of_nested_padding_is_decided_fast_and_blocks(self):
        n = 400_000
        shapes = {
            'open-paren padding': '$(' * (n // 2) + G + ' push origin main',
            'balanced nesting': '$(' * 130000 + G + ' status' + ')' * 130000 + '; ' + G + ' push origin main',
            'dash-c padding': ("bash -c 'echo " + G + " status'; ") * (n // 30) + G + ' push origin main',
            'nested dash-c padding': ('bash -c "bash -c \'x\'" ; ') * (n // 25) + G + ' push origin main',
            'eval padding': ('eval ' + G + ' status; ') * (n // 20) + G + ' push origin main',
            'backtick padding': ('`' + G + ' status` ') * (n // 12) + G + ' push origin main',
            'quote padding': ('"' + G + '" ') * (n // 6) + '; ' + G + ' push origin main',
            'heredoc padding': "cat <<'EOF'\n" + (G + ' status `x`\n') * (n // 14) + 'EOF\n' + G + ' push origin main',
        }
        for name, cmd in shapes.items():
            with self.subTest(shape=name, length=len(cmd)):
                code, msg, elapsed = self.timed(cmd)
                self.assertEqual(code, 2, f'{name}: allowed')
                self.assertLess(elapsed, BOUND_SECS, f'{name}: {elapsed:.2f} s')


if __name__ == '__main__':
    unittest.main()
