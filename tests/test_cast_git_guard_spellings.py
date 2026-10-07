#!/usr/bin/env python3
"""Spelling / indirection bypasses of the Bash git guard (2026-10-06 security fix, High).

`scripts/cast-git-guard.py::evaluate("Bash")` ALLOWED (rc 0 on main) every one of these, all of
which the shell executes as a real guarded git command:

    bash -c 'git push origin main'      (also sh / zsh / dash / ksh, -lc, /bin/bash, env, sudo ...)
    eval "git push"                     echo $(git push)        echo `git push`
    GIT push   (APFS is case-insensitive)     $'git' push     $"git" push     git${IFS}push

Every BLOCK pattern anchors on `(^|\\s)git`, and `_normalize_git_segment` only ran when the
segment's first token had basename exactly `git`. The fix is ADDITIVE: `_executed_code` extracts
the code a command hands to a nested shell, the data piped into a shell that reads its stdin, and a
virtual `git ...` segment for every spelled git, and `_executable_segments` re-evaluates them as
extra segments through the same engine. `_normalize_git_segment`, `_scannable_segments` and
`_git_evaluate` are byte-identical to main (a rewrite of a REAL segment can remove a block); only
`_GIT_MENTION` (widened) and `_git_evaluate_impl` (iterates `_executable_segments`) changed. A hatch
is scoped to its own (virtual) segment: none passes through a spelling, and one INSIDE a `-c` /
`eval` payload is evaluated like the same direct command.

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
  * payloads are found at ANY word of a simple command (TestC1: redirections, assignments, `$SHELL`,
    wrappers, zsh precommands, csh / fish, `eval`, `trap`, `env -S`, herestrings), a refusal covers the
    word and the command that hands words to a shell when the lexer cannot finish them (TestC2:
    `bash -c 'git '"${x:-'push'}"`), and `-c` payloads read their operands as `$0` `$1` `$@` (TestC3);
  * the scanner is bounded (step / code-count / depth caps fail CLOSED) and is fast on 400 KB of
    nested padding and on 5 MB of every padding shape;
  * spelled git is read at every word (TestD1), data piped to a shell is read (TestD2), fish's
    `--command` is a payload (TestD3);
  * real segments are yielded first and unchanged (additive).
  * Unit B-iv (security round 2 + re-review): positional operands substituted raw and decoded
    (S-H1), `{fd}>` before the operand (S-H2), any pipe after an unresolved construct (S-H3), zsh
    `=git`, `/dev/stdin` scripts, `source`, `<( .. )` as script / stdin, a heredoc whose shell is on
    a later line of a continuing pipeline (R-F1), a path-qualified git whose span main splits
    differently (R-F2), `eval` read both ways (R-L1), more stdin wrappers (R-L3).
  * Unit B-v (security round 3): a newline in a positional operand is a word separator (H1), zsh's
    `=bash` (M), stdin paths with extra slashes / zeros, `eval` as a stdin wrapper.

CI: the oracle runs real shells, so it is built for ubuntu-latest (bash 5, no zsh, no Homebrew bash):
a repro that needs a particular shell says so (`only=`) and is SKIPPED where it is absent, a `sudo` form
is guard-only (never run), and the oracle's `git` is a stub under every letter-case spelling.

The verb is assembled (`G`) so no literal guarded command sits in this file. HOME is redirected
to a temp dir and `_record_hatch` is mocked, as in tests/test_cast_git_guard_perf.py. The
hyphenated module is loaded via importlib, same pattern as the other git-guard tests.
"""
import importlib.util
import itertools
import os
import random
import re
import shlex
import shutil
import signal
import sys
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
BOUND_SECS = 2.0       # CI runners are ~1.2x slower and the dev box load average is 20-30: never below 2 s
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
    """(d) Spelled git: case, ANSI-C / locale quotes, `$IFS` as the separator, quote-split words.
    `_normalize_git_segment` is main's (security M1: a rewrite of the REAL segment can forge a
    hatch), so every spelling is read by `_shell_payloads` and covered as an extra VIRTUAL segment."""

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

    def test_a_spelling_is_covered_by_a_virtual_segment_and_never_by_a_rewrite(self):
        # `_normalize_git_segment` is main's: it renders none of these. The spelling is read by
        # `_shell_payloads` and handed back as an EXTRA segment, canonical, after the real one.
        for spelled in ('GI' + 'T push', "$'" + G + "' push", '$"' + G + '" push', G + '${IFS}push',
                        G + '$IFS push', "$'\\x67it' push", "$'\\147it' push"):
            with self.subTest(spelled=spelled):
                self.assertIsNone(gg._normalize_git_segment(spelled))
                segs = [s for s in gg._executable_segments(spelled)]
                self.assertEqual(segs[0], spelled)              # the real segment, first, unchanged
                self.assertIn(G + ' push', segs[1:])            # the virtual one

    def test_a_non_git_command_is_still_not_normalised(self):
        for seg in ('rg "' + G + ' push" docs/', 'echo $IFS', 'mygit push', './' + G + 'x push', 'GITHUB push'):
            with self.subTest(seg=seg):
                self.assertIsNone(gg._normalize_git_segment(seg))

    def test_ifs_split_never_touches_the_assignment_prefix(self):
        # `CAST_PUSH_OK=1$IFS git push` assigns "1 \t\n" in real bash - it is NOT the hatch, and
        # the normaliser must not turn it into one (a rewrite may add a block, never remove one).
        self.assertBlocks('CAST_PUSH_OK=1$IFS ' + G + ' push origin main')
        self.assertBlocks('CAST_PUSH_OK=1${IFS} ' + G + ' push origin main')

    def test_a_hatch_never_passes_through_a_spelled_git(self):
        # BY DESIGN: a spelled `git` is read by the extractor, not by main's anchored patterns, and
        # the virtual segment it yields carries no assignment prefix. Honouring a hatch there would
        # mean honouring one that was FORGED with the same spelling (`=$'1'`), so none is honoured:
        # the plain `git push` after the hatch is the only spelling a hatch ever unlocks.
        self.assertBlocks('CAST_PUSH_OK=1 ' + G + '${IFS}push origin main')
        self.assertBlocks("CAST_PUSH_OK=1 $'" + G + "' push origin main")
        self.assertBlocks('CAST_PUSH_OK=1 GI' + 'T push origin main')
        self.assertAllows('CAST_PUSH_OK=1 ' + G + ' push origin main')
        self.assertAllows('CAST_PUSH_OK=1 /usr/bin/' + G + ' push origin main')


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
        self.assertLess(elapsed, BOUND_SECS)


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


class TestHatchValuesAreNotRewritten(_Base):
    """Security M1: a `$` in a hatch VALUE is not a hatch. `CAST_PUSH_OK='1$' git push` assigns
    the value `1$`, which is not `1`; on main it BLOCKs, and a normaliser that strips the `$` of
    `$'` / `$"` (or splits on `$IFS`) turned it into a well-formed hatch (ALLOW). The real segment
    must be normalised exactly as on main: new spellings are extra virtual segments, never a
    rewrite of the real one (a rewrite may add a block to an ALLOW hatch pattern's variants, but a
    variant that is NOT the raw text can also remove one - `hit()` ORs every variant)."""

    HATCHES = (('CAST_PUSH_OK', G + ' push origin main'),
               ('CAST_COMMIT_AGENT', G + ' commit -m x'),
               ('CAST_RESET_OK', G + ' reset --hard'))

    def test_a_dollar_in_the_hatch_value_still_blocks(self):
        for var, verb in self.HATCHES:
            for value in ("'1$'", '1"$"', "$'$'1", "1$''", '"1$"', "1\\$", "'1'$''"):
                cmd = f'{var}={value} {verb}'
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_the_forged_value_is_not_normalised_into_a_hatch(self):
        # The engine-level statement of the same thing: no variant of the real segment (`hit()`
        # ORs the raw text and the normal form) is accepted by an ALLOW hatch pattern.
        for var, verb in self.HATCHES:
            for value in ("'1$'", '1"$"', "$'$'1"):
                seg = f'{var}={value} {verb}'
                norm = gg._normalize_git_segment(seg)
                with self.subTest(seg=seg):
                    for pat in (gg._PUSH_ALLOW, gg._RESET_ALLOW, gg._COMMIT_ALLOW):
                        self.assertIsNone(pat.search(seg), seg)
                        self.assertIsNone(pat.search(norm or ''), norm)

    def test_legitimate_hatches_still_allow(self):
        self.assertAllows('CAST_PUSH_OK=1 ' + G + ' push origin main')
        self.assertAllows('CAST_PUSH_OK=1 /usr/bin/' + G + ' push origin main')
        self.assertAllows('CAST_COMMIT_AGENT=1 ' + G + ' commit -m x')
        self.assertAllows('CAST_RESET_OK=1 ' + G + ' reset --hard')
        self.assertAllows('CAST_PUSH_OK=1 FOO="a b" ' + G + ' push origin main')


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
        # A payload is looked for at ANY word (C1), so a shell word with `-c` behind a command that
        # is not a wrapper is a code string too: it only ever ADDS a segment to evaluate, and the
        # guard judges it like any other (`rg bash -c x` hands `x` to the evaluator, which allows it).
        self.assertEqual(c("rg bash -c 'x'"), ['x'])
        self.assertEqual(c("echo bash -c 'x'"), ['x'])
        self.assertEqual(c("echo bash -c"), [])

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
        self.assertEqual(c("bash <<< 'x'; bash -c y"), ['x', 'y'])      # a herestring to a shell IS a command (C1)
        self.assertEqual(c("cat <<< 'x'; bash -c y"), ['y'])
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
                           side_effect=lambda w, *a: calls.append([(str(x), x.redir) for x in w]) or ([], False)):
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

    # Code-review High: git BEFORE the unresolved construct, in the same word or the same simple
    # command, was neither extracted nor counted by the refusal (which only looked from the
    # construct on). Each of these runs git in real bash 3.2 / bash 5 / zsh (`$[1]` is 1).
    GIT_BEFORE = (
        "bash -c '" + G + " push --force '$[1]",
        "eval '" + G + " push --force '$[1]",
        'bash -c "' + G + ' push --force "$[1]',
        "bash -c '" + G + " push --force '\"${x:-'y'}\"",
        "bash -c '" + G + " push --force '${x:-$[1]}",
        'bash -c ' + G + "' push --force '$[1]",
        "bash -c '" + G + " push'<<$x",
        "bash -c $'" + G + " push --force '$[1]",
        "bash -c '" + G + " push' $[1]",                    # blocked before the fix too: keep it
        "bash -c '" + G + " push --force '$(echo $[1])",
        "sh -c \"" + G + " push --force \"`echo $[1]`",
        "FOO=1 sudo -u root bash -lc '" + G + " push --force '$[1]",
        "time eval '" + G + " push --force '\"${x:-'y'}\"",
        "echo ok; bash -c '" + G + " push --force '$[1]",
        "bash -c '" + G + " push --force '$[1]; echo after",
    )

    def test_git_before_the_construct_same_word_same_command_blocks(self):
        for cmd in self.GIT_BEFORE:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_git_before_the_construct_blocks_inside_a_substitution_too(self):
        for cmd in self.GIT_BEFORE:
            for wrapped in ('echo $(' + cmd + ')', 'echo $(' + cmd + '\n)', 'echo `' + cmd.replace('`', '') + '`',
                            'echo "$(' + cmd + '\n)"', '(' + cmd + '\n)'):
                with self.subTest(wrapped=wrapped):
                    self.assertBlocks(wrapped)

    def test_the_nested_level_has_its_own_word_and_command_state(self):
        # The substitution body is scanned as a command of its own one level down (where the
        # unresolved construct is met again), and so is the payload of a `bash -c`.
        for inner in self.GIT_BEFORE[:9]:
            for wrapped in ('bash -c ' + shlex.quote(inner), 'eval ' + shlex.quote(inner),
                            'bash -c ' + shlex.quote('bash -c ' + shlex.quote(inner))):
                with self.subTest(wrapped=wrapped):
                    self.assertBlocks(wrapped)

    # zsh reads `(x))` as the group pattern `(x)` and the `)` that ends it; bash (a syntax error
    # there) and the lexer's bash model read a pattern `x` and a stray `)`, which closes the
    # enclosing `$(` EARLY - and the rest of the case body then lands as arguments of the command
    # around the substitution (`echo $(...) bash -c "git push"`), where nothing extracts it.
    ZSH_CASE = (
        'echo $(case "x" in (x)) bash -c "' + G + ' push" ;; esac)',
        'echo $(case "x" in (x))bash -c "' + G + ' push";; esac)',
        'echo $(case x in (x))\n bash -c "' + G + ' push"\n ;; esac)',
        'echo $(case x in (a|x)) bash -c \'' + G + ' push\' ;; esac)',
        'echo $(case x in (a) echo ok ;; (x)) bash -c "' + G + ' push" ;; esac)',
        'echo "$(case x in (x)) bash -c \\"' + G + ' push\\" ;; esac)"',
        'case "x" in (x)) bash -c "' + G + ' push" ;; esac',
    )

    def test_a_close_paren_right_after_a_case_pattern_is_uncertain(self):
        for cmd in self.ZSH_CASE:
            with self.subTest(cmd=cmd):
                with self.assertRaises(gg._LexUncertain):
                    _code(cmd)
                segs = list(gg._executable_segments(cmd))
                self.assertIsInstance(segs[-1], gg._Refusal)
                self.assertEqual(segs[-1].msg, gg._LEX_UNCERTAIN_MSG)
                self.assertBlocks(cmd)

    def test_the_case_forms_both_shells_agree_on_are_still_modelled(self):
        for cmd in ('echo $(case x in (x) bash -c "' + G + ' push" ;; esac)',
                    'echo $(case x in x) bash -c "' + G + ' push" ;; esac)',
                    'echo $(case x in a) echo ok ;; b) bash -c "' + G + ' push" ;; esac)',
                    'echo $(case x in a) (echo ok) ;; esac) ; bash -c "' + G + ' push"'):
            with self.subTest(cmd=cmd):
                _code(cmd)                      # models it: no _LexUncertain
                self.assertBlocks(cmd)          # ... and so it finds the git inside
                self.assertFalse(any(isinstance(s, gg._Refusal) for s in gg._executable_segments(cmd)), cmd)
        # Without a git mention after it the same input is not refused (nothing there can run git).
        self.assertEqual(_code('echo $(case x in (x)) echo ok ;; esac)'), [])

    def test_the_partial_command_is_extracted_not_blanket_refused(self):
        # Only a command that can hand the git text to a shell is refused: a git command (or
        # anything else) merely followed by an unresolved construct is the real segment's business.
        self.assertEqual(_code("bash -c 'x '$[1]"), ['x '])                  # B-i's flush: the partial payload
        # ... but with git anywhere in a payload-producing command the refusal starts at the command (C2)
        with self.assertRaises(gg._LexUncertain):
            _code("bash -c '" + G + " push --force '$[1]")
        # (`echo <git>` is a plain git that is not main's: its own virtual segment `<git> ''` - the
        # cut-off word - is judged and allowed; no refusal)
        self.assertEqual([c for c in _code("echo " + G + " $[1]") if G + ' push' in c], [])
        self.assertAllows("echo " + G + " $[1]")
        self.assertEqual(_code(G + ' status "${x:-\'y\'}"'), [])
        # (A payload-producing command - `bash -c`, `eval` ... - followed by an unresolved construct
        # is refused from its start instead: TestC2RefusalCoversTheWordAndCommand.)
        for cmd in (G + ' status $[1]', 'echo ' + G + ' $[1]', G + " log --format='%h' \"${x:-'y'}\"",
                    'CAST_COMMIT_AGENT=1 ' + G + ' commit -m "fix ${x:-\'y\'}"'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)


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
        self.assertEqual(_code("bash <<< 'x'; bash -c y"), ['x', 'y'])     # ... to a shell: a command (C1)
        self.assertEqual(_code("cat <<< 'x'; bash -c y"), ['y'])
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

    def test_the_delimiter_is_found_by_comparing_lines_not_by_a_regex(self):
        # (L4) each of these has the delimiter text in a line that is NOT the delimiter line
        c = _code
        self.assertEqual(c("cat <<EOF\nxEOF\nEOFx\na EOF b\nEOF EOF\n$(x)\nEOF\nbash -c 'after'"), ['x', 'after'])
        self.assertEqual(c("cat <<-EOF\n\tEOF x\n  \tEOF\n$(x)\n\t\tEOF\nbash -c 'after'"), ['x', 'after'])
        self.assertEqual(c("cat <<'E'\nE E E E\nEE\n$(x)\nE\nbash -c 'after'"), ['after'])
        self.assertEqual(c("cat <<EOF\n$(x)\nEOF"), ['x'])                       # last line, no newline
        self.assertEqual(c("cat <<''\n$(x)\n\nbash -c 'after'"), ['after'])     # the empty delimiter
        self.assertEqual(c("cat <<-''\n$(x)\n\t\t\nbash -c 'after'"), ['after'])
        self.assertEqual(c('cat <<A <<A\n$(x)\nA\n$(y)\nA\nbash -c z'), ['x', 'y', 'z'])
        self.assertEqual(c('{ cat <<A; } ; cat <<A\n$(x)\nA\n$(y)\nA\nbash -c z'), ['x', 'y', 'z'])
        with self.assertRaises(gg._LexUncertain):                                  # never terminated
            c('cat <<EOF\nxEOF\nEOFx\n' + G + ' status')
        with self.assertRaises(gg._LexUncertain):
            c("cat <<-EOF\nEOF x\n" + G + ' status')

    def test_a_delimiter_holding_a_tab_is_uncertain(self):
        # Shells disagree on which `<<-` line ends such a heredoc (bash: the raw line, or the line
        # with its tabs stripped; zsh strips the delimiter too): refuse rather than guess.
        for cmd in ("cat <<-'\tEOF'\nx\n\tEOF\n" + P, "cat <<'\t'\nx\n\t\n" + P, "cat <<-'E\tF'\nx\nE\tF\n" + P):
            with self.subTest(cmd=cmd):
                with self.assertRaises(gg._LexUncertain):
                    _code(cmd)
                self.assertBlocks(cmd)


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
                               side_effect=lambda w, *a: spans.extend((str(x), text[x.start:x.end]) for x in w) or ([], False)):
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
        self.assertLess(elapsed, BOUND_SECS)

    def test_a_huge_quoted_heredoc_next_to_one_git_mention_is_not_refused(self):
        body = ('lorem ipsum dolor sit amet, consectetur $x `y` adipiscing elit sed do eiusmod\n' * 22000)[:1_600_000]
        code, msg, elapsed = self.timed("cat > f <<'EOF'\n" + body + '\nEOF\n' + G + ' log')
        self.assertEqual((code, msg), (0, ''))
        self.assertLess(elapsed, BOUND_SECS)

    @staticmethod
    def _many_heredocs(n, shape='one-line', distinct=True):
        """`n` heredocs, each with its own delimiter (`distinct`) or all with the same one."""
        d = (lambda i: f'D{i}') if distinct else (lambda i: 'D')
        if shape == 'one-line':             # `cat <<'D0' <<'D1' ...`, then the bodies in order
            return ('cat ' + ' '.join(f"<<'{d(i)}'" for i in range(n)) + '\n'
                    + ''.join(f'{d(i)}\n' for i in range(n)) + G + ' log')
        return ''.join(f"cat <<'{d(i)}'\nbody {i}\n{d(i)}\n" for i in range(n)) + G + ' log'

    @staticmethod
    def _lex_seconds(cmd, runs=3):
        best = 1e9
        for _ in range(runs):
            t0 = time.perf_counter()
            gg._executed_code(cmd, [gg._MAX_EXEC_SCAN_STEPS, gg._MAX_EXEC_CODES])
            best = min(best, time.perf_counter() - t0)
        return best

    def test_many_distinct_heredoc_delimiters_are_cheap(self):
        # L4: a regex was compiled per distinct delimiter (the `re` cache holds 512): 40,000 of
        # them made the scan several times slower than the same heredocs with ONE delimiter.
        # The delimiter line is found by string search now. The lexing time is judged against the
        # same-shaped command with a single repeated delimiter (a ratio, so machine load cancels).
        distinct = self._lex_seconds(self._many_heredocs(40000))
        same = self._lex_seconds(self._many_heredocs(40000, distinct=False))
        self.assertLess(distinct, 2.0 * same + 0.05, f'distinct {distinct:.3f} s vs same {same:.3f} s')
        code, msg, elapsed = self.timed(self._many_heredocs(40000))
        self.assertEqual((code, msg), (0, ''))
        self.assertLess(elapsed, 2.0, f'{elapsed:.2f} s')

    def test_the_lexer_builds_no_regex_per_heredoc_delimiter(self):
        compiled = []
        real = gg.re.compile
        for shape in ('one-line', 'per-command'):
            cmd = self._many_heredocs(600, shape)
            with mock.patch.object(gg.re, 'compile', side_effect=lambda *a, **k: compiled.append(a) or real(*a, **k)):
                out = gg._executed_code(cmd, [gg._MAX_EXEC_SCAN_STEPS, gg._MAX_EXEC_CODES])
            self.assertEqual(out, [], shape)
        self.assertEqual(compiled, [])

    def test_lines_that_merely_contain_the_delimiter_are_charged_to_the_budget(self):
        # Every line that holds the delimiter text without being the delimiter line costs a step,
        # so a body made of them cannot be walked for free (steps: one per candidate line).
        body = 'EOF EOF\n' * 5000
        cmd = 'cat <<EOF\n' + body + 'EOF\n' + G + ' log'
        budget = [10 ** 9, 10 ** 9]
        gg._executed_code(cmd, budget)
        self.assertGreaterEqual(10 ** 9 - budget[0], 5000)
        with self.assertRaises(gg._ExecOverBudget):
            gg._executed_code(cmd, [2000, 10])
        self.assertEqual(self.verdict('cat <<EOF\n' + 'EOF EOF\n' * 5000 + 'EOF\n' + G + ' log'), (0, ''))
        with mock.patch.object(gg, '_MAX_EXEC_SCAN_STEPS', 2000):
            self.assertEqual(self.verdict(cmd)[0], 2)

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


def _quoted(verb):
    """The payload every B-ii-a repro hands to a nested shell: a quoted guarded git command."""
    return shlex.quote(G + ' ' + verb)


class TestC1PayloadsAtAnyWord(_Base):
    """C1: a `<shell> -c` / `eval` / `trap` / `env -S` / herestring payload is found at ANY word of
    a simple command - behind redirections, assignments, wrappers, zsh precommand modifiers, a
    variable that names the shell - not only behind a short list of known wrappers. `@P@` is the
    quoted guarded command."""

    REDIRECTIONS = (
        '>/dev/null bash -c @P@', '2>&1 bash -c @P@', '</dev/null bash -c @P@', 'A=1 >/dev/null bash -c @P@',
        'x+=1 bash -c @P@', 'x[0]=1 bash -c @P@', '{fd}>/dev/null bash -c @P@', 'bash >/dev/null -c @P@',
        'bash -c >/dev/null @P@', '&>/dev/null bash -c @P@', '>>/dev/null bash -c @P@',
        '2>/dev/null A=1 >/dev/null B=2 bash -c @P@', 'bash 2>&1 -c @P@', 'bash -c 2>&1 @P@',
    )
    VARIABLE_SHELLS = (
        '$SHELL -c @P@', '"$BASH" -c @P@', '${SHELL} -c @P@', '"${SHELL}" -c @P@', 'env $SHELL -c @P@',
        'sudo "$SHELL" -c @P@',
    )
    WRAPPERS = (
        'find . -exec bash -c @P@ \\;', 'xargs -I{} bash -c @P@', 'arch -arm64 bash -c @P@',
        'caffeinate bash -c @P@', 'script -q /dev/null bash -c @P@', 'find . -exec sh -c @P@ {} +',
        'watch -n1 bash -c @P@', 'ionice -c3 bash -c @P@', 'chronic bash -c @P@', 'stdbuf -oL bash -c @P@',
    )
    OTHER_SHELLS = (
        'csh -c @P@', 'tcsh -c @P@', 'fish -c @P@', 'mksh -c @P@', 'ksh93 -c @P@', 'bash5 -c @P@',
        '/opt/homebrew/bin/bash -c @P@', '/bin/CSH -c @P@', 'fish --no-config -c @P@',
    )
    ZSH_PRECOMMANDS = (
        'noglob bash -c @P@', 'nocorrect bash -c @P@', 'repeat 1 bash -c @P@', 'coproc bash -c @P@',
        'noglob nocorrect bash -c @P@', 'builtin command bash -c @P@',
    )
    COMPOUND = (
        'function f { bash -c @P@; }; f', 'f() { bash -c @P@; }; f', 'while true; do bash -c @P@; break; done',
        'for i in 1; do 2>&1 bash -c @P@; done', '{ bash -c @P@; }', 'if true; then >/dev/null bash -c @P@; fi',
    )
    EVALS = (
        '2>&1 eval @P@', 'A=1 eval @P@', 'noglob eval @P@', 'x=1 >/dev/null eval @P@', 'eval -- @P@',
        'xargs eval @P@',
    )

    def _each(self, templates):
        for verb in VERBS:
            q = _quoted(verb)
            for t in templates:
                with self.subTest(template=t, verb=verb):
                    self.assertBlocks(t.replace('@P@', q))

    def test_behind_redirections_and_assignments(self):
        self._each(self.REDIRECTIONS)

    def test_a_variable_that_names_the_shell(self):
        self._each(self.VARIABLE_SHELLS)

    def test_behind_wrappers_that_are_not_in_any_list(self):
        self._each(self.WRAPPERS)

    def test_other_shells(self):
        self._each(self.OTHER_SHELLS)

    def test_zsh_precommand_modifiers(self):
        self._each(self.ZSH_PRECOMMANDS)

    def test_inside_a_function_or_a_compound_command(self):
        self._each(self.COMPOUND)

    def test_eval_at_any_word(self):
        self._each(self.EVALS)

    def test_trap_action_at_any_word(self):
        for verb in VERBS:
            q = _quoted(verb)
            for cmd in ('trap ' + q + ' EXIT', 'trap ' + q + ' INT TERM', 'trap -- ' + q + ' EXIT',
                        'echo x; trap ' + q + ' EXIT', '2>&1 trap ' + q + ' EXIT', 'A=1 trap ' + q + ' ERR'):
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_env_dash_s_string_is_a_command(self):
        for verb in VERBS:
            cmd = G + ' ' + verb
            q = shlex.quote(cmd)
            qq = shlex.quote('bash -c ' + q)
            for wrapped in ('env -S ' + q, 'env -S' + q, 'env --split-string ' + q, 'env --split-string=' + q,
                            'env -S ' + qq, 'env -i -S ' + q, 'env FOO=1 -S ' + q, '/usr/bin/env -S ' + qq,
                            'sudo env -S ' + q, 'env -iS ' + q):
                with self.subTest(cmd=wrapped):
                    self.assertBlocks(wrapped)

    def test_herestring_to_a_shell_is_a_command(self):
        for verb in VERBS:
            q = _quoted(verb)
            for cmd in ('bash <<< ' + q, 'sh <<<' + q, 'bash -s <<< ' + q, '$SHELL <<< ' + q, '<<< ' + q + ' bash',
                        'zsh -l <<< ' + q, 'bash 0<<< ' + q, 'env bash <<< ' + q, 'cat x | bash <<< ' + q,
                        'bash <<< "' + G + ' ' + verb + '"'):
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_the_extractor_sees_each_payload(self):
        c = _code
        self.assertEqual(c('>/dev/null bash -c x'), ['x'])
        self.assertEqual(c('2>&1 bash -c x'), ['x'])
        self.assertEqual(c('x+=1 bash -c x'), ['x'])
        self.assertEqual(c('x[0]=1 bash -c x'), ['x'])
        self.assertEqual(c('{fd}>/dev/null bash -c x'), ['x'])
        self.assertEqual(c('bash >/dev/null -c x'), ['x'])
        self.assertEqual(c('$SHELL -c x'), ['x'])
        self.assertEqual(c('"${BASH}" -c x'), ['x'])
        self.assertEqual(c('find . -exec bash -c x \\;'), ['x'])
        self.assertEqual(c('find . -exec bash -c x \\; -exec sh -c y \\;'), ['x', 'y'])
        self.assertEqual(c('trap "a b" EXIT'), ['a b'])
        self.assertEqual(c('trap -- a EXIT'), ['a'])
        self.assertEqual(c('2>&1 eval a b'), ['a b'])
        self.assertEqual(c("env -S 'a b'"), ['a b'])
        self.assertEqual(c("env -Sx"), ['x'])
        self.assertEqual(c("env --split-string=a"), ['a'])
        self.assertEqual(c("bash <<< 'a b'"), ['a b'])
        self.assertEqual(c("echo x <<< 'a b'"), [])      # no shell word: the herestring is plain input

    def test_these_stay_allowed(self):
        for cmd in ("bash -c '" + G + " status'", 'bash scripts/x.sh -c cfg', 'ssh -c aes128-ctr host ls',
                    'echo bash -c', 'rg "bash -c" docs/', 'trap - EXIT', 'trap \'rm -f "$tmp"\' EXIT',
                    "echo bash -c '" + G + " status'", 'echo trap', G + ' status',
                    "echo $0; " + G + " log", G + ' log -c 3',
                    'A=/bin/bash echo -c \'x\'; ' + G + ' status', 'env -S'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_a_shell_word_alone_is_not_a_payload(self):
        for cmd in ('bash', 'bash -c', 'bash -o pipefail', 'bash scripts/x.sh', 'env', 'eval', 'trap', 'trap -p', 'x=1'):
            with self.subTest(cmd=cmd):
                self.assertEqual(_code(cmd + '; ' + G + ' status'), [])

    def test_a_padded_command_of_shell_words_is_bounded(self):
        # Each `$1` payload walks the operand list after it: charged to the step budget, so n
        # shell words cannot cost n x n - the command is refused (it mentions git) in bounded time.
        cmd = "bash -c '$1' " * 30000 + '; ' + G + ' status'    # the `;`: a git segment over the cap is refused before the lexer runs
        code, msg, elapsed = self.timed(cmd)
        self.assertEqual(code, 2)
        self.assertLess(elapsed, 2.0, f'{elapsed:.2f} s')
        cmd = 'eval ' * 100000 + '; ' + G + ' status'
        code, msg, elapsed = self.timed(cmd)
        self.assertLess(elapsed, 2.0, f'{elapsed:.2f} s')


class TestC2RefusalCoversTheWordAndCommand(_Base):
    """C2: inside double quotes `${x:-'push'}` keeps its quotes and SUPPLIES the verb (real bash 3.2,
    bash 5 and zsh all run `git push` for `bash -c 'git '"${x:-'push'}"`). The lexer is uncertain
    at that `'`, and what it extracted (`git `) has no verb: the refusal must start at the word
    being built or at the start of a command that hands its words to a shell, not at the construct."""

    @staticmethod
    def shapes(verb):
        s = "${x:-'" + verb + "'}"
        return (
            "bash -c '" + G + " '\"" + s + '"',
            'bash -c "' + G + ' ' + s + '"',
            "eval '" + G + " ' \"" + s + '"',
            "bash -c '" + G + " \"$0\"' \"" + s + '"',
            "bash -c '" + G + " '\"" + s + '" ; echo done',
            "env -S \"" + G + ' ' + s + '"',
            "bash <<< \"" + G + ' ' + s + '"',
            "trap \"" + G + ' ' + s + '" EXIT',
            "2>&1 sudo bash -c '" + G + " '\"" + s + '"',
            "find . -exec bash -c '" + G + " '\"" + s + '" \\;',
            "echo ok; $SHELL -c '" + G + " '\"" + s + '"',
        )

    def test_the_quoted_default_that_supplies_the_verb_blocks(self):
        for verb in ('push', 'commit', 'reset'):
            for cmd in self.shapes(verb):
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_the_same_shapes_inside_a_substitution_block(self):
        for cmd in self.shapes('push'):
            for wrapped in ('echo $(' + cmd + ')', 'echo $(' + cmd + '\n)', 'echo "$(' + cmd + '\n)"',
                            '(' + cmd + '\n)', 'echo `' + cmd.replace('`', '') + '`'):
                with self.subTest(wrapped=wrapped):
                    self.assertBlocks(wrapped)

    def test_the_same_shapes_one_payload_level_down_block(self):
        for cmd in self.shapes('push')[:4]:
            for wrapped in ('bash -c ' + shlex.quote(cmd), 'eval ' + shlex.quote(cmd),
                            'bash -c ' + shlex.quote('eval ' + shlex.quote(cmd))):
                with self.subTest(wrapped=wrapped):
                    self.assertBlocks(wrapped)

    def test_the_refusal_is_the_lexers_not_a_verdict_on_the_verb(self):
        for cmd in self.shapes('status'):
            with self.subTest(cmd=cmd):
                segs = list(gg._executable_segments(cmd))
                self.assertIsInstance(segs[-1], gg._Refusal)
                self.assertEqual(segs[-1].msg, gg._LEX_UNCERTAIN_MSG)

    def test_a_command_that_hands_nothing_to_a_shell_is_not_widened(self):
        # The refusal start moves back only for a payload-producing command: a plain git command
        # (or any other) followed by an unresolved construct is the real segment's business.
        for cmd in ('CAST_COMMIT_AGENT=1 ' + G + ' commit -m "fix ${x:-\'y\'}"', G + ' status $[1]',
                    G + ' log --format=%h "${x:-\'y\'}"', 'echo "${x:-\'y\'}"', 'echo x $[1]',
                    G + ' status; echo "${x:-\'y\'}"'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_an_earlier_complete_payload_command_is_not_the_current_command(self):
        # `bash -c 'x'` is finished when the unresolved construct starts a LATER command: the
        # refusal then starts at that command, as before (the git after it is what blocks).
        self.assertEqual(_code("bash -c 'x'; echo $[1]"), ['x'])
        self.assertAllows("bash -c 'x'; echo $[1]; echo done")
        self.assertBlocks("bash -c 'x'; echo $[1]; " + G + ' status')

    def test_a_git_free_payload_command_with_an_unresolved_construct_is_still_not_scanned(self):
        self.assertAllows("bash -c 'echo hi '\"${x:-'y'}\"")
        self.assertAllows("eval 'echo hi ' \"${x:-'y'}\"")

    def test_the_partial_payload_that_already_has_a_verb_is_refused_too(self):
        # `${x:-'push'}` may complete ANY git word, so even `git status ` + construct is refused
        # from the command start (it was an allow when only the construct onward was counted).
        self.assertBlocks("bash -c '" + G + " status '$[1]")
        self.assertBlocks("eval '" + G + " status '\"${x:-'y'}\"")


class TestC3PositionalParameters(_Base):
    """C3: the operands after a `-c` payload are `$0`, `$1` ...; `bash -c 'git $1' x push` runs
    `git push`. Both the raw payload and one with the operands substituted are code strings."""

    def test_positional_operands_complete_the_command(self):
        for cmd in ("bash -c '" + G + " $1' x push",
                    "sh -c '" + G + " \"$@\"' _ push",
                    "bash -c '" + G + " $*' x push origin main",
                    "bash -c '" + G + " ${1}' x push",
                    "bash -c '$0 push' " + G,
                    "bash -c '$0 $1 origin' " + G + ' push',
                    "bash -c '" + G + " $@' _ push origin main",
                    "bash -c '\"$@\"' _ " + G + ' push',
                    "bash -c '" + G + " \"$*\"' _ push",
                    "bash -c '" + G + " $1 $2' x reset --hard",
                    "bash -c '" + G + " ${2}' x ignored commit",
                    "bash -lc '" + G + " $1' x push",
                    "env bash -c '" + G + " $1' x push",
                    "find . -exec bash -c '" + G + " $1' x push \\;",
                    "bash -c '" + G + " $1' x \"push\"",
                    "bash -c '" + G + " $1' x 'push'",
                    "bash -c 'eval " + G + " $1' x push",
                    "bash -c \"bash -c '" + G + " \\$1' x push\" _"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_inside_a_substitution_and_a_payload(self):
        inner = "bash -c '" + G + " $1' x push"
        for cmd in ('echo $(' + inner + ')', '(' + inner + ')', 'eval ' + shlex.quote(inner),
                    'bash -c ' + shlex.quote(inner)):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_both_the_raw_and_the_substituted_payload_are_emitted(self):
        self.assertEqual(_code("bash -c 'git $1' x push"), ['git $1', 'git push'])
        self.assertEqual(_code("bash -c 'echo $0 $1' a b"), ['echo $0 $1', 'echo a b'])
        # quoted (one word per operand), then raw (the operand's own words: what `eval "$1"` runs)
        self.assertEqual(_code("sh -c 'x \"$@\"' _ a 'b c'"), ['x "$@"', "x a 'b c'", 'x a b c'])
        self.assertEqual(_code("sh -c 'x $*' _ a b"), ['x $*', 'x a b'])
        self.assertEqual(_code("bash -c 'x ${0} ${1} ${2}' a b"), ['x ${0} ${1} ${2}', 'x a b '])
        self.assertEqual(_code("bash -c 'echo $10' a b"), ['echo $10', 'echo b0'])
        # a placeholder with no operand behind it is empty, like an unset parameter
        self.assertEqual(_code("bash -c 'x $3' a"), ['x $3', 'x '])

    def test_nothing_is_substituted_without_operands_or_placeholders(self):
        self.assertEqual(_code("bash -c 'x $1'"), ['x $1'])
        self.assertEqual(_code("bash -c 'x y' a b"), ['x y'])
        self.assertEqual(_code("eval 'x $1' a"), ['x $1 a'])         # eval has no positional parameters
        self.assertEqual(_code("bash -c 'x $1' >/dev/null"), ['x $1'])      # a redirection is not an operand

    def test_these_stay_allowed(self):
        for cmd in ("bash -c '" + G + " $1' x status", "bash -c '" + G + " status' x push",
                    "bash -c 'echo $1' x " + G + ' status', "bash -c '" + G + " log $@' _ -3",
                    "bash -c '" + G + " status \"$@\"' _ push"):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_an_operand_that_ended_uncertain_is_refused(self):
        self.assertBlocks("bash -c '" + G + " \"$0\"' \"${x:-'push'}\"")
        self.assertBlocks("bash -c '" + G + " $1' x $[1]")

    def test_a_huge_expansion_is_refused_not_built(self):
        cmd = G + " status; bash -c '" + '$@' * 100000 + "' _ " + ' '.join(['x' * 100] * 10)
        code, msg, elapsed = self.timed(cmd)
        self.assertEqual(code, 2)
        self.assertLess(elapsed, 2.0, f'{elapsed:.2f} s')


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


def _g(template):
    return template.replace('@G@', G)


class TestD1SpelledGitAtEveryWord(_Base):
    """A word whose shell reading is `git` - whatever its spelling, wherever it sits in a simple
    command - is judged as the plain `git` it runs as: `_shell_payloads` hands back the code string
    `git <rest of the command>` and the per-segment engine does the rest. No new detection ever
    removes a block: it is an extra virtual segment."""

    SPELLED = (
        'GIT @V@', "$'@G@' @V@", '$"@G@" @V@', "g''it @V@", '\\@G@ @V@', '@G@${IFS}@V@', '@G@$IFS @V@',
        "$'\\x67it' @V@", "$'\\147it' @V@", '/usr/bin/GIT @V@',
    )
    CONTEXTS = (
        '@S@', 'command @S@', '{ @S@; }', 'if @S@; then :; fi', 'env A=1 @S@', 'nohup @S@', 'time @S@',
        '! @S@', 'xargs @S@', 'f() { @S@; }', 'case x in x) @S@;; esac', 'CAST_PUSH_OK=1 @S@',
        'sudo -u root @S@', 'FOO=1 BAR=2 @S@', 'while @S@; do :; done', '>/dev/null @S@', '@S@ 2>&1',
    )

    @classmethod
    def _cmds(cls, ctx, spelled, verb):
        return _g(ctx.replace('@S@', spelled.replace('@V@', verb)))

    def test_every_spelling_blocks_in_every_context(self):
        for spelled in self.SPELLED:
            for ctx in self.CONTEXTS:
                for verb in VERBS:
                    cmd = self._cmds(ctx, spelled, verb)
                    with self.subTest(cmd=cmd):
                        self.assertBlocks(cmd)

    def test_every_spelling_blocks_inside_bash_c_and_a_substitution(self):
        n = 0
        for spelled in self.SPELLED:
            for ctx in self.CONTEXTS:
                verb = VERBS[n % len(VERBS)]
                n += 1
                inner = self._cmds(ctx, spelled, verb)
                for wrapped in ('bash -c ' + shlex.quote(inner), '$(' + inner + ')', 'echo `' + inner + '`'):
                    with self.subTest(cmd=wrapped):
                        self.assertBlocks(wrapped)

    def test_an_exec_path_to_git_blocks_where_main_only_looked_at_the_first_word(self):
        for verb in VERBS:
            for prefix in ('exec ', 'sudo ', 'env A=1 ', 'nohup ', 'command ', 'xargs ', 'time '):
                cmd = prefix + '/usr/bin/' + G + ' ' + verb
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_a_hatch_is_not_honoured_through_a_spelling(self):
        for cmd in ('CAST_PUSH_OK=1 GI' + 'T push', 'CAST_PUSH_OK=1 $\'' + G + '\' push origin main',
                    'CAST_PUSH_OK=$\'1\' GI' + 'T push origin main', 'CAST_PUSH_OK=1 ' + G + '${IFS}push',
                    'CAST_COMMIT_AGENT=1 GI' + 'T commit -m x', 'CAST_RESET_OK=1 GI' + 'T reset --hard'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_the_plain_hatches_still_work(self):
        for cmd in ('CAST_PUSH_OK=1 ' + G + ' push origin main',
                    'CAST_PUSH_OK=1 /usr/bin/' + G + ' push origin main',
                    'CAST_COMMIT_AGENT=1 ' + G + ' commit -F f',
                    'CAST_PUSH_OK=1 ' + G + ' push origin main && ' + G + ' status'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    ALLOW = (
        'rg "@G@ push" docs/', 'gh pr create --body "@G@ push guard added"', 'echo "GIT is fine"',
        '@G@ status', 'command @G@ status', 'GIT status', 'GIT', '"@G@"', 'echo GIT',
        "echo '$\"@G@\" push'", 'echo "$\'@G@\'" push', 'echo "@G@$IFS push"', 'ls GIT*',
        '$(echo @G@) status', 'sudo ls @G@', 'echo $\'@G@\'',
        'CAST_PUSH_OK=1 @G@ push origin main', 'CAST_PUSH_OK=1 /usr/bin/@G@ push origin main',
        'CAST_COMMIT_AGENT=1 @G@ commit -F f', 'bash -c "$\'@G@\' status"', '/usr/bin/GIT --version',
        '$"@G@" log --oneline | head',
    )

    def test_data_and_unguarded_verbs_still_allow(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_virtual_segment_is_the_plain_command_with_the_words_after_it(self):
        cases = (
            ('GIT push origin main', G + ' push origin main'),
            ("$'" + G + "' commit -m 'a b'", G + " commit -m 'a b'"),
            (G + '${IFS}push${IFS}origin main', G + ' push origin main'),
            ('FOO=1 GIT reset --hard', G + ' reset --hard'),                 # assignments are not carried
            ('xargs -n1 $"' + G + '" push', G + ' push'),
            ('exec /usr/bin/' + G + ' -C /tmp push', G + ' -C /tmp push'),
            ('GIT push >/dev/null', G + ' push'),                              # redirections are not words
        )
        for text, want in cases:
            with self.subTest(text=text):
                self.assertIn(want, _code(text))

    def test_a_quoted_git_followed_by_a_verb_is_an_accepted_false_positive(self):
        # Every word is read, so a data argument that SPELLS `git` and is followed by a guarded
        # verb is taken for the command (main allowed these; they have no use outside a guard test).
        self.assertBlocks("echo '" + G + "' push")
        self.assertBlocks('echo "' + G + '" commit -m x')

    def test_an_operand_written_with_ansi_c_escapes_is_read_as_the_shell_reads_it(self):
        # `bash -c $'git\x20push'` runs `git push`: the lexer holds `git\x20push`.
        for cmd in ("bash -c $'" + G + "\\x20push origin main'", "eval $'" + G + "\\x20push'",
                    "bash -c $'" + G + "\\x20commit\\x20-m\\x20x'", "sh -c $'\\x67it push'",
                    "trap $'" + G + "\\x20push' EXIT", "env -S $'" + G + "\\x20push'",
                    "bash <<< $'" + G + "\\x20push'", "fish --command=$'" + G + "\\x20push'"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)
        self.assertAllows("echo $'" + G + "\\x20push'")                 # an argument stays data
        self.assertAllows("bash -c $'" + G + "\\x20status'")

    def test_a_word_the_shell_cannot_be_read_without_running_is_a_residual_not_a_guess(self):
        for text in ('$(echo ' + G + ') push', '`echo ' + G + '` push', '$X push', G + '$x push', 'g${x}it push',
                     '"$G" push', 'GI$(true)T push'):
            with self.subTest(text=text):
                self.assertEqual([c for c in _code(text) if c.startswith(G + ' ')], [])

    def test_ansi_c_decoding_matches_bash(self):
        # Expected values read back from /opt/homebrew/bin/bash 5 (`printf %s $'...' | od`).
        for body, want in (
                (r'\a', '\a'), (r'\b', '\b'), (r'\e', '\x1b'), (r'\E', '\x1b'), (r'\f', '\f'), (r'\n', '\n'),
                (r'\r', '\r'), (r'\t', '\t'), (r'\v', '\v'), ('\\\\', '\\'), (r"\'", "'"), (r'\"', '"'),
                (r'\?', '?'), (r'\147', 'g'), (r'\x67', 'g'), (r'g', 'g'), (r'\U00000067', 'g'),
                (r'\u67', 'g'), (r'\cA', '\x01'), (r'\c?', '\x7f'), (r'\q', '\\q'), (r'\x', '\\x'),
                (r'\x6g', '\x06g'), (r'\1470', 'g0'), (r'a\0b', 'a'), (r'\x41\x42', 'AB'), (r'\8', '\\8'),
                ('a\\\\x67b', 'a\\x67b'), ('plain', 'plain'), ('', '')):
            with self.subTest(body=body):
                self.assertEqual(gg._ansi_c(body), want)

    def test_a_surrogate_or_out_of_range_escape_never_raises(self):
        for body in (r'\ud800', r'\udfff', r'\U00110000', r'\UFFFFFFFF', r'\U0010FFFF'):
            with self.subTest(body=body):
                gg._ansi_c(body)
                self.assertAllows("echo $'" + body + "'")

    def test_word_view_reads_what_the_shell_reads(self):
        for raw, want in (
                (G, [G]), ("$'" + G + "'", [G]), ('$"' + G + '"', [G]), ("g''it", [G]), ('\\' + G, [G]),
                ('"' + G + '"', [G]), ("'" + G + "'", [G]), (G + '${IFS}push', [G, 'push']),
                (G + '$IFS', [G]), ('${IFS}' + G, [G]), ('a${IFS}${IFS}b', ['a', 'b']),
                ("$'\\x67it'", [G]), ("$'\\147it'", [G]), ('/usr/bin/GIT', ['/usr/bin/GIT']),
                ('"a\\"b"', ['a"b']), ('"a\\b"', ['a\\b']), ('"$"', ['$']), ("a\\\nb", ['ab']),
                ('"' + G + '$IFS"', None), (G + '$x', None), (G + '$(x)', None), ('`x`' + G, None),
                (G + '${x:-y}', None), ('"' + G, None), ("'" + G, None), ("$'" + G, None)):
            with self.subTest(raw=raw):
                self.assertEqual(gg._word_view(raw), want)

    def test_a_big_word_or_many_quoted_gits_are_bounded_and_block(self):
        n = 200_000
        for name, cmd in (
                ('quoted gits', ('"' + G + '" ') * (n // 6) + '; ' + G + ' push origin main'),
                ('one huge word', "'" + 'x' * n + "'" + G + ' push origin main'),
                ('huge spelled word', "$'" + G + "'${IFS}" + 'x' * n),
                ('ansi padding', ("$'\\x41' " * (n // 8)) + G + ' push origin main')):
            with self.subTest(shape=name):
                code, msg, elapsed = self.timed(cmd)
                self.assertEqual(code, 2, name)
                self.assertLess(elapsed, BOUND_SECS, f'{name}: {elapsed:.2f} s')

    def test_a_git_free_command_with_ansi_escapes_is_not_scanned(self):
        # `$'\x41'` decodes to no letter of `git`: no mention, so no lexer pass over a big heredoc.
        code, msg, elapsed = self.timed("printf '%s' $'\\x41\\n'; cat > f <<'EOF'\n" + 'x' * 1_000_000 + '\nEOF')
        self.assertEqual((code, msg), (0, ''))
        self.assertLess(elapsed, BOUND_SECS)


class TestD2PipeToShell(_Base):
    """A shell that reads its stdin runs what the stages before it write: `echo 'git push' | bash`.
    The data is each argument of every earlier stage (and all of them joined); the shell is a
    stdin reader when it has no `-c` and no script operand (`-s` and `-` aside)."""

    BLOCK = (
        "echo '@G@ push' | bash", "printf '@G@ push\\n' | sh", "echo '@G@ push' | $SHELL",
        "cat <<'EOF' | bash\n@G@ push origin main\nEOF", 'echo @G@ push | bash -s', "echo '@G@ push' | bash -s x",
        "echo '@G@ push' | bash -", "echo '@G@ push' | sudo bash", "echo '@G@ push' | env bash",
        "echo '@G@ commit -m x' | zsh", "echo '@G@ reset --hard' | dash -e", "echo '@G@ push' |& bash",
        "cat <<< '@G@ push' | bash", "echo '@G@ push' | cat | bash", "echo '@G@ push' | tee /dev/null | sh",
        "echo '@G@ push' | sed s/x/y/ | tr a b | sh", "echo '@G@ push' | { bash; }", "echo '@G@ push' | time bash",
        "echo '@G@ push' | /bin/bash", "echo '@G@ push' | BASH", "FOO=1 echo '@G@ push' | sh",
        "echo 'ls; @G@ push' | bash", "printf 'ls\\n@G@ push\\n' | bash", "echo \"@G@ push\" | bash -l",
        "echo 'GIT push' | bash", "echo \"$'@G@' push\" | sh", "echo '@G@${IFS}push' | sh",
        "echo x | cat; echo '@G@ push' | bash", "echo '@G@ push' | sh -o pipefail", "echo '@G@ push' | sh -x",
        "bash -c \"echo '@G@ push' | sh\"", "echo $(echo '@G@ push' | sh)", "echo '@G@ push' | fish",
        "echo '@G@ push' | ksh93", "echo '@G@ push' | exec bash",
    )
    ALLOW = (
        'cat script.sh | bash', "echo '@G@ status' | bash", '@G@ log | head', "echo '@G@ push' | bash script.sh",
        "echo '@G@ push' | bash -c 'cat'", "echo '@G@ push' | ssh host", "echo '@G@ push' | grep push",
        "echo '@G@ push' | xargs echo publish", '@G@ log --oneline | grep -c fix | sh', "echo hi | bash",
        '@G@ show HEAD:build.sh | bash', "echo '@G@ push'; bash", "echo '@G@ push' > f; cat f | wc -l",
        "echo '@G@ push' | tee log", "bash < script.sh", "echo ok | sh -c 'cat >/dev/null'",
        "echo '@G@ push' || bash", "echo '@G@ push' && bash",
    )

    def test_data_piped_to_a_shell_that_reads_stdin_blocks(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_everything_else_allows(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_an_unresolved_construct_before_a_pipe_to_a_shell_is_refused(self):
        # The scan cannot finish the first stage, so it cannot say what the `| sh` is fed.
        for cmd in ("echo '@G@ push' $[1] | bash", "echo '@G@ push' $[1] | tee f | sudo sh",
                    "echo '@G@ push' $[1] | $SHELL"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))
        # Any later pipe extends the refusal (`_PIPE_SINK` is a plain `|`: a shell NAME after the pipe
        # can be spelled with quotes, so it is not looked for). The cost is a false positive when the
        # pipe goes to something harmless - accepted, and listed in the module's RESIDUALS.
        self.assertBlocks(_g("echo '@G@ push' $[1] | grep push"))
        # No unresolved construct (the `$[1]` is quoted data): nothing is refused
        self.assertAllows(_g("@G@ diff | grep 'a$[1]' | head -20"))

    def test_the_payloads_are_each_argument_and_the_joined_words(self):
        # the arguments, and them joined; the echo stage's own plain git (not main's: it is not the
        # first word) is the virtual segment `<git> push`, the same string
        self.assertEqual(sorted(set(c for c in _code('echo ' + G + ' push | bash -s') if G in c)),
                         sorted([G, G + ' push']))
        self.assertIn(G + ' push\n', _code("printf '" + G + " push\\n' | sh"))
        self.assertEqual(_code(G + ' log | head'), [])

    def test_a_long_pipeline_of_shells_is_bounded_and_fails_closed(self):
        cmd = "echo '" + G + " status' | " + ' | '.join(['bash'] * 20000)
        code, msg, elapsed = self.timed(cmd)
        self.assertEqual(code, 2)
        self.assertLess(elapsed, BOUND_SECS)
        # 40k stages and no shell: main takes longer than the 2 s bound on this shape (every stage is
        # a segment of its own), so only `timed`'s 4 s tripwire applies; the point is that the
        # argument list a pipeline collects costs nothing without a shell, and the verdict stands.
        # (Each `echo <git>` is a plain git that is not main's: ONE virtual segment, identical
        # strings deduplicated - and it counts toward main's own 400,000-character work cap, which
        # 50k of these stages sat on the edge of.)
        code, msg, elapsed = self.timed(' | '.join(['echo ' + G] * 40000) + ' | cat')
        self.assertEqual((code, msg), (0, ''))


class TestD3FishCommand(_Base):
    """fish's `-c` has the long form `--command` (`--command=STR` or `--command STR`, and any unique
    abbreviation getopt takes): it is a payload at any word that names a shell."""

    def test_the_long_option_is_a_payload(self):
        for cmd in ("fish --command='@G@ push'", "fish --command '@G@ push'", "fish --comm='@G@ push'",
                    "fish --c '@G@ push origin main'", "/usr/bin/fish --command='@G@ commit -m x'",
                    "env fish --command '@G@ reset --hard'", "sudo fish --command='@G@ push'",
                    "fish --no-config --command='@G@ push'", "fish -c '@G@ push'", "fish -ic '@G@ push'",
                    "fish --command=\"$'@G@' push\"", "fish --command='GIT push'"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_it_does_not_block_what_is_not_git(self):
        for cmd in ("fish --command='@G@ status'", "fish --command='echo hi'", "fish --command 'ls'",
                    "fish --no-config", "fish --command", "fish --command=", "fish --commandX='@G@ push'",
                    "fish --login script.fish"):
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_payload_is_the_command_string(self):
        self.assertIn(G + ' push', _code("fish --command='" + G + " push'"))
        self.assertIn(G + ' push', _code("fish --command '" + G + " push'"))


# ---------------------------------------------------------------------------------------------
# Unit B-iii: the code-review findings on Unit B (H1, H2, M1 .. M5, LOW). Every BLOCK below was
# confirmed with a real shell (`_Oracle`): the stub `git` it runs logs its argv, and `push` ran.
# ---------------------------------------------------------------------------------------------
_ORACLE_SHELLS = tuple((path, flags) for path, flags in (
    ('/bin/bash', ('--norc', '--noprofile', '-c')), ('/opt/homebrew/bin/bash', ('--norc', '--noprofile', '-c')),
    ('/bin/zsh', ('-f', '-c'))) if os.path.exists(path))


def _shell_version(path):
    """The major version of the oracle shell at `path` (`BASH_VERSINFO[0]`; 99 for zsh), else 0."""
    import subprocess
    probe = 'echo ${BASH_VERSINFO[0]:-${ZSH_VERSION:+99}}'
    # no startup files: a bare `zsh -c` sources the real `~/.zshenv` (and bash may read `BASH_ENV`)
    flags = ('-f', '-c') if path.endswith('zsh') else ('--norc', '--noprofile', '-c')
    try:
        out = subprocess.run([path, *flags, probe], capture_output=True, text=True, timeout=10,
                             stdin=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin'}).stdout.strip()
        return int(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0


# Which shells read what. CI (ubuntu-latest) has /bin/bash 5, no zsh and no Homebrew bash, so a test
# that needs a particular shell says so (`_Oracle.ran(only=...)`) and is SKIPPED where it is absent;
# a test that merely needs "some shell ran it" runs on whatever is installed.
_ZSH_SHELLS = tuple(s for s in _ORACLE_SHELLS if s[0].endswith('zsh'))
# bash 3.2 (macOS /bin/bash) and zsh read `$'\c\\'` as `\c` + ONE character; bash 5 reads two backslashes.
_LEGACY_ANSI_SHELLS = tuple(s for s in _ORACLE_SHELLS if _shell_version(s[0]) in (3, 99))
# A test that spells `bash` inside the command runs whichever bash is first on the oracle's PATH.
_PATH_BASH_IS_LEGACY = os.path.exists('/bin/bash') and _shell_version('/bin/bash') == 3
_SUDO_WORD = re.compile(r'(?<![\w.-])(?:sudo|doas)(?![\w.-])')
_GIT_CASES = sorted({''.join(c) for c in itertools.product(*((ch, ch.upper()) for ch in 'git'))})


class _Oracle(_Base):
    """`_Base` plus a real-shell oracle: `ran(cmd)` runs `cmd` in every shell found with `git`
    shimmed to a stub that logs its argv (never the real git), and says whether `push` ran.

    The stub exists under every upper/lower-case spelling of `git` (a case-sensitive file system
    has no `GIT`), a path-qualified `/usr/bin/git` is pointed at it, `sh` is a bash (ubuntu's is
    dash), and GIT_DIR / GIT_CEILING_DIRECTORIES make a real git that slipped through fail."""

    def setUp(self):
        super().setUp()
        self.shim = tempfile.mkdtemp(prefix='cast-gitspell-shim-')
        self.addCleanup(shutil.rmtree, self.shim, True)
        stub = os.path.join(self.shim, G)
        with open(stub, 'w') as f:
            f.write('#!/bin/sh\nprintf "ran %s\\n" "$*" >> "$GITLOG"\n')
        os.chmod(stub, 0o755)
        for case in _GIT_CASES:
            if not os.path.lexists(os.path.join(self.shim, case)):
                os.link(stub, os.path.join(self.shim, case))
        bash = next((p for p, _ in _ORACLE_SHELLS if not p.endswith('zsh')), None)
        if bash is not None:
            os.symlink(bash, os.path.join(self.shim, 'sh'))

    def ran(self, cmd, only=None, verb='push'):
        """True when some oracle shell ran the stub with `verb`; None when no shell is installed or
        the command needs `sudo` (never run: GitHub's sudo is passwordless and resets PATH, macOS's
        prompts). `only`: the shells the repro needs - skips the test when none is installed."""
        import subprocess
        shells = _ORACLE_SHELLS if only is None else only
        if only is not None and not shells:
            self.skipTest('this repro needs a shell that is not installed here')
        if not shells or _SUDO_WORD.search(cmd) is not None:
            return None
        cmd = re.sub(r'/usr/bin/(?=[gG][iI][tT]\b)', self.shim + '/', cmd)
        hit = False
        for k, (path, flags) in enumerate(shells):
            log = os.path.join(self.shim, 'log.%d' % k)
            env = {'PATH': self.shim + ':/usr/bin:/bin', 'GITLOG': log, 'HOME': self.shim, 'SHELL': path,
                   'GIT_DIR': os.path.join(self.shim, 'no-such.git'),
                   'GIT_CEILING_DIRECTORIES': os.path.dirname(self.shim), 'GIT_CONFIG_NOSYSTEM': '1'}
            proc = subprocess.Popen([path, *flags, cmd], cwd=self.shim, env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            finally:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)         # nothing the shell left behind survives
                except OSError:
                    pass
            if os.path.exists(log):
                with open(log) as f:
                    hit = hit or ('ran ' + verb) in f.read()
        return hit

    def assertRunsAndBlocks(self, cmd, only=None, verb='push'):
        ran = self.ran(cmd, only, verb)
        if ran is not None:
            self.assertTrue(ran, f'no shell ran the stub with `{verb}` - not a repro: {cmd!r}')
        self.assertBlocks(cmd)


class TestReviewH1SpelledArgumentsAndHeredocs(_Oracle):
    """H1: a spelled verb / argument after a plain `git`, and spelled git in a heredoc body fed to
    a shell, ran git while only Unit A's wider net saw them."""

    SPELLED_ARGS = (
        '@G@ $IFS push', '@G@ ${IFS}push', "@G@ $'push'", '@G@ $"push"', "@G@ p$'u'sh", "@G@ -C . $'push'",
        "GIT_DIR=. @G@ $'push'", "@G@ ${IFS} push", "@G@ -c x=y $'push'", "@G@ $'p\\x75sh'",
    )
    HEREDOCS = (
        "bash <<'EOF'\nGIT push\nEOF", "cat <<'EOF' | bash\n$'@G@' push\nEOF", "bash <<EOF\n@G@${IFS}push\nEOF",
        "sh <<'EOF'\n@G@ ${IFS}push\nEOF", "bash -s <<'EOF'\nGIT push\nEOF", "cat <<EOF | sh\nGIT push\nEOF",
        "cat <<'EOF' | tee f | bash\nGIT push\nEOF", "bash <<'EOF'\nls\nGIT push origin main\nEOF",
        "bash - <<'EOF'\nGIT push\nEOF", "FOO=1 bash <<'EOF'\n$\"@G@\" push\nEOF",
    )
    DATA = (
        "bash <<'EOF'\necho hi\nEOF", "cat > f <<'EOF'\nGIT push notes\nEOF", "cat <<'EOF'\nGIT push\nEOF",
        "cat <<EOF | grep x\nGIT push\nEOF", "bash script.sh <<'EOF'\nGIT push\nEOF", "bash -c 'cat' <<'EOF'\nGIT push\nEOF",
        "cat <<'EOF' | bash script.sh\nGIT push\nEOF", "cat <<'EOF' > run.sh\n$'@G@' push\nEOF",
        "@G@ apply <<'EOF'\nGIT push is documented here\nEOF",
    )

    def test_spelled_arguments_after_a_plain_git_block(self):
        for cmd in self.SPELLED_ARGS:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_a_heredoc_fed_to_a_shell_is_code(self):
        for cmd in self.HEREDOCS:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_a_heredoc_that_is_data_stays_allowed(self):
        for cmd in self.DATA:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_virtual_segment_carries_the_spelled_arguments(self):
        self.assertIn(G + ' push', _code(_g("@G@ $'push'")))
        self.assertIn(G + ' push', _code(_g('@G@ ${IFS}push')))
        self.assertIn(G + ' -C . push', _code(_g("@G@ -C . $\"push\"")))
        self.assertIn(G + ' push', _code(_g("GIT_DIR=. @G@ $'push'")))

    def test_a_plain_argument_adds_nothing(self):
        # What main sees is what runs: no virtual segment for a plain `git` with plain words.
        for cmd in (G + ' push origin main', G + " commit -m 'a b' -F f", G + ' status | head',
                    'CAST_PUSH_OK=1 ' + G + ' push'):
            with self.subTest(cmd=cmd):
                self.assertEqual([c for c in _code(cmd) if G in c], [])

    def test_the_heredoc_body_is_a_payload_only_for_a_stdin_shell(self):
        self.assertIn('GIT push\n', _code("bash <<'EOF'\nGIT push\nEOF"))
        self.assertIn('GIT push\n', _code("cat <<'EOF' | bash\nGIT push\nEOF"))
        self.assertNotIn('GIT push\n', _code("cat > f <<'EOF'\nGIT push\nEOF"))


class TestReviewH2NewlineAfterPipe(_Oracle):
    """H2: `|` followed by a newline (blank lines, comments) still continues the pipeline."""

    BLOCK = (
        "echo '@G@ push' |\n bash", "echo '@G@ push' |\n\n bash", "echo '@G@ push' | # c\n bash",
        "echo '@G@ push' | cat |\n sh", "echo '@G@ push' |&\n bash", "echo '@G@ push' |\n# a comment\n bash",
        "echo '@G@ push' |\n\n# c\n\n bash -s", "printf 'GIT push\\n' |\n sh", "echo 'GIT push' | tee f |\n zsh",
    )
    ALLOW = (
        "echo '@G@ push' |\n grep push", "echo '@G@ push'\nbash", "echo '@G@ push' ||\n bash",
        "echo '@G@ push' |\n cat\nbash", "echo '@G@ push' &&\n bash", "echo '@G@ push' |\n # c\n cat", "echo hi |\n bash",
    )

    def test_a_pipeline_continues_across_the_newline(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_what_is_not_a_pipeline_stays_allowed(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_pipe_sink_refusal_spans_the_newline(self):
        for cmd in ("echo '@G@ push' $[1] |\n bash", "echo '@G@ push' $[1] |\n\n  sh", "echo '@G@ push' $[1] | # c\n $SHELL",
                    "echo '@G@ push' $[1] | cat |\n sudo bash", "echo '@G@ push' |\n bash -s $[1]",
                    "echo '@G@ push' |\n\n bash -s $[1]"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))
        self.assertBlocks(_g("echo '@G@ push' $[1] |\n grep push"))      # any later pipe: see `_PIPE_SINK`

    def test_the_data_is_carried_across_the_newline(self):
        self.assertIn(G + ' push', _code(_g("echo '@G@ push' |\n bash")))
        self.assertIn(G + ' push', _code(_g("echo '@G@ push' |\n\n# c\n bash")))
        self.assertNotIn(G + ' push', _code(_g("echo '@G@ push'\nbash")))


class TestReviewM1PlainGitSkip(_Oracle):
    """M1: a plain `git` is skipped only where `_normalize_git_segment` and main's anchored patterns
    really see it as the first word of a main segment."""

    BLOCK = (
        'sleep 0 &@G@ push', 'case x in x)@G@ push;; esac', 'sleep 0 & /usr/bin/@G@ push',
        'case x in x) /usr/bin/@G@ push;; esac', 'x+=1 /usr/bin/@G@ push', 'x[0]=1 /usr/bin/@G@ push',
        '>/dev/null /usr/bin/@G@ push', '2>&1 /usr/bin/@G@ push', 'echo x |& /usr/bin/@G@ push', 'echo x |& @G@ push',
        '{ /usr/bin/@G@ push; }', '( /usr/bin/@G@ push )', 'if /usr/bin/@G@ push; then :; fi', '! /usr/bin/@G@ push',
        'sleep 0 &@G@ --git-dir . push', '{ @G@ --git-dir . push; }', 'if @G@ --git-dir . push; then :; fi',
        'x+=1 @G@ --git-dir . push',
    )
    ALLOW = (
        'CAST_PUSH_OK=1 @G@ push', 'CAST_PUSH_OK=1 /usr/bin/@G@ push', 'CAST_COMMIT_AGENT=1 @G@ commit -F f',
        'CAST_COMMIT_AGENT=1 /usr/bin/@G@ commit -F f', '@G@ status', '/usr/bin/@G@ log | head', 'x=1; @G@ diff',
        'ls && /usr/bin/@G@ status', 'ls || @G@ status\n@G@ log', 'CAST_PUSH_OK=1 @G@ push\n@G@ status',
    )

    def test_a_plain_git_the_shell_runs_but_main_cannot_see_blocks(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_a_plain_git_main_sees_is_left_to_main(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_skip_is_exactly_the_main_segment_start(self):
        # skipped: nothing but main's own anchoring
        for cmd in ('/usr/bin/@G@ push', 'A=1 /usr/bin/@G@ push', 'ls; /usr/bin/@G@ push', 'ls\n/usr/bin/@G@ push',
                    'ls && /usr/bin/@G@ push', 'ls || /usr/bin/@G@ push', 'ls | /usr/bin/@G@ push', 'ls |  /usr/bin/@G@ push'):
            with self.subTest(cmd=cmd):
                self.assertEqual([c for c in _code(_g(cmd)) if G in c], [])
        # emitted: anywhere else
        for cmd in ('ls & /usr/bin/@G@ push', 'ls |& /usr/bin/@G@ push', '{ /usr/bin/@G@ push; }', 'x+=1 /usr/bin/@G@ push',
                    '>f /usr/bin/@G@ push', 'A=1 B+=2 /usr/bin/@G@ push'):
            with self.subTest(cmd=cmd):
                self.assertIn(G + ' push', _code(_g(cmd)))


class TestReviewM2IfsFields(_Oracle):
    """M2: every field `$IFS` / `${IFS}` makes of a word is a word of its own, for git, the shells,
    `eval` and the rest - not only the first one."""

    BLOCK = (
        'command${IFS}@G@ push', 'env${IFS}@G@${IFS}push', 'time${IFS}@G@ push', 'nohup${IFS}@G@ push',
        "eval${IFS}'@G@ push'", "eval${IFS}@G@${IFS}push",
        "bash${IFS}-c${IFS}'@G@ push'", "bash -c${IFS}'@G@ push'", "sh${IFS}-c '@G@ push'", "env${IFS}-S${IFS}'@G@ push'",
        "echo${IFS}'@G@ push' | bash", "echo 'GIT push' |${IFS}bash", "trap${IFS}'@G@ push'${IFS}EXIT",
        'xargs${IFS}GIT${IFS}push',
    )

    def test_every_field_is_a_word(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_a_sudo_form_is_guard_only(self):
        # Never run in the oracle: GitHub's sudo is passwordless and resets PATH, macOS's prompts.
        for cmd in ('sudo${IFS}-u${IFS}root${IFS}@G@ push', 'sudo${IFS}@G@${IFS}push'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_no_new_false_positives(self):
        for cmd in ('command${IFS}@G@ status', 'echo${IFS}@G@ push', "echo${IFS}'@G@ push' | grep x", 'time${IFS}ls',
                    "bash${IFS}-c${IFS}'echo hi'", 'ls${IFS}-l'):
            with self.subTest(cmd=cmd):
                code, msg = self.verdict(_g(cmd))
                if 'echo${IFS}@G@ push' == cmd:
                    continue            # main blocks `echo git push` (its own false positive); not ours to judge
                self.assertEqual((code, msg), (0, ''), cmd)

    def test_the_fields_become_words(self):
        self.assertIn(G + ' push', _code(_g('command${IFS}@G@ push')))
        self.assertIn(G + ' push', _code(_g('env${IFS}@G@${IFS}push')))
        self.assertIn(G + ' push', _code(_g("bash${IFS}-c${IFS}'@G@ push'")))


class TestReviewM3AnsiControlBackslash(_Oracle):
    """M3: bash 5 reads `\\c\\\\` as ONE control-backslash (0x1c), so the `\\n` after it is a newline."""

    def test_decoding(self):
        self.assertEqual(gg._ansi_c(r'\c\\'), '\x1c')
        self.assertEqual(gg._ansi_c(r'\c\\\ngit'), '\x1c\ngit')
        self.assertEqual(gg._ansi_c(r'\c\\\\'), '\x1c\\')       # `\c\\` then a literal `\\`
        self.assertEqual(gg._ansi_c(r'\cA\n'), '\x01\n')
        self.assertEqual(gg._ansi_c(r'\c?'), '\x7f')
        self.assertEqual(gg._ansi_c('\\c\\'), '\x1c')           # a lone trailing `\c\` is still `\c` + `\`

    def test_the_payload_is_found(self):
        cmd = "bash -c $'\\c\\\\\\ngit push'"        # bash -c $'\c\\\ngit push'
        self.assertRunsAndBlocks(cmd)
        self.assertRunsAndBlocks(cmd.replace('git', G))
        self.assertAllows("bash -c $'\\c\\\\\\n" + G + " status'")

    def test_bash_3_and_zsh_read_it_the_other_way_so_both_readings_are_payloads(self):
        # bash 3.2 / zsh take `\c` and ONE character: `\c\` then `\n` (a newline). Inside backticks
        # the `\\` is unescaped to `\`, which leaves exactly that for them to run.
        self.assertEqual(gg._ansi_c(r'\c\\\ngit', True), '\x1c\\ngit')       # `\c\` then a literal `\` and `n`
        self.assertEqual(gg._ansi_c(r'\c\\ngit'), '\x1cngit')
        self.assertEqual(gg._ansi_c(r'\c\\ngit', True), '\x1c\ngit')
        self.assertIn('\x1c\n' + G + ' push', _code("bash -c $'\\c\\\\ngit push'".replace('git', G)))

    def test_the_legacy_reading_runs_only_under_bash_3_or_zsh(self):
        # The inner `bash` is the one first on PATH: bash 3.2 on macOS, bash 5 on ubuntu (which reads
        # `\c\\` as one character and so never runs these - the repro is skipped there).
        legacy = ("echo `bash -c $'\\c\\\\\\ngit push'`".replace('git', G), "bash -c $'\\c\\\\ngit push'".replace('git', G))
        for cmd in legacy:                  # the guard's verdict first: the skip below must not take it along
            self.assertBlocks(cmd)
        if not _PATH_BASH_IS_LEGACY:
            self.skipTest('the `bash` on PATH is not bash 3.x: it does not read `\\c\\\\` the legacy way')
        for cmd in legacy:
            self.assertRunsAndBlocks(cmd)


class TestReviewM4Bounds(_Oracle):
    """M4: the rest of the command that rides along with a spelled git word is charged per WORD."""

    SHAPES = (
        ('quoted gits then padding', ("$'" + G + "' ") * 1000 + 'x ' * 20000),
        ('few gits, huge rest', ("$'" + G + "' ") * 150 + 'x ' * 85000),
        ('upper-case gits, huge rest', 'GIT ' * 150 + 'x ' * 85000),
        ('plain gits, huge rest', G + ' ' + ('echo ' + G + ' ') * 150 + 'x ' * 85000),
    )

    def test_the_shapes_are_bounded_and_fail_closed_or_allow_quickly(self):
        for name, cmd in self.SHAPES:
            with self.subTest(shape=name, length=len(cmd)):
                code, msg, elapsed = self.timed(cmd)
                self.assertLess(elapsed, BOUND_SECS, f'{name}: {elapsed:.2f} s')
                self.assertIn(code, (0, 2))

    def test_the_virtual_segments_are_bounded_in_size(self):
        # Deterministic: what the scan is allowed to produce, whatever the machine's speed.
        for name, cmd in self.SHAPES:
            budget = [gg._MAX_EXEC_SCAN_STEPS, gg._MAX_EXEC_CODES]
            try:
                codes = gg._executed_code(cmd, budget)
            except gg._ExecOverBudget:
                continue
            with self.subTest(shape=name):
                self.assertLess(sum(map(len, codes)), 6_000_000)

    def test_the_rest_of_the_command_is_charged_per_word(self):
        # `GIT` then 4000 plain words: the code string carries all of them, so the charge is ~ a
        # quarter of their number (kills a charge per character, per KB, or none).
        text = 'GIT ' + 'x ' * 4000
        words = _words(text)
        budget = [10 ** 6, 10 ** 6]
        found, _ = gg._shell_payloads(words, text, budget)
        self.assertEqual(len(found), 1)
        self.assertGreaterEqual(10 ** 6 - budget[0], 4000 >> 2)
        # and a word that is not git costs nothing for the rest
        text = 'echo ' + 'x ' * 4000
        budget = [10 ** 6, 10 ** 6]
        gg._shell_payloads(_words(text), text, budget)
        self.assertEqual(10 ** 6 - budget[0], 0)

    def test_each_special_word_is_charged_for_its_reading(self):
        # `_word_view` reads every special word: charged `1 + len >> 6` BEFORE it is done.
        raw = "$'" + 'x' * 6400 + "'"
        text = 'echo ' + raw
        words = [gg._W('echo', 0, 4), gg._W('x' * 6400, 5, 5 + len(raw))]
        budget = [10 ** 6, 10 ** 6]
        gg._shell_payloads(words, text, budget)
        self.assertGreaterEqual(10 ** 6 - budget[0], 1 + (len(raw) >> 6))
        with self.assertRaises(gg._ExecOverBudget):
            gg._shell_payloads(words, text, [50, 10 ** 6])
        # a plain word is not read at all
        text = 'echo ' + 'x' * 6400
        budget = [10 ** 6, 10 ** 6]
        gg._shell_payloads([gg._W('echo', 0, 4), gg._W('x' * 6400, 5, len(text))], text, budget)
        self.assertEqual(10 ** 6 - budget[0], 0)

    def test_a_virtual_segment_is_a_leaf_so_many_git_words_do_not_nest(self):
        # One simple command with many plain `git` words (a missing `&&`, `xargs`): each gets its
        # own virtual segment, and none of those is scanned again for the others - else the chain
        # `git add a git add b git add c ...` nests one level per word and trips the depth cap.
        cmd = ' '.join(G + ' add f%d' % i for i in range(12))
        self.assertAllows(cmd)
        self.assertAllows('x ' + cmd)
        self.assertBlocks(cmd + ' ' + G + ' commit -m x')
        self.assertTrue(all(isinstance(c, gg._Virtual) for c in _code('x ' + cmd) if c.startswith(G + ' ')))

    def test_the_ansi_mention_cap(self):
        # A text with `$'` and more numeric escapes than the cap counts as a mention WITHOUT decoding them all.
        cap = gg._ANSI_MENTION_MAX
        self.assertFalse(gg._git_mentioned("$'" + r'\x41' * cap + "'"))
        self.assertTrue(gg._git_mentioned("$'" + r'\x41' * (cap + 1) + "'"))
        self.assertTrue(gg._git_mentioned("$'" + r'\x41' * cap + r'\x67' + "'"))       # decoded: a letter of git
        self.assertFalse(gg._git_mentioned(r'\x41' * (cap + 1)))                       # no `$'`: not ANSI-C at all
        # bounded: a megabyte of escapes is answered by the cap, not by decoding them all
        t0 = time.perf_counter()
        self.assertTrue(gg._git_mentioned("$'" + r'\x41' * 150_000 + "'"))
        self.assertLess(time.perf_counter() - t0, BOUND_SECS)


def _words(text):
    """The `_W` words of the FIRST simple command the lexer builds for `text`."""
    calls = []
    with mock.patch.object(gg, '_shell_payloads',
                           side_effect=lambda w, *a: calls.append(list(w)) or ([], False)):
        _code(text)
    return calls[0]


class TestReviewM5Residuals(_Oracle):
    """M5: printf / echo escapes into a shell, multi-digit `${NN}`; and what stays a documented residual."""

    BLOCK = (
        "printf '@G@ push' | bash", "printf 'g\\151t push' | bash", "printf 'g\\x69t push' | bash",
        "echo -e 'g\\x69t push' | bash", "echo -e 'g\\0151t push' | bash", "printf 'ls\\n\\147it push\\n' | sh",
        "printf '\\x67\\x69\\x74 push' | bash", "echo -e '\\x47IT push' | bash",
        "echo -e 'g\\x69t push' | tee f | sh",
        "bash -c '@G@ ${10}' 0 1 2 3 4 5 6 7 8 9 push", "bash -c '@G@ ${11}' 0 1 2 3 4 5 6 7 8 9 x push",
        "bash -c '@G@ \"${10}\"' 0 1 2 3 4 5 6 7 8 9 push",
    )
    ALLOW = (
        "printf 'g\\151t status' | bash", "echo -e 'g\\x69t log' | bash", "printf 'g\\151t push' | grep x",
        "bash -c '@G@ ${10}' 0 1 2 3 4 5 6 7 8 9 status", "printf 'g\\151t push' > f",
        "echo -e 'g\\x69t push' | head -1",
    )

    def test_escapes_piped_into_a_shell_are_decoded(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_no_new_false_positives(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_decoded_argument_is_a_payload_next_to_the_raw_one(self):
        codes = _code("printf 'g\\151t push' | bash")
        self.assertIn('g\\151t push', codes)            # raw: additive
        self.assertIn(G + ' push', codes)
        codes = _code("echo -e 'g\\0151t push' | bash")
        self.assertIn(G + ' push', codes)

    # A SAMPLE of the documented residuals (the module docstring's RESIDUALS list - not every listed form
    # is here): a shell RUNS git and the guard allows it. Pinned so a later closure of one of these is a
    # deliberate edit of the docs AND this list.
    RESIDUALS = (
        "echo '@G@ push' | (bash)", "echo '@G@ push' | if true; then bash; fi", "{ echo '@G@ push'; } | bash",
        "echo '@G@ push' | xargs -I{} bash -c '{}'", "bash -c '@G@ ${1:-push}' x", "bash -c '@G@ ${1#}' x push",
        "x=push; @G@ $x", "python3 -c 'import os; os.system(\"@G@ push\")'",
        "echo '@G@ push' | frobnicate bash", "printf 'g%s push' it | bash",
        # Unit B-v: the residuals the module docstring lists and the oracle confirmed (each RAN push in a shell)
        "source -- /dev/stdin <<< '@G@ push'", "{ bash; } <<< '@G@ push'", "( bash ) <<EOF\nGIT push\nEOF",
        "bash < <((echo '@G@ push'))", "cat < <(echo '@G@ push') | bash", "bash <(cat <<EOF\nGIT push\nEOF\n)",
        "source /dev/fd/3 3<<< '@G@ push'", "echo '@G@ push' | bash $(echo /dev/stdin)", "echo '@G@ push' | bash /dev/std?n",
        "echo '@G@ push' | env -S 'bash -s'", "@G@ >/dev/null push", "@G@ {fd}>f push", "@G@ -c 'a;b' push",
        "bash -c '@G@ ${1:0}' x push", "bash -c 'shift; @G@ $1' x y push", "bash -c 'for a; do $a; done' x '@G@ push'",
        "zsh -c $'\\c\\nGIT push'", "bash {fd} >/dev/null -c '@G@ push'",
    )

    def test_documented_residuals_are_still_residuals(self):
        for cmd in self.RESIDUALS:
            with self.subTest(cmd=cmd):
                code, msg = self.verdict(_g(cmd))
                self.assertEqual(code, 0, f'now BLOCKED - update the docs and RESIDUALS: {cmd!r}')


class TestReviewLowStdinShellIsTheCommandWord(_Oracle):
    """LOW: a stdin shell is the stage's COMMAND word - the first word after assignments and
    redirections, or after only the wrappers (and their options) - never an argument of another
    command (`grep -v sh`)."""

    ALLOW = (
        "rg '@G@ push' docs | grep -v sh", "echo '@G@ push is blocked' | grep sh", "echo '@G@ push' | grep -c bash",
        "echo '@G@ push' | wc -l bash", "echo '@G@ push' | tee sh", "echo '@G@ push' | sed s/sh/x/", "echo '@G@ push' | cat -n bash",
        "echo '@G@ push' | python3 -c 'print(1)' sh", "echo '@G@ push' | xargs bash",
    )
    BLOCK = (
        "echo '@G@ push' | bash", "echo '@G@ push' | sudo bash", "echo '@G@ push' | sudo -u root bash",
        "echo '@G@ push' | sudo -E bash", "echo '@G@ push' | env -i A=1 bash", "echo '@G@ push' | nice -n 5 bash",
        "echo '@G@ push' | time bash", "echo '@G@ push' | nohup bash", "echo '@G@ push' | exec bash",
        "echo '@G@ push' | command bash", "echo '@G@ push' | builtin exec bash", "echo '@G@ push' | stdbuf -oL bash",
        "echo '@G@ push' | caffeinate bash", "echo '@G@ push' | arch -arm64 bash", "echo '@G@ push' | doas bash",
        "echo '@G@ push' | noglob zsh", "echo '@G@ push' | nocorrect zsh", "echo '@G@ push' | A=1 B=2 bash",
        "echo '@G@ push' | >/dev/null bash", "echo '@G@ push' | { bash; }", "echo '@G@ push' | /usr/bin/env bash",
        "echo '@G@ push' | sudo nice -n 5 env A=1 bash",
    )

    def test_a_shell_that_is_an_argument_reads_nothing(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_a_shell_at_the_command_position_is_a_stdin_reader(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_accepted_false_positives_stay_documented(self):
        # An upper-case `Git` ARGUMENT followed by a verb, and a herestring to ssh (a shell word that
        # runs elsewhere) are blocked: accepted - the cost of reading every word as a possible git.
        for cmd in ('grep -n Git push.log', 'echo Git push notes'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)


# ---------------------------------------------------------------------------------------------
# Unit B-iv: security round 2 (S-H1 .. S-H3, S-M), the re-review findings (R-F1, R-F2, R-L1,
# R-L3 .. R-L5). Every BLOCK that a shell can run is confirmed with the oracle.
# ---------------------------------------------------------------------------------------------
class TestBivSH1PositionalSubstitution(_Oracle):
    """S-H1: `-c` operands are substituted into the payload the way the shell reads them: a raw
    (unquoted) variant next to the quoted one, `${@}` / `${*}` / `${@:N}`, and the DECODED operand."""

    BLOCK = (
        "bash -c '$1' x '@G@ push'", "bash -c 'eval \"$1\"' x '@G@ push'", "bash -c '$@' x '@G@ push'",
        "bash -c '$0' '@G@ push'", "bash -c 'exec $1' x '@G@ push'", "sh -c 'eval \"$1\"' x \"@G@ push\"",
        "bash -c '@G@ ${@}' x push", "bash -c '@G@ \"${@}\"' x push", "bash -c '@G@ ${*}' x push",
        "bash -c '@G@ ${@:1}' x push", "bash -c '@G@ ${*:1}' x push", "bash -c '@G@ $1' x $'\\x70ush'",
        "bash -c '@G@ \"$1\"' x $'p\\x75sh'", "bash -c '@G@ \"${*}\"' x push", "bash -c '${@:1}' x '@G@ push'",
        "bash -c '@G@ ${@:1:1}' x push",
    )
    ALLOW = (
        "bash -c '@G@ $1' x status", "bash -c '$1' x 'echo hi'", "bash -c '@G@ ${@}' x status",
        "bash -c 'eval \"$1\"' x 'ls -l'", "bash -c '@G@ ${@:1}' x log", "bash -c '@G@ ${*:2}' x push status",
        "bash -c '@G@ ${@}' x", "bash -c '@G@ $1' x $'\\x73tatus'",
    )

    def test_the_operand_is_substituted_as_the_shell_reads_it(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_no_new_false_positives(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_a_raw_variant_is_a_payload_next_to_the_quoted_one(self):
        codes = _code(_g("bash -c '$1' x '@G@ push'"))
        self.assertIn(G + ' push', codes)               # raw: the operand text, unquoted
        self.assertIn("'" + G + " push'", codes)        # quoted: one word (kept: additive)
        codes = _code(_g("bash -c '@G@ $1' x 'a b'"))
        self.assertIn(G + " 'a b'", codes)
        self.assertIn(G + ' a b', codes)

    def test_the_decoded_operand_is_used(self):
        self.assertIn(G + ' push', _code(_g("bash -c '@G@ $1' x $'\\x70ush'")))
        self.assertIn(G + ' push', _code(_g("bash -c '@G@ $1' x $'p'$'ush'")))

    def test_positional_forms(self):
        sub = gg._substitute_positional
        ops = ['x', 'a', 'b', 'c']
        for payload, want in (('$@', 'a b c'), ('${@}', 'a b c'), ('${*}', 'a b c'), ('"${@}"', 'a b c'),
                              ('${@:1}', 'a b c'), ('${*:2}', 'b c'), ('${@:0}', 'x a b c'), ('${@:1:2}', 'a b'),
                              ('${@:3}', 'c'), ('${@:9}', ''), ('${1}', 'a'), ('$0', 'x'), ('${@:2:1}', 'b')):
            for raw in (True, False):
                with self.subTest(payload=payload, raw=raw):
                    self.assertEqual(sub(payload, ops, 0, 4, [10 ** 6], raw), want)
        self.assertEqual(sub('$1', ['x', 'a b'], 0, 2, [10 ** 6], True), 'a b')
        self.assertEqual(sub('$1', ['x', 'a b'], 0, 2, [10 ** 6], False), "'a b'")
        with self.assertRaises(gg._ExecOverBudget):
            sub('$@', ['x'] + ['y' * 500] * 50, 0, 51, [20], True)


class TestBivSH2FdBeforeARedirection(_Oracle):
    """S-H2: a `{name}` word right before a redirection operator is that redirection's fd, not an
    operand - it must not hide the `-c` payload, the script operand or the stdin shell."""

    BLOCK = (
        "bash {fd}>/dev/null -c '@G@ push'", "bash -c {fd}>/dev/null '@G@ push'", "echo '@G@ push' | bash {fd}>&2",
        "bash {fd}>/dev/null {fd2}>&2 -c '@G@ push'", "env bash {fd}>/dev/null -c '@G@ push'",
        "bash {fd}<&0 -c '@G@ push'", "bash {a_1}>/dev/null -c '@G@ push'", "echo '@G@ push' | bash {fd}>/dev/null",
        "bash {fd}>/dev/null <<EOF\nGIT push\nEOF",
    )
    ALLOW = (
        "bash {fd}>/dev/null -c 'echo hi'", "echo '@G@ push' | grep {fd}>/dev/null", "bash {fd} >/dev/null -c '@G@ status'",
        "echo '@G@ push' | tee {fd}>/dev/null",
    )

    def test_the_fd_name_is_not_an_operand(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_zsh_reads_it_too(self):
        # the guard's verdict FIRST: the oracle skips the test where zsh is not installed (CI), and a
        # skip must not take the guard assertion with it
        self.assertBlocks(_g("zsh {fd}<&0 -c '@G@ push'"))
        self.assertRunsAndBlocks(_g("zsh {fd}<&0 -c '@G@ push'"), only=_ZSH_SHELLS)

    def test_no_new_false_positives(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_command_words_drops_the_name_the_operator_and_the_target(self):
        ops, here = gg._command_words(_words('bash {fd}>/dev/null -c x'))
        self.assertEqual([str(w) for w in ops], ['bash', '-c', 'x'])
        ops, here = gg._command_words(_words("bash {fd}<<<'abc' -s"))
        self.assertEqual([str(w) for w in ops], ['bash', '-s'])
        self.assertEqual([str(w) for w in here], ['abc'])
        # not adjacent to the operator: an ordinary word
        ops, here = gg._command_words(_words('bash {fd} >/dev/null -c x'))
        self.assertEqual([str(w) for w in ops], ['bash', '{fd}', '-c', 'x'])
        ops, here = gg._command_words(_words('echo {fd}'))
        self.assertEqual([str(w) for w in ops], ['echo', '{fd}'])


class TestBivSH3PipeSink(_Oracle):
    """S-H3: after an unresolved construct ANY later pipe extends the refusal to the pipeline's
    first stage - a shell named with quotes (`ba's'h`, `s''h`, `b"a"s"h"`) cannot dodge it."""

    BLOCK = (
        "echo '@G@ push' $[1] | ba's'h", 'echo \'@G@ push\' "${x:-\'a\'}" | b"a"s"h"', "echo '@G@ push' | tee f $[1] | s''h",
        "echo '@G@ push' $[1] | env ba's'h", "echo '@G@ push' $[1] | { ba's'h; }", "echo '@G@ push' $[1] | /bin/s\\h",
        "echo '@G@ push' $[1] | b\\ash", "echo '@G@ push' $[1] | tee f | ba's'h",
    )

    def test_a_quote_split_shell_after_an_unresolved_construct_blocks(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_zsh_spelled_with_quotes(self):
        self.assertBlocks(_g("echo '@G@ push' $[1] | z's'h"))
        self.assertRunsAndBlocks(_g("echo '@G@ push' $[1] | z's'h"), only=_ZSH_SHELLS)

    def test_what_has_no_git_or_no_pipe_stays_allowed(self):
        for cmd in ("echo hi $[1] | ba's'h", "echo '@G@ push' $[1]", 'echo $[1] | sh', 'ls $[1]'):
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_sink_is_a_plain_pipe(self):
        self.assertEqual(gg._PIPE_SINK.pattern, r'\|')

    def test_the_search_is_linear(self):
        # The old pattern re-scanned the rest of the text from every `|`: `echo $[1] ` + `| # ` x N was
        # quadratic (80 KB hit the 2 s watchdog). Now one `str.find`-like pass: a bound far above
        # what the work needs and far below what quadratic costs.
        for n in (5000, 20000):
            cmd = "echo '" + G + " push' $[1] " + '| # ' * n
            with self.subTest(n=n):
                code, msg, elapsed = self.timed(cmd)
                self.assertEqual(code, 2)
                self.assertLess(elapsed, BOUND_SECS, f'{elapsed:.2f} s')
        t0 = time.perf_counter()
        for _ in range(200):
            gg._PIPE_SINK.search('x' * 4096 + '| # ' * 1000, 0, 8000)
        self.assertLess(time.perf_counter() - t0, 1.0)


class TestBivSMZshEqualsExpansion(_Oracle):
    """S-M: zsh's `=cmd` expands to the path of `cmd`: `=git push` runs git."""

    ZSH = ('=@G@ push', "=@G@ $'push'", 'command =@G@ push', '=GIT push', 'nohup =@G@ push', 'env =@G@ push',
           "=$'@G@' push", 'A=1 =@G@ push')

    def test_zsh_runs_them(self):
        for cmd in self.ZSH:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd), only=_ZSH_SHELLS)

    def test_the_guard_blocks_them(self):
        for cmd in self.ZSH:
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_no_new_false_positives(self):
        for cmd in ('=@G@ status', 'command =@G@ log', "=@G@ $'status'", 'echo ==push', 'x==@G@ status', 'ls =foo'):
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_one_leading_equals_is_stripped(self):
        self.assertIn(G + ' push', _code(_g('=@G@ push')))
        self.assertNotIn(G + ' push', _code(_g('==@G@ push')))


class TestBivSMStdinScripts(_Oracle):
    """S-M: a script operand that IS stdin (`/dev/stdin`, `/dev/fd/0`) makes the shell a stdin
    shell, and so do `source` / `.` reading it."""

    BLOCK = (
        "echo '@G@ push' | bash /dev/stdin", "echo '@G@ push' | bash /dev/fd/0", "bash /dev/stdin <<EOF\nGIT push\nEOF",
        "source /dev/stdin <<< '@G@ push'", ". /dev/stdin <<< '@G@ push'", "echo '@G@ push' | source /dev/stdin",
        "echo '@G@ push' | . /dev/fd/0", "source /dev/stdin <<EOF\nGIT push\nEOF", "echo '@G@ push' | bash -- /dev/stdin",
        "echo '@G@ push' | bash --norc /dev/stdin", "bash /dev/stdin <<< '@G@ push'",
    )
    ALLOW = (
        "echo '@G@ push' | bash /dev/null", "source ./f <<< '@G@ push'", "echo '@G@ push' | source ./f", "echo '@G@ push' | bash script.sh",
        ". ./f <<< '@G@ push'", "bash /dev/stdin <<'EOF'\nls\nEOF", "echo hi | bash /dev/stdin", "source /dev/stdin <<< 'ls'",
    )

    def test_a_stdin_script_operand_reads_the_pipe(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_a_real_script_stays_allowed(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))


class TestBivSMProcessSubstitution(_Oracle):
    """S-M: a process substitution that a shell reads as its stdin or script, or `source` reads, is a
    pipe producer: what its commands write is code."""

    BLOCK = (
        "bash < <(echo '@G@ push')", "source <(echo '@G@ push')", ". <(echo '@G@ push')", "bash <(echo '@G@ push')",
        "bash < <(printf 'GIT push\\n')", "bash < <(echo '@G@ push' | cat)", "source /dev/stdin < <(echo '@G@ push')",
        "bash -s < <(echo 'GIT push')", "bash --norc <(echo 'GIT push')", "sh < <(echo 'GIT' push)",
        "bash < <(echo ls; echo '@G@ push')", "bash < <(echo \"@G@ push\")", "bash <(echo -e 'g\\x69t push')",
        "bash <(cat <(echo '@G@ push'))", "bash < <(cat <(echo 'GIT push'))",
    )
    ALLOW = (
        "diff <(echo '@G@ push') <(ls)", "bash script.sh <(echo '@G@ push')", "bash -c 'echo hi' <(echo '@G@ push')",
        "cat <(echo '@G@ push')", "bash < f", "bash <(echo hi)", "bash < <(echo hi)", "source ./f <(echo '@G@ push')",
        "grep x < <(echo '@G@ push')", "bash -c 'cat' < <(echo '@G@ push')",
    )

    def test_the_producer_of_a_shell_reads_as_code(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_what_is_not_read_as_code_stays_allowed(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))


class TestBivRF1HeredocOnAPipeLine(_Oracle):
    """R-F1: a heredoc on a line that ENDS with a pipe feeds the pipeline's LATER stages - the
    shell may stand on a later line, after the body."""

    BLOCK = (
        "cat <<'EOF' |\nGIT push\nEOF\nbash", "cat <<EOF | tee f |\nGIT push\nEOF\nbash", "cat <<'EOF' |\nGIT push\nEOF\n\n\nbash",
        "cat <<'EOF' |\n$'@G@' push\nEOF\nbash", "cat <<'EOF' |\n@G@ -C . $'push'\nEOF\nbash",
        "cat <<'EOF' |\nGIT push\nEOF\nbash -s", "cat <<'EOF' |&\nGIT push\nEOF\nbash", "cat <<'EOF' |\nGIT push\nEOF\n# c\nbash",
        "cat <<'EOF' | cat |\nGIT push\nEOF\nsh", "cat <<'EOF' |\nGIT push\nEOF\ntee f |\nbash", "x=1; cat <<'EOF' |\nGIT push\nEOF\nbash",
        "cat <<-'EOF' |\n\tGIT push\n\tEOF\nbash", "cat <<'A' <<'B' |\nls\nA\nGIT push\nB\nbash",
    )
    ALLOW = (
        "cat <<'EOF' |\nGIT push\nEOF\ngrep x", "cat <<'EOF' |\nGIT push\nEOF\nbash script.sh", "cat <<'EOF' |\nGIT push\nEOF\ncat\nbash",
        "cat <<'EOF'\nGIT push\nEOF\nbash", "cat <<'EOF' ||\nGIT push\nEOF\nbash", "cat <<'EOF' &&\nGIT push\nEOF\nbash",
        "cat <<'EOF' |\nls\nEOF\nbash", "cat <<'EOF' |\nGIT push\nEOF\ntee f", "cat > f <<'EOF'\nGIT push\nEOF\nbash",
    )

    def test_a_shell_on_a_later_line_reads_the_body(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_what_is_not_fed_to_a_shell_stays_allowed(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_body_is_a_payload_only_once_a_stdin_shell_is_seen(self):
        self.assertIn('GIT push\n', _code("cat <<'EOF' |\nGIT push\nEOF\nbash"))
        self.assertNotIn('GIT push\n', _code("cat <<'EOF' |\nGIT push\nEOF\ngrep x"))
        self.assertNotIn('GIT push\n', _code("cat <<'EOF' |\nGIT push\nEOF\ncat\nbash"))


class TestBivRF2PathQualifiedGitSkip(_Oracle):
    """R-F2: a PATH-qualified git (`/usr/bin/git`) is main's only when main splits the command the way
    the shell does: with a `;` `|` `&` newline `$(` backtick `${` in its span it is judged here too."""

    BLOCK = (
        ('A=$(echo 1) /usr/bin/@G@ push', 'push'), ('A=`echo 1` /usr/bin/@G@ push', 'push'), ('A=${x:-a b} /usr/bin/@G@ push', 'push'),
        ("/usr/bin/@G@ commit -m 'a; b'", 'commit'), ('/usr/bin/@G@ push "a;b"', 'push'), ("x=';' /usr/bin/@G@ push", 'push'),
        ("HOME=/tmp /usr/bin/@G@ commit -m 'fix; x'", 'commit'), ('A=$((1+1)) /usr/bin/@G@ push', 'push'),
        ("/usr/bin/@G@ commit -m 'a & b'", 'commit'), ("/usr/bin/@G@ commit -m 'a | b'", 'commit'),
        ("/usr/bin/@G@ commit -m 'a\nb'", 'commit'),
    )
    ALLOW = (
        "CAST_COMMIT_AGENT=1 @G@ commit -m 'fix; x'", 'CAST_COMMIT_AGENT=1 @G@ commit -F f', 'CAST_PUSH_OK=1 @G@ push',
        'CAST_PUSH_OK=1 /usr/bin/@G@ push', '/usr/bin/@G@ status', "/usr/bin/@G@ log | head", "ls; /usr/bin/@G@ status",
    )

    def test_a_path_qualified_git_main_splits_differently_blocks(self):
        for cmd, verb in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd), verb=verb)

    def test_what_main_sees_is_left_to_main(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_skip_needs_a_clean_span(self):
        for cmd in ('/usr/bin/@G@ push', 'A=1 /usr/bin/@G@ push', 'ls; /usr/bin/@G@ push', 'ls | /usr/bin/@G@ push',
                    "CAST_PUSH_OK=1 /usr/bin/@G@ push"):
            with self.subTest(cmd=cmd):
                self.assertEqual([c for c in _code(_g(cmd)) if G in c], [])
        for cmd in ('A=$(x) /usr/bin/@G@ push', '/usr/bin/@G@ push "a;b"', "/usr/bin/@G@ commit -m 'a|b'"):
            with self.subTest(cmd=cmd):
                self.assertTrue([c for c in _code(_g(cmd)) if c.startswith(G + ' ')], cmd)


class TestBivRL1EvalReadsTheLegacyBackslashC(_Oracle):
    """R-L1: `eval` reads its operands both ways, like `-c`: bash 5 takes `\\c\\\\` as one character,
    bash 3.2 and zsh as `\\c\\`."""

    def test_the_eval_operand_is_read_both_ways(self):
        cmd = _g("eval $'\\c\\\\nGIT push'")
        self.assertIn('\x1c\nGIT push', _code(cmd))
        self.assertBlocks(cmd)
        self.assertRunsAndBlocks(cmd, only=_LEGACY_ANSI_SHELLS)

    def test_the_bash_5_reading_is_kept(self):
        cmd = _g("eval $'\\c\\\\\\nGIT push'")
        self.assertIn('\x1c\nGIT push', _code(cmd))
        self.assertRunsAndBlocks(cmd)

    def test_a_harmless_eval_stays_allowed(self):
        self.assertAllows(_g("eval $'\\c\\\\nGIT status'"))


class TestBivRL3StdinWrappers(_Oracle):
    """R-L3: the wrappers a stdin shell can stand behind, each with its option arity. The list is
    CLOSED: a wrapper that is not in it hides a stdin shell (documented residual)."""

    BLOCK = (
        'timeout 5 bash', 'timeout -s KILL 5 bash', 'timeout -k 1 5 bash', 'setsid bash', 'setsid -w bash', 'ionice bash',
        'ionice -c 2 -n 4 bash', 'ionice -c3 bash', 'unbuffer bash', "sandbox-exec -p '(version 1)(allow default)' bash",
        'sandbox-exec -f prof.sb bash', 'sandbox-exec -n name bash', 'chroot / bash', 'chroot --userspec=1 / bash',
        'taskset 1 bash', 'taskset -c 0 bash', 'chrt 10 bash', 'chrt -f 10 bash', 'watch bash', 'watch -n 1 bash',
        'sudo timeout 5 bash', 'timeout 5 nice -n 5 bash', 'timeout 5 env A=1 bash', '/usr/bin/timeout 5 bash',
        'TIMEOUT 5 bash', 'timeout 5 timeout 5 bash', 'nice timeout 5 setsid bash',
    )
    ALLOW = (
        'timeout 5 grep sh', 'timeout 5 cat bash', 'chroot / cat bash', 'taskset 1 cat sh', 'chrt 10 grep -v bash',
        'setsid cat bash', 'ionice -c 2 grep sh', 'unbuffer cat sh', "sandbox-exec -p x cat bash", 'watch cat bash',
        'timeout 5 tee sh', 'timeout bash 5',
    )

    def test_a_stdin_shell_behind_a_wrapper(self):
        for tail in self.BLOCK:
            with self.subTest(tail=tail):
                self.assertBlocks(_g("echo '@G@ push' | " + tail))

    def test_a_shell_that_is_an_argument_reads_nothing(self):
        for tail in self.ALLOW:
            with self.subTest(tail=tail):
                self.assertAllows(_g("echo '@G@ push' | " + tail))

    def test_the_documented_wrapper_list_is_closed(self):
        for name in ('timeout', 'setsid', 'ionice', 'unbuffer', 'sandbox-exec', 'chroot', 'taskset', 'chrt', 'watch'):
            self.assertIn(name, gg._STDIN_WRAPPERS)
        self.assertEqual(gg._WRAPPER_OPERANDS, {'timeout': 1, 'chroot': 1, 'taskset': 1, 'chrt': 1})
        # a wrapper that is not listed hides the stdin shell: a RESIDUAL, pinned
        self.assertEqual(self.verdict(_g("echo '@G@ push' | frobnicate bash"))[0], 0)


# ---------------------------------------------------------------------------------------------
# Unit B-v: the last small findings (security round 3): a newline in a positional operand, zsh's
# `=bash`, stdin script paths spelled with extra slashes / zeros, `eval` as a stdin wrapper.
# Every BLOCK that a shell can run is confirmed with the oracle.
# ---------------------------------------------------------------------------------------------
class TestBvNewlineInAPositionalOperand(_Oracle):
    """H1: an UNQUOTED `$1` / `$@` / `$*` is word-split on IFS - space, tab AND newline. The payload
    the operand is substituted into must read a newline as a blank, not as a command separator
    (`git` newline `push` is two commands, `git push` one)."""

    BLOCK = (
        "bash -c '@G@ $1' x $'\\npush'", "bash -c '@G@ $1' x $'\\x0a'push", "bash -c '$1' x $'@G@\\npush'",
        "bash -c '$1 $2' x $'@G@\\n' push", "bash -c '@G@ $@' x $'\\npush'", "bash -c '@G@ $*' x $'\\npush'",
        "bash -c '$@' x $'@G@\\npush'", "bash -c '$*' x $'@G@\\npush'", "bash -c '${@}' x $'@G@\\npush'",
        "bash -c '@G@ ${1}' x $'\\npush'", "bash -c '@G@ $1' x $'\\t\\npush'", "bash -c 'exec $1' x $'@G@\\npush'",
        "sh -c '@G@ $1' x $'\\npush'", "bash -c '@G@ ${@:1}' x $'\\npush'", "bash -c '$1' x $'@G@\\n\\npush'",
        "bash -c '@G@ $1 $2' x $'\\n' push", "bash -c '@G@ $1' x $'\\n'push", "bash -c '@G@ $1' x $'\\x0a\\x0apush'",
        "bash -c '$1' x '@G@\npush'", "bash -c '@G@ $1' x '\npush'",
    )
    ALLOW = (
        "bash -c '@G@ $1' x $'\\nstatus'", "bash -c '@G@ $1' x $'\\n'", "bash -c 'echo $1' x $'\\npush'",
        "bash -c '$1' x $'@G@\\nstatus'", "bash -c '@G@ $@' x $'\\nlog'", "bash -c '$1 $2' x $'@G@\\n' status",
        "bash -c '@G@ $1' x $'\\n\\n'", "bash -c '@G@ $1' x $'\\tstatus\\n'",
    )

    def test_a_newline_in_an_unquoted_operand_separates_words(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_quoted_all_operands_are_read_the_unquoted_way_too(self):
        # The shell does NOT split `"$@"` / `"$*"` (the operand stays one word with its newline in
        # it), but the raw reading has always taken the quotes off: kept, so these block too.
        for cmd in ("bash -c '@G@ \"$@\"' x $'\\npush'", "bash -c '\"$@\"' x $'@G@\\npush'",
                    "bash -c '@G@ \"${@}\"' x $'\\npush'"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_no_new_false_positives(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_the_split_reading_is_a_payload_next_to_the_raw_one(self):
        codes = _code(_g("bash -c '@G@ $1' x $'\\npush'"))
        self.assertIn(G + ' \npush', codes)             # raw: the operand's own text (kept: additive)
        self.assertIn(G + '  push', codes)              # split: the newline is a blank
        self.assertIn(G + " '\npush'", codes)           # quoted: one word
        codes = _code(_g("bash -c '@G@ $1' x 'a b'"))   # no newline: nothing new
        self.assertEqual(sorted(c for c in codes if G in c and '$' not in c), [G + " 'a b'", G + ' a b'])

    def test_substitute_positional_split(self):
        sub = gg._substitute_positional
        ops = ['x', 'a\nb', 'c\td']
        for payload, raw, split, want in (
                ('$1', True, True, 'a b'), ('$1', True, False, 'a\nb'), ('$1', False, False, "'a\nb'"),
                ('$@', True, True, 'a b c d'), ('${*:2}', True, True, 'c d'), ('"${@}"', True, True, 'a b c d'),
                ('x $1 y', True, True, 'x a b y')):
            with self.subTest(payload=payload, raw=raw, split=split):
                self.assertEqual(sub(payload, ops, 0, 3, [10 ** 6], raw, split), want)
        with self.assertRaises(gg._ExecOverBudget):
            sub('$@', ['x'] + ['y\n' * 500] * 50, 0, 51, [20], True, True)

    def test_ifs_words_are_already_split_at_a_newline(self):
        # `_word_view` does not share the positional code: `$IFS` is cut into FIELDS (shlex-joined
        # into the virtual segment), so the newline `$IFS` stands for never fuses two words.
        for cmd in ('@G@${IFS}push', '@G@$IFS push', '@G@${IFS}${IFS}push'):
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))
        self.assertEqual(gg._word_view('git${IFS}push'), ['git', 'push'])
        self.assertEqual(gg._word_view("git$IFS$'\\n'push"), ['git', '\npush'])      # the `$'\n'` is quoted: no split


class TestBvZshEqualsShells(_Oracle):
    """zsh's `=cmd` expands to the path of `cmd` - for a SHELL too: `=bash -c 'git push'`."""

    ZSH = (
        "=bash -c '@G@ push'", "echo '@G@ push' | =bash", "=bash <<< '@G@ push'", "=sh -c '@G@ push'", "=zsh -c '@G@ push'",
        "=bash <<EOF\nGIT push\nEOF", "echo 'GIT push' | =zsh", "=bash -lc '@G@ push'", "env =bash -c '@G@ push'",
        "echo '@G@ push' | =env bash", "echo '@G@ push' | =nice bash", "echo '@G@ push' | =bash -s",
        "A=1 =bash -c '@G@ push'", "echo '@G@ push' | =bash /dev/stdin", "=dash -c '@G@ push'", "=bash -c '$1' x '@G@ push'",
        "=bash <(echo '@G@ push')", "=bash < <(echo '@G@ push')",
    )
    ALLOW = (
        "=bash -c 'echo hi'", "echo '@G@ push' | =grep bash", "=bash script.sh", "echo '@G@ push' | =bash script.sh",
        "echo ==bash", "==bash -c '@G@ push'", "echo '@G@ push' | ==bash", "echo =bash -c 'ls'", "=bash <<< 'ls'",
        "x==bash -c '@G@ push'", "echo hi | =bash", "echo '@G@ push' | =cat bash",
    )

    def test_the_guard_blocks_them(self):
        for cmd in self.ZSH:
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))

    def test_zsh_runs_them(self):
        for cmd in self.ZSH:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd), only=_ZSH_SHELLS)

    def test_no_new_false_positives(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_one_leading_equals_is_stripped(self):
        self.assertTrue(gg._is_shell_word(_words('=bash')[0], '=bash'))
        self.assertTrue(gg._is_shell_word(_words('=zsh')[0], '=zsh'))
        self.assertFalse(gg._is_shell_word(_words('==bash')[0], '==bash'))
        self.assertFalse(gg._is_shell_word(_words('=')[0], '='))
        self.assertFalse(gg._is_shell_word(_words('=ls')[0], '=ls'))
        self.assertIn(G + ' push', _code(_g("=bash -c '@G@ push'")))
        self.assertNotIn(G + ' push', _code(_g("==bash -c '@G@ push'")))


class TestBvStdinPathsAndEval(_Oracle):
    """A stdin script path is read as the OS resolves it (`//dev/stdin`, `/dev/./stdin`, `/dev/fd/00`),
    and `eval` stands in front of a stdin shell the way `exec` / `command` do."""

    PATHS = ('//dev/stdin', '/dev//stdin', '/dev/./stdin', '/dev/fd/00', '/dev/fd/./0', '///dev///fd///0', '/./dev/stdin',
             '/dev/../dev/stdin', '/dev/fd/000')
    # Linux's /proc refuses a zero-padded fd number (`/dev/fd/00`: ENOENT), macOS runs it: the guard blocks
    # both, the oracle can only confirm the macOS one
    ZERO_PADDED = ('/dev/fd/00', '/dev/fd/000')
    BLOCK = (
        "echo 'GIT push' | eval bash", "eval source /dev/stdin <<< 'GIT push'", "echo '@G@ push' | eval exec bash",
        "echo '@G@ push' | eval env bash", "echo 'GIT push' | eval bash -s", "echo '@G@ push' | eval eval bash",
        "echo '@G@ push' | eval nice -n 5 bash", "echo 'GIT push' | eval 'bash'", "eval bash <<< '@G@ push'",
        "echo '@G@ push' | eval bash /dev/stdin", "eval . /dev/stdin <<< 'GIT push'", "x=1 eval bash <<< '@G@ push'",
        "echo '@G@ push' | { eval bash; }",
    )
    ALLOW = (
        "echo '@G@ push' | eval echo bash", "echo '@G@ push' | eval bash script.sh", "echo hi | eval bash",
        "echo '@G@ push' | eval grep sh", "echo '@G@ push' | eval cat bash",
        "echo '@G@ push' | bash /dev/stdinx", "echo '@G@ push' | bash /dev/fd/10", "echo '@G@ push' | bash /dev/fd/01x",
        "echo '@G@ push' | bash dev/stdin", "echo '@G@ push' | bash ./dev/stdin", "echo '@G@ push' | bash /dev/fd/",
        "echo '@G@ push' | bash /tmp/dev/stdin", "echo '@G@ push' | bash /dev/null/", "source //tmp/f <<< '@G@ push'",
        "echo '@G@ push' | eval",
    )

    def test_a_stdin_path_with_extra_slashes_or_zeros_reads_the_pipe(self):
        for p in self.PATHS:
            for tpl in ("echo 'GIT push' | bash @P@", "bash @P@ <<< 'GIT push'", "source @P@ <<< 'GIT push'",
                        ". @P@ <<< 'GIT push'", "echo 'GIT push' | bash -- @P@", "echo 'GIT push' | sh @P@"):
                cmd = tpl.replace('@P@', p)
                with self.subTest(cmd=cmd):
                    if p in self.ZERO_PADDED and sys.platform.startswith('linux'):
                        self.assertBlocks(cmd)
                    else:
                        self.assertRunsAndBlocks(cmd)

    def test_a_trailing_slash_is_blocked_whether_or_not_the_os_runs_it(self):
        # macOS's fd device ignores the trailing slash and runs it, Linux fails (ENOTDIR): blocked either way
        for cmd in ("echo 'GIT push' | bash /dev/stdin/", "echo 'GIT push' | bash /dev/fd/0/", "source /dev/stdin/ <<< 'GIT push'"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_a_pipe_and_a_heredoc_are_both_read(self):
        # zsh feeds a stdin shell BOTH the pipe and the heredoc / herestring (bash only the body): both read.
        # The guard's verdict first - the oracle skips the test where zsh is absent (CI).
        for cmd in ("echo '@G@ push' | bash <<'EOF'\nls\nEOF", "echo '@G@ push' | sh <<<ls", "echo 'GIT push' | zsh <<$'EOF'\nls\nEOF"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(_g(cmd))
        self.assertRunsAndBlocks(_g("echo '@G@ push' | bash <<'EOF'\nls\nEOF"), only=_ZSH_SHELLS)

    def test_eval_is_a_stdin_wrapper(self):
        for cmd in self.BLOCK:
            with self.subTest(cmd=cmd):
                self.assertRunsAndBlocks(_g(cmd))

    def test_no_new_false_positives(self):
        for cmd in self.ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(_g(cmd))

    def test_is_stdin_path(self):
        for p in ('-', '/dev/stdin', '/dev/fd/0', '/proc/self/fd/0', '/proc/self/fd/00') + self.PATHS + ('/dev/stdin/', '/dev/fd/0/'):
            with self.subTest(p=p):
                self.assertTrue(gg._is_stdin_path(p))
        for p in ('', '--', 'stdin', '/dev/null', '/dev/fd/1', '/dev/fd/10', '/dev/fd/01', '/dev/stdinx', '/dev/stdout', 'dev/stdin',
                  './dev/stdin', '/dev/fd/', '/dev/fd', '/dev/fd/0x', '/tmp/dev/stdin', '/proc/self/fd/10', '/dev/null/', '/'):
            with self.subTest(p=p):
                self.assertFalse(gg._is_stdin_path(p))

    def test_eval_stays_in_the_wrapper_list(self):
        self.assertIn('eval', gg._STDIN_WRAPPERS)

    def test_a_run_of_evals_stays_linear(self):
        for n in (2000, 20000):
            cmd = "echo '" + G + " push' | " + 'eval ' * n + 'bash'
            with self.subTest(n=n):
                code, msg, elapsed = self.timed(cmd)
                self.assertEqual(code, 2)
                self.assertLess(elapsed, BOUND_SECS, f'{elapsed:.2f} s')


if __name__ == '__main__':
    unittest.main()
