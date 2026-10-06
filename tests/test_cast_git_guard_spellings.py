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
  * the scanner never raises, is bounded (step / code-count / depth caps fail CLOSED) and is
    fast on 400 KB of nested padding;
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

    def test_unbalanced_input_stops_extraction_without_raising(self):
        c = self.code
        self.assertEqual(c("echo 'unterminated; bash -c 'x'"), [])
        self.assertEqual(c("echo $(unterminated; bash -c 'x'"), [])
        self.assertEqual(c("bash -c 'x' $(unterm"), ['x'])      # a command already complete is kept
        self.assertEqual(c('echo "unterminated $(x'), [])

    def test_the_scanner_never_raises_and_always_returns_strings(self):
        rng = random.Random(20261006)
        alphabet = ["'", '"', '`', '$', '(', ')', '\\', '<', '<<', '<<-', '\n', ';', '|', '&', ' ', '#', 'a',
                    'bash', ' -c ', 'eval', G, 'EOF', '-', '$(', "$'", "<<'EOF'", '\t']
        for _ in range(8000):
            s = ''.join(rng.choice(alphabet) for _ in range(rng.randint(0, 28)))
            out = self.code(s)
            self.assertIsInstance(out, list, repr(s))
            self.assertTrue(all(isinstance(x, str) for x in out), repr(s))
            list(gg._executable_segments(s))        # and the generator on top of it

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

    def test_a_scanner_crash_degrades_to_the_status_quo_not_an_exception(self):
        with mock.patch.object(gg, '_executed_code', side_effect=RuntimeError('boom')):
            self.assertEqual(self.verdict('echo hi; ' + G + ' status'), (0, ''))
            self.assertBlocks(G + ' push origin main')          # the real segments still decide


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
