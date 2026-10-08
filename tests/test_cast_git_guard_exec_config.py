#!/usr/bin/env python3
"""Exec-capable git config keys blocked in the Bash git guard (U6a-1, CAST v10.3.0).

`scripts/cast-git-guard.py` used to block only gc-expiry config injection. A git config key that makes
git EXECUTE a program (`core.fsmonitor`, `core.hooksPath`, `core.pager`, `alias.*`, `filter.*.smudge`,
`credential.helper`, `include.path`, ...) runs in Ed's UNSANDBOXED terminal and in CAST hooks the next
time anyone runs `git status` in that repo; the file-tool route to `.git/config` is policy-gated, the
Bash `git config` write was not. Pinned here:

  * BLOCK matrix: every key family x every write/injection form (`config k v`, scopes, `--file`,
    `set`, `--add`, `-c k=v`, `-ck=v`, `-c k`, `--config-env=k=E`, `--config-env k=E`, the
    GIT_CONFIG_COUNT/KEY/VALUE trio), mixed-case keys, quoted forms, spelled git from #420, and the
    gc-expiry keys through `--config-env` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_PARAMETERS` (the
    formerly documented residual) — with the GC message and CAST_GC_OK hatch unchanged;
  * ALLOW matrix (false-positive fences): every read, removal and look-alike stays allowed;
  * hatch: CAST_GIT_CONFIG_OK=1 allows and records exactly once; it is scoped to its own segment;
    `config --edit` accepts either hatch;
  * the new patterns are linear (adversarial token runs finish well inside the PreToolUse timeout);
  * the measured residual (`export GIT_CONFIG_KEY_0=...` in an EARLIER segment) is pinned as allowed.

The verb is assembled (`G`) so no literal guarded command sits in this file. HOME is redirected to a
temp dir and `_record_hatch` is mocked, as in tests/test_cast_git_guard_spellings.py. The hyphenated
module is loaded via importlib, same pattern as the other git-guard tests.
"""
import importlib.util
import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent

_spec = importlib.util.spec_from_file_location(
    'cast_git_guard_exec_config', str(_REPO / 'scripts' / 'cast-git-guard.py'))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

G = 'gi' + 't'
CFG = G + ' config'

# One concrete spelling per key family named in the task (subsections include dotted ones).
EXEC_KEYS = (
    'core.fsmonitor', 'core.hooksPath', 'core.pager', 'core.editor', 'core.sshCommand',
    'core.askPass', 'core.gitProxy', 'core.alternateRefsCommand', 'sequence.editor', 'ssh.variant',
    'pager.log', 'alias.x', 'alias.co.nested', 'filter.lfs.clean', 'filter.lfs.smudge',
    'filter.lfs.process', 'diff.external', 'diff.word.command', 'diff.word.textconv',
    'merge.m.driver', 'mergetool.t.cmd', 'difftool.t.cmd', 'gpg.program', 'gpg.ssh.program',
    'gpg.x509.program', 'credential.helper', 'credential.https://h.example/.helper',
    'remote.origin.uploadpack', 'remote.origin.receivepack', 'remote.origin.vcs',
    'uploadpack.packObjectsHook', 'include.path', 'includeIf.gitdir:~/x/.path',
    'protocol.ext.allow', 'url.ext::sh.insteadOf', 'url.https://a/.pushInsteadOf', 'web.browser',
    'browser.b.cmd', 'man.m.cmd', 'sendemail.smtpServer', 'sendemail.toCmd', 'sendemail.ccCmd',
    'sendemail.headerCmd', 'trailer.t.cmd', 'interactive.diffFilter', 'init.templateDir',
    'submodule.s.update',
)
GC_KEYS = ('gc.pruneExpire', 'gc.reflogExpire', 'gc.reflogExpireUnreachable')

# `@K@` = key, `@V@` = value.
WRITE_FORMS = (
    CFG + ' @K@ @V@',
    CFG + ' --local @K@ @V@',
    CFG + ' --global @K@ @V@',
    CFG + ' --system @K@ @V@',
    CFG + ' --worktree @K@ @V@',
    CFG + ' --file f @K@ @V@',
    CFG + ' -f f @K@ @V@',
    CFG + ' --file=f @K@ @V@',
    CFG + ' --add @K@ @V@',
    CFG + ' --replace-all @K@ @V@',
    CFG + ' --type=bool @K@ @V@',
    CFG + ' set @K@ @V@',
    CFG + ' set --all @K@ @V@',
    CFG + ' --global set @K@ @V@',
)
INJECT_FORMS = (
    G + ' -c @K@=@V@ status',
    G + ' -c@K@=@V@ log',
    G + ' -c @K@ status',
    G + ' --config-env=@K@=E log',
    G + ' --config-env @K@=E log',
    G + ' -C /x -c @K@=@V@ log',
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=@K@ GIT_CONFIG_VALUE_0=@V@ ' + G + ' status',
    "GIT_CONFIG_PARAMETERS=\"'@K@'='@V@'\" " + G + ' status',
    "GIT_CONFIG_PARAMETERS=\"'a'='b' '@K@'='@V@'\" " + G + ' status',
)


class _Base(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-gitexec-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_GIT_CONFIG_OK', 'CAST_GC_OK', 'CAST_COMMIT_AGENT', 'CLAUDE_SUBPROCESS'):
            os.environ.pop(k, None)
        rec = mock.patch.object(gg, '_record_hatch')
        self.record = rec.start()
        self.addCleanup(rec.stop)

    def verdict(self, cmd):
        return gg.evaluate('Bash', {'command': cmd})

    def assertBlocks(self, cmd):
        code, msg = self.verdict(cmd)
        self.assertEqual(code, 2, f'ALLOWED, must block: {cmd!r}')
        self.assertTrue(msg and '[CAST]' in msg, f'{cmd!r}: block without a CAST message: {msg!r}')
        return msg

    def assertAllows(self, cmd):
        code, msg = self.verdict(cmd)
        self.assertEqual((code, msg), (0, ''), f'BLOCKED, must allow: {cmd!r}: {msg!r}')


class TestBlockMatrix(_Base):
    def test_every_key_family_every_write_form(self):
        for key in EXEC_KEYS:
            for form in WRITE_FORMS:
                for value in ('x', 'true'):
                    cmd = form.replace('@K@', key).replace('@V@', value)
                    with self.subTest(cmd=cmd):
                        self.assertBlocks(cmd)

    def test_every_key_family_every_injection_form(self):
        for key in EXEC_KEYS:
            for form in INJECT_FORMS:
                cmd = form.replace('@K@', key).replace('@V@', 'v')
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_empty_and_benign_looking_values_block(self):
        # Same deny-by-default precedent as the gc keys: ANY value blocks.
        for cmd in (CFG + " core.pager ''", CFG + ' core.pager ""', CFG + ' core.fsmonitor false',
                    CFG + ' core.hooksPath /dev/null', G + ' -c core.fsmonitor=false status',
                    G + ' -c core.hooksPath= status'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_mixed_case_keys(self):
        for cmd in (CFG + ' Core.FsMonitor x', CFG + ' CORE.HOOKSPATH x', CFG + ' ALIAS.x !sh',
                    G + ' -c Core.Pager=x status', G + ' --config-env=Core.Pager=E log',
                    'GIT_CONFIG_KEY_0=CORE.FSMONITOR ' + G + ' status'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_quoted_forms(self):
        for cmd in (CFG + " 'core.pager' x", CFG + ' "core.pager" x', CFG + " core.pager 'less -R'",
                    G + ' -c "alias.x=!sh" status', G + " -c 'core.pager=less' status",
                    G + ' -c "core.fsmonitor" status', G + ' --config-env="core.pager=E" log',
                    G + " -c'core.pager=x' log", CFG + " 'includeIf.gitdir:~/x/.path' /y",
                    'GIT_CONFIG_KEY_0="core.pager" ' + G + ' status',
                    'GIT_CONFIG_KEY_0=\'alias.x\' ' + G + ' status'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_spelled_git_from_420(self):
        for cmd in ("bash -c '" + CFG + " core.hooksPath x'", 'sh -c "' + G + ' -c core.pager=x status"',
                    "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=v " + G + ' status',
                    'eval "' + CFG + ' alias.x !sh"', 'echo $(' + CFG + ' core.pager x)',
                    G.upper() + CFG[len(G):] + ' core.pager x', "/usr/bin/" + CFG + ' core.pager x'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_rename_section_into_an_exec_section(self):
        for cmd in (CFG + ' --rename-section x alias', CFG + ' rename-section x alias',
                    CFG + ' --rename-section x filter.lfs', CFG + ' rename-section x core',
                    CFG + ' --global --rename-section x includeIf.gitdir:~/x/'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_env_file_injection(self):
        for cmd in ('GIT_CONFIG_GLOBAL=/tmp/evil ' + G + ' status',
                    'GIT_CONFIG_SYSTEM=/tmp/evil ' + G + ' log',
                    'GIT_CONFIG_GLOBAL="$HOME/.evilconfig" ' + G + ' status',
                    'GIT_CONFIG_GLOBAL=/dev/null/x ' + G + ' status'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_edit_still_blocked_with_extended_message(self):
        msg = self.assertBlocks(CFG + ' -e')
        self.assertIn('CAST_GIT_CONFIG_OK', msg)
        self.assertIn('CAST_GC_OK', msg)
        self.assertBlocks(CFG + ' edit')


class TestGcKeysThroughIndirection(_Base):
    """The docstring residual (`--config-env` / GIT_CONFIG_KEY_<n>) is closed, with the GC message."""

    CMDS = (
        G + ' --config-env=gc.pruneExpire=PRX gc',
        G + ' --config-env gc.pruneExpire=PRX gc',
        G + ' --config-env=gc.reflogExpire=PRX gc',
        G + ' --config-env="gc.reflogExpireUnreachable=PRX" gc',
        'PRX=now ' + G + ' --config-env=gc.pruneExpire=PRX gc',
        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gc.pruneExpire GIT_CONFIG_VALUE_0=now ' + G + ' gc',
        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=GC.PruneExpire GIT_CONFIG_VALUE_0=now ' + G + ' gc',
        "GIT_CONFIG_PARAMETERS=\"'gc.pruneExpire'='now'\" " + G + ' gc',
        'env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gc.pruneExpire GIT_CONFIG_VALUE_0=now ' + G + ' gc',
    )

    def test_blocked_with_the_gc_message(self):
        for cmd in self.CMDS:
            with self.subTest(cmd=cmd):
                msg = self.assertBlocks(cmd)
                self.assertIn('CAST_GC_OK', msg)
                self.assertNotIn('CAST_GIT_CONFIG_OK=1', msg)

    def test_gc_hatch_still_allows_and_records_the_gc_variable(self):
        cmd = 'CAST_GC_OK=1 ' + G + ' --config-env=gc.pruneExpire=PRX gc'
        self.assertAllows(cmd)
        self.assertEqual([c.args[0] for c in self.record.call_args_list], ['CAST_GC_OK'])

    def test_gc_hatch_does_not_cover_an_exec_key_in_the_same_command(self):
        msg = self.assertBlocks('CAST_GC_OK=1 ' + G + ' -c gc.pruneExpire=now -c core.pager=x gc')
        self.assertIn('CAST_GIT_CONFIG_OK', msg)

    def test_existing_gc_messages_unchanged_for_the_old_forms(self):
        self.assertIn('CAST_GC_OK', self.assertBlocks(G + ' -c gc.pruneExpire=now gc'))
        self.assertIn('CAST_GC_OK', self.assertBlocks(CFG + ' gc.pruneExpire now'))


class TestAllowMatrix(_Base):
    def test_reads_and_removals_and_lookalikes_stay_allowed(self):
        for cmd in (
            CFG + ' --get core.pager',
            CFG + ' core.pager',
            CFG + ' --global core.pager',
            CFG + ' --get-regexp alias',
            CFG + ' --get-all include.path',
            CFG + ' get core.pager',
            CFG + ' get --all alias.x',
            CFG + ' list',
            CFG + ' -l',
            CFG + ' --list',
            CFG + ' --global --list',
            CFG + ' user.email x@example.org',
            CFG + ' --unset core.pager',
            CFG + " --unset core.pager 'x'",
            CFG + ' --unset-all alias.x',
            CFG + ' unset core.pager',
            CFG + ' --remove-section alias',
            CFG + ' remove-section alias',
            CFG + ' --rename-section alias x',
            CFG + ' rename-section alias x',
            CFG + ' --blob HEAD:f core.pager',
            G + ' -c color.ui=never log',
            G + ' -c core.quotepath=off status',
            G + ' -c user.name=x log',
            G + ' -c core.pagerx=1 status',
            G + ' --config-env=user.name=E log',
            G + ' log --grep core.pager',
            G + ' log -c core.pager',
            G + ' status',
            "rg 'core.fsmonitor' docs/",
            'echo core.pager alias.x include.path',
            "echo '" + CFG + " core.pager less'",
            # main allows a double-quoted echo payload as data too; pin whatever main does.
            'echo "' + CFG + ' core.pager less"',
            'GIT_CONFIG_GLOBAL=/dev/null ' + G + ' status',
            'GIT_CONFIG_GLOBAL="/dev/null" GIT_CONFIG_SYSTEM=/dev/null ' + G + ' status',
            'GIT_CONFIG_GLOBAL= ' + G + ' status',
            'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x ' + G + ' status',
            "GIT_CONFIG_PARAMETERS=\"'user.name'='x'\" " + G + ' status',
            "rg 'GIT_CONFIG_KEY_0=core.pager' docs",
            'GIT_CONFIG_PARAMETERS= ' + G + ' log --grep alias.x',
        ):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)
        self.assertEqual(self.record.call_count, 0)

    def test_residual_export_in_an_earlier_segment_is_not_seen(self):
        # MEASURED residual, documented in the module docstring: the engine evaluates one
        # segment at a time and the exporting segment mentions no git. If this starts BLOCKING,
        # update the docstring paragraph "Config-injection indirection" and delete this test.
        self.assertAllows('export GIT_CONFIG_KEY_0=core.pager; ' + G + ' status')


class TestHatch(_Base):
    def test_hatch_allows_and_records_exactly_once(self):
        self.assertAllows('CAST_GIT_CONFIG_OK=1 ' + CFG + ' core.pager less')
        self.assertEqual(self.record.call_count, 1)
        args = self.record.call_args.args
        self.assertEqual((args[0], args[2]), ('CAST_GIT_CONFIG_OK', 'git-config-exec'))

    def test_hatch_covers_every_route_with_one_record_each(self):
        for cmd in (
            'CAST_GIT_CONFIG_OK=1 ' + G + ' -c core.pager=less log',
            'CAST_GIT_CONFIG_OK=1 ' + G + ' --config-env=core.pager=E log',
            'CAST_GIT_CONFIG_OK=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=x ' + G + ' log',
            'CAST_GIT_CONFIG_OK=1 GIT_CONFIG_GLOBAL=/tmp/f ' + G + ' log',
            'CAST_GIT_CONFIG_OK=1 ' + CFG + ' --rename-section x alias',
            'CAST_GIT_CONFIG_OK=1 ' + CFG + ' --global alias.x "!sh"',
        ):
            self.record.reset_mock()
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)
                self.assertEqual(self.record.call_count, 1)
                self.assertEqual(self.record.call_args.args[0], 'CAST_GIT_CONFIG_OK')

    def test_hatch_value_must_be_one(self):
        self.assertBlocks('CAST_GIT_CONFIG_OK=0 ' + CFG + ' core.pager less')
        self.assertBlocks('CAST_GIT_CONFIG_OK= ' + CFG + ' core.pager less')

    def test_hatch_does_not_leak_into_another_segment(self):
        self.assertBlocks('CAST_GIT_CONFIG_OK=1 true && ' + CFG + ' core.pager less')
        self.assertBlocks('CAST_GIT_CONFIG_OK=1 ' + CFG + ' user.name x && ' + CFG + ' core.pager less')
        self.assertBlocks('CAST_GIT_CONFIG_OK=1 ' + CFG + ' core.pager less; ' + CFG + ' alias.x !sh')

    def test_hatch_does_not_open_other_guards(self):
        self.assertBlocks('CAST_GIT_CONFIG_OK=1 ' + G + ' reset --hard')
        self.assertBlocks('CAST_GIT_CONFIG_OK=1 ' + G + ' -c gc.pruneExpire=now gc')

    def test_config_edit_accepts_either_hatch_and_records_one_row(self):
        for var, op in (('CAST_GIT_CONFIG_OK', 'git-config-exec'), ('CAST_GC_OK', 'gc-config')):
            self.record.reset_mock()
            with self.subTest(hatch=var):
                self.assertAllows(var + '=1 ' + CFG + ' --edit')
                self.assertEqual(self.record.call_count, 1)
                args = self.record.call_args.args
                self.assertEqual((args[0], args[2]), (var, op))
        self.assertBlocks(CFG + ' --edit')


class TestLinear(_Base):
    """The new patterns must stay linear: a hook timeout is an ALLOW, so a slow regex is a bypass."""

    BOUND_SECS = 2.0

    def test_adversarial_runs_finish_fast(self):
        cases = {
            'flags': CFG + ' ' + '-a ' * 5000 + 'x',
            'file-flags': CFG + ' ' + '--file ' * 5000 + 'x',
            'c-opts': G + ' ' + '-c a=b ' * 3000 + 'status',
            'C-opts': G + ' ' + '-C x ' * 3000 + 'status',
            'dots': CFG + ' alias.' + 'a.' * 20000 + 'x',
            'params': 'GIT_CONFIG_PARAMETERS="' + "'a'='b' " * 3000 + '" ' + G + ' status',
            'env-keys': ' '.join('GIT_CONFIG_KEY_%d=a.b' % i for i in range(2000)) + ' ' + G + ' status',
        }
        for name, cmd in cases.items():
            t0 = time.perf_counter()
            self.verdict(cmd)
            elapsed = time.perf_counter() - t0
            self.assertLess(elapsed, self.BOUND_SECS, f'{name}: {elapsed:.2f}s on {len(cmd)} chars')


class TestSecurityRound1(_Base):
    """Security BLOCKED U6a-1 (real-git verified): read-flag lookahead bypass (F1), rename-section
    flag placement (F2), key gaps (F3), shell-expanded keys (F4), ANSI-C env values (F5)."""

    F1_WRITES = (
        CFG + ' core.editor "a --get b"',
        CFG + " alias.zz '!sh -l q'",
        CFG + ' core.askpass x --get',          # git ignores a trailing --get: stores x
        CFG + ' core.pager "sh -l x"',
        CFG + " --comment='a --get b' core.hooksPath /x",
        CFG + ' core.pager x # --get',
        CFG + ' --global alias.x "!f() { sh -l; }; f"',
        CFG + ' core.pager x --unset',
        CFG + ' core.pager x --list',
        CFG + ' core.pager x -l',
        CFG + ' core.pager x > /dev/null',
        CFG + ' --file f --comment c core.pager x',
        CFG + ' --type bool core.fsmonitor true',
    )

    def test_f1_read_looking_token_in_a_value_or_after_the_key_is_still_a_write(self):
        for cmd in self.F1_WRITES:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_f1_real_flags_in_the_option_region_still_read_or_remove(self):
        for cmd in (CFG + ' --get core.pager', CFG + ' --get core.pager x', CFG + ' --global --get-all alias.x',
                    CFG + ' --get-regexp alias', CFG + ' --unset core.pager x', CFG + ' --unset-all alias.x',
                    CFG + ' --file f --get core.pager', CFG + ' -f f --list', CFG + ' --remove-section alias',
                    CFG + ' --global -l', CFG + ' core.pager', CFG + ' core.pager 2>/dev/null',
                    CFG + ' --get core.pager >/dev/null 2>&1', CFG + ' get core.pager', CFG + ' list',
                    CFG + ' unset core.pager', CFG + ' remove-section alias'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_f1_unparseable_git_config_naming_an_exec_key_fails_closed(self):
        self.assertBlocks(CFG + " core.pager 'x")
        self.assertBlocks(CFG + ' alias.x "!sh')
        self.assertAllows(CFG + " user.name 'x")

    F2_RENAMES = (
        CFG + ' --rename-section --local foo core',
        CFG + ' --rename-section user --global core',
        CFG + ' --rename-section -f x user core',
        CFG + ' rename-section --global user core',
        CFG + ' --rename-section --file x user alias',
        CFG + ' --global --rename-section user core',
        CFG + ' rename-section -f x user filter.lfs',
    )

    def test_f2_rename_section_flag_placement(self):
        for cmd in self.F2_RENAMES:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)
        for cmd in (CFG + ' --rename-section --local foo bar', CFG + ' --rename-section -f x user mine',
                    CFG + ' rename-section --global user mine', CFG + ' --rename-section core user'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_f3_additional_exec_keys(self):
        for key in ('imap.tunnel', 'man.m.path', 'instaweb.httpd', 'instaweb.browser', 'help.browser',
                    'guitool.g.cmd', 'trailer.t.command', 'sendemail.id.smtpServer', 'sendemail.id.toCmd'):
            for form in (CFG + ' @K@ x', G + ' -c @K@=x log', 'GIT_CONFIG_KEY_0=@K@ ' + G + ' log'):
                cmd = form.replace('@K@', key)
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_f4_shell_expanded_keys_block(self):
        for cmd in ('K=core.pager; ' + CFG + ' $K x', CFG + ' "$K" x', CFG + ' core.pa{g,}er x',
                    CFG + ' $(echo core.pager) x', G + ' -c $K=x log', G + ' -c "$K=x" log',
                    CFG + ' `echo core.pager` x', CFG + ' ${K} x', G + ' --config-env=$K=E log',
                    G + ' --config-env $K=E log', G + ' -c core.pa{g,}er=x log', CFG + ' --global "$K" x'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_f4_literal_and_value_dollars_stay_allowed(self):
        for cmd in (CFG + " '$K' x", CFG + ' user.name "$NAME"', CFG + ' user.name $NAME',
                    G + ' -c user.name="$NAME" log', G + ' -c color.ui=$X log',
                    CFG + ' --get $K', CFG + ' user.email "a{b,c}"', G + " -c '$K=x' log"):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_f5_ansi_c_quoting_in_env_values(self):
        for cmd in ("GIT_CONFIG_KEY_0=$'core.pager' " + G + ' log',
                    "GIT_CONFIG_KEY_0=$'core\\x2epager' " + G + ' log',
                    "GIT_CONFIG_PARAMETERS=$'\\'core.pager\\'=\\'x\\'' " + G + ' log',
                    "GIT_CONFIG_KEY_0=$'gc.pruneExpire' " + G + ' gc',
                    "GIT_CONFIG_GLOBAL=$'/tmp/evil' " + G + ' status',
                    CFG + " $'core.pager' x"):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)
        self.assertAllows("GIT_CONFIG_KEY_0=$'user.name' " + G + ' status')
        self.assertAllows("GIT_CONFIG_GLOBAL=$'/dev/null' " + G + ' status')

    def test_nit_global_dev_null_allowed_and_edit_message_names_both_hatches(self):
        self.assertAllows('GIT_CONFIG_GLOBAL=/dev/null ' + G + ' status')
        msg = self.assertBlocks(CFG + ' --edit')
        self.assertIn('EITHER', msg)


class TestSecurityRound2(_Base):
    """Security round 2: structural fail-closed (N1 quoted redirection-lookalikes, N2 option parser
    not modelled, unquoted globs) plus the pinned residual and the accepted over-blocks."""

    N1 = (
        CFG + " core.pager '>/dev/null v'", CFG + " core.pager '<v'", CFG + " core.pager '2>/dev/null v'",
        CFG + ' core.pager "&>/dev/null v"', CFG + " --local core.pager '>x v'", CFG + " core.pager '>' v",
        CFG + ' core.pager \\>x', CFG + " core.hooksPath '2>' x",
    )
    N2 = (
        CFG + ' --fil .git/config core.pager v', CFG + ' --com c core.pager v',
        CFG + ' --comm c core.pager v', CFG + ' --ty bool core.fsmonitor true',
        CFG + ' --bl HEAD:f core.pager v', CFG + ' --def d core.pager v',
        CFG + ' -zf .git/config core.pager v', CFG + ' --$E core.pager v', CFG + ' --${E} core.pager v',
        CFG + ' --$E $K v', CFG + ' -fz x core.pager v', CFG + ' --rename-sec user core',
        CFG + ' --rename-section --$E user core',
        # an abbreviated / bundled / dynamic VALUE-taker swallows a read-looking token as its value,
        # so the "read flag" is really a file name and the rest is a write
        CFG + ' --fil --get core.pager v', CFG + ' -zf --list core.pager v',
        CFG + ' --$E --unset core.pager v', CFG + ' --comm --get-all alias.x v',
    )
    GLOBS = (
        CFG + ' core.pag?r v', CFG + ' core.pa[g]er v', CFG + ' core.p* v', CFG + ' alias.* v',
        CFG + ' --global core.pa?er v', G + ' -c core.pa?er=v log', CFG + ' set core.pa[g]er v',
    )

    def test_n1_quoted_redirection_lookalikes_are_operands(self):
        for cmd in self.N1:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_n2_option_region_not_exactly_parsed_fails_closed(self):
        for cmd in self.N2:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_unquoted_globs_in_key_position_block(self):
        for cmd in self.GLOBS:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_unquoted_redirections_are_still_dropped(self):
        for cmd in (CFG + ' core.pager 2>/dev/null', CFG + ' core.pager >/dev/null 2>&1',
                    CFG + ' core.pager > f', CFG + ' --get core.pager &>/dev/null',
                    CFG + ' core.pager < f'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)
        self.assertBlocks(CFG + ' core.pager x 2>&1')

    def test_allow_fences_for_exact_reads_and_ordinary_writes(self):
        for cmd in (CFG + ' user.email x@example.org', CFG + ' init.defaultBranch main',
                    CFG + " --get-regexp '^alias\\.'", CFG + ' --list --show-origin',
                    CFG + ' pull.rebase true', CFG + " --global --add safe.directory '*'",
                    CFG + ' get --all alias.x', CFG + ' unset core.pager', CFG + ' remove-section alias',
                    CFG + ' --global --unset-all alias.x', CFG + ' --file f --get-all include.path',
                    CFG + ' --get-regexp alias.*', CFG + ' --get core.pa?er', CFG + ' core.pager',
                    CFG + ' --global user.name "$NAME"', CFG + ' --file=f user.name x',
                    CFG + ' --type=bool core.bare false', CFG + ' --rename-section alias user',
                    'GIT_CONFIG_GLOBAL=/dev/null ' + G + ' status'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_accepted_over_blocks_are_hatchable(self):
        # A value that is literally an exec key cannot be told from the key without modelling
        # git exactly: blocked, and CAST_GIT_CONFIG_OK=1 is the way through.
        for cmd in (CFG + ' user.name "core.pager"', CFG + ' --global user.name x core.pager'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)
                self.assertAllows('CAST_GIT_CONFIG_OK=1 ' + cmd)

    def test_accepted_residual_dynamic_git_command_word_is_not_seen(self):
        # Same limit as the rest of the module (documented in `_exec_config_cmd_blocks`' block comment).
        for cmd in ('C=config; ' + G + ' $C core.pager v', 'G=' + G + '; $G config core.pager v',
                    G + ' $C core.pager v'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)


class TestSecurityRound3(_Base):
    """Security round 3: a word-splitting sole operand is key + value (R3-1), help.autocorrect
    (R3-2), `clone -c/--config/--template` persist into the new repo (R3-3)."""

    R31 = (
        "KV='core.pager v'; " + CFG + ' $KV', CFG + ' --global $KV', CFG + ' $KV',
        'set -- core.pager v; ' + CFG + ' "$@"', CFG + ' --global $@', CFG + ' "$@"', CFG + ' $*',
        CFG + ' "$*"', CFG + ' "${@}"', CFG + ' ${KV}', CFG + ' $(echo core.pager v)',
        CFG + ' `echo core.pager v`', CFG + ' core.pa{g,}er', CFG + ' --local $KV',
    )

    def test_r31_a_word_splitting_sole_operand_is_a_possible_write(self):
        for cmd in self.R31:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_r31_single_quoted_dollar_and_exact_reads_stay_allowed(self):
        for cmd in (CFG + ' "$KV"', CFG + " '$KV'", CFG + ' --get $KV', CFG + ' --get-regexp $P',
                    CFG + ' get $KV', CFG + ' --unset $KV', CFG + ' user.name $NAME',
                    CFG + ' user.name "$@"', CFG + ' user.name "$KV"', CFG + ' --list'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_r32_help_autocorrect_is_an_exec_key(self):
        for form in (CFG + ' @K@ immediate', G + ' -c @K@=immediate status',
                     'GIT_CONFIG_KEY_0=@K@ ' + G + ' status', CFG + ' --global @K@ 1'):
            with self.subTest(form=form):
                self.assertBlocks(form.replace('@K@', 'help.autocorrect'))

    def test_r32_accepted_residual_autocorrected_subcommand_is_not_seen(self):
        # A user's OWN ~/.gitconfig help.autocorrect (or a pre-existing alias) turns a typo into
        # `config`; the guard sees only the typed word: same class as the dynamic command word.
        self.assertAllows(G + ' confg core.pager v')
        self.assertAllows(G + ' cfg core.pager v')

    CLONE_BLOCK = (
        G + ' clone -c core.fsmonitor=X https://h/r', G + ' clone --config core.pager=X https://h/r',
        G + ' clone --config=core.pager=X https://h/r', G + ' clone -ccore.pager=X https://h/r',
        G + ' clone https://h/r -c alias.x=!sh d', G + ' clone -qc core.hooksPath=/x https://h/r',
        G + ' clone --conf core.pager=X https://h/r', G + ' clone --conf=core.pager=X https://h/r',
        G + ' clone -c "$K" https://h/r', G + ' clone --config=$K=x https://h/r',
        G + ' clone -c Core.FsMonitor=x https://h/r', G + ' -C /x clone -c core.pager=x u',
        G + " clone -c 'filter.f.smudge=sh' u", G + ' clone -c core.fsmonitor u',
        G + ' clone --template=/tmp/t https://h/r', G + ' clone --template /tmp/t https://h/r',
        G + ' init --template=/tmp/t', G + ' init --template /tmp/t d', G + ' clone --tem=/t u',
        G + ' init --templ /t',
    )
    CLONE_ALLOW = (
        G + ' clone https://h/r', G + ' clone -c user.name=x https://h/r',
        G + ' clone --config user.email=x@example.org https://h/r', G + ' clone -c core.quotepath=off u d',
        G + ' clone --depth 1 -b main -o up https://h/r', G + ' clone --no-template u',
        G + ' init', G + ' init -q d', G + ' init --bare d', G + ' init --initial-branch=main',
        G + ' clone -c color.ui=never -c user.name=x u',
    )

    def test_r33_clone_config_and_template_block(self):
        for cmd in self.CLONE_BLOCK:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_r33_ordinary_clone_and_init_stay_allowed(self):
        for cmd in self.CLONE_ALLOW:
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_r33_hatch_allows_clone_config(self):
        self.assertAllows('CAST_GIT_CONFIG_OK=1 ' + G + ' clone -c core.pager=x u')
        self.assertEqual(self.record.call_args.args[0], 'CAST_GIT_CONFIG_OK')

    def test_r33_accepted_residual_program_flags_are_one_shot(self):
        # CLI flags that run a program ONE-SHOT at the agent's own privilege (no persistence):
        # not chased, same limit as the rest of the module. `ext::` is off by default
        # (protocol.allow), and persisting `protocol.ext.allow` IS blocked above.
        for cmd in (G + ' fetch --upload-pack=/x/p origin', G + ' clone -u /x/p https://h/r',
                    G + ' clone --upload-pack /x/p https://h/r', G + " clone 'ext::sh -c x' d"):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)


class TestSecurityRound4(_Base):
    """Security round 4: git's own shell-exec carriers hand a STRING to a shell (R4-1) - the carried
    command is judged by the whole engine like a `bash -c` operand; unique-prefix abbreviations of
    `--template` / `--config` come from the real option tables, not a length threshold (R4-2)."""

    WRITE = CFG + ' core.pager FE1'
    CARRIERS = (
        G + " submodule foreach '@C@'", G + " submodule foreach --recursive '@C@'",
        G + " submodule --quiet foreach --quiet --recursive '@C@'", G + ' submodule foreach "@C@"',
        G + " rebase -x '@C@' --root", G + " rebase --exec='@C@' main", G + " rebase --exec '@C@' main",
        G + " rebase -i -x '@C@' main", G + " rebase -ix '@C@' main", G + " rebase -x'@C@' main",
        G + " rebase --exe '@C@' main", G + " rebase main -x '@C@'",
        G + " difftool -x '@C@'", G + " difftool --extcmd='@C@'", G + " difftool --extcmd '@C@'",
        G + " difftool --ext='@C@'", G + " -C /x submodule foreach '@C@'",
        G + " bisect run @C@", G + " bisect run sh -c '@C@'", G + " --no-pager rebase -x '@C@' HEAD~1",
        'FOO=1 ' + G + " submodule foreach '@C@'",
    )

    def test_r41_carried_exec_config_write_blocks(self):
        for tpl in self.CARRIERS:
            cmd = tpl.replace('@C@', self.WRITE)
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_r41_carried_push_and_reset_still_block_by_every_check(self):
        for payload in (G + ' push origin main', G + ' reset --hard', G + ' commit -m x',
                        G + ' -c core.pager=x log', 'GIT_CONFIG_GLOBAL=/tmp/e ' + G + ' status'):
            for tpl in self.CARRIERS[:8]:
                cmd = tpl.replace('@C@', payload)
                with self.subTest(cmd=cmd):
                    self.assertBlocks(cmd)

    def test_r41_ordinary_carried_commands_stay_allowed(self):
        for payload in ('echo hi', 'make test', G + ' status', G + ' config --get core.pager',
                        G + ' config user.name x', G + ' log --oneline', 'npm test -- --watch=false'):
            for tpl in self.CARRIERS:
                if tpl.startswith(G + ' bisect run @C@'):
                    continue
                cmd = tpl.replace('@C@', payload)
                with self.subTest(cmd=cmd):
                    self.assertAllows(cmd)
        for cmd in (G + ' submodule update --init', G + ' rebase main', G + ' rebase -i HEAD~3',
                    G + ' difftool -t vimdiff', G + ' difftool --tool=meld', G + ' bisect start',
                    G + ' bisect run make', G + ' submodule status', G + " rebase -s ours main",
                    G + " rebase --strategy-option=theirs main"):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_r41_hatch_inside_the_carried_string_is_honoured_like_a_direct_command(self):
        self.assertAllows(G + " submodule foreach 'CAST_GIT_CONFIG_OK=1 " + self.WRITE + "'")
        self.assertBlocks('CAST_GIT_CONFIG_OK=1 ' + G + " submodule foreach '" + self.WRITE + "'")

    def test_r41_unreadable_carrier_fails_closed(self):
        self.assertBlocks(G + " submodule foreach '" + self.WRITE)
        self.assertBlocks(G + " rebase -x '" + self.WRITE + ' main')

    def test_r42_unique_prefix_abbreviations_of_template_and_config(self):
        for cmd in (G + ' init --t=/x ../d', G + ' init --t /x', G + ' init --te /x', G + ' init --tem=/x d',
                    G + ' init --templat=/x', G + ' clone --t=/x u', G + ' clone --t /x u',
                    G + ' clone --te /x u', G + ' clone --co core.pager=x u', G + ' clone --c core.pager=x u',
                    G + ' clone --conf=core.pager=x u', G + ' clone --confi core.hooksPath=/x u',
                    G + ' init --template /x'):
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_r42_other_abbreviations_and_negations_stay_allowed(self):
        for cmd in (G + ' init --b d', G + ' init --bar d', G + ' init --in=main', G + ' init --q',
                    G + ' init --no-template', G + ' clone --no-template u', G + ' clone --dep 1 u',
                    G + ' clone --bra main u', G + ' clone --ta u', G + ' clone --sh u',
                    G + ' clone --no-checkout u', G + ' clone --no-c u', G + ' clone --rec u',
                    G + ' clone --config user.name=x u', G + ' clone --co user.name=x u'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)


if __name__ == '__main__':
    unittest.main()
