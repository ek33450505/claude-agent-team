#!/usr/bin/env python3
"""Unit G (U6a-2 + git-guard parts of U6c) for scripts/cast-git-guard.py.

U6a-2 (probed hazard E1, 2026-10-04): `git gc` runs `git worktree prune`, which follows an
agent-planted SYMLINKED `.git/worktrees/<id>` entry and EMPTIES its target (`gc.worktreePruneExpire=
never` does NOT stop it). Pinned here:

  * `git worktree prune` (any flags except `-n` / `--dry-run`), every `git gc` form and `git
    maintenance run` (any task) BLOCK; dry-run forms and look-alikes stay allowed; hatches:
    CAST_WORKTREE_OK=1 for the worktree prune, CAST_GC_OK=1 for gc / maintenance;
  * the stateful check: ANY git invocation whose repository has a `worktrees/*` entry that is a
    symlink (or whose `gitdir` file is a symlink, or whose `worktrees` dir itself is a symlink)
    BLOCKS, resolved from the cwd / `-C` / `--git-dir=` / `GIT_DIR=` / a linked worktree's `.git`
    file; unreadable dirs fail OPEN (git, same uid, cannot traverse them either), an over-cap dir
    fails CLOSED; it costs well under a millisecond on a realistic repo.

U6c: an installed policies.json with zero `block` policies ({} / {"policies": []} / all warn) is
INVALID (fail closed like a missing file); `_hatch_value` no longer re-tokenizes a whole hatched
segment (2 x 195 KB hatched segments tripped the 2 s watchdog); `git grep -O<cmd>` is a pinned
ALLOW (accepted residual).

The verb is assembled (`G`) so no literal guarded command sits in this file. Scratch git repos live
under a temp dir with HOME redirected; `_record_hatch` is mocked. Hyphenated module via importlib.
"""
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO = Path(__file__).parent.parent

_spec = importlib.util.spec_from_file_location(
    'cast_git_guard_worktree_prune', str(_REPO / 'scripts' / 'cast-git-guard.py'))
gg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gg)

G = 'gi' + 't'
SESS = 'unit-g-session'


class _Base(unittest.TestCase):
    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix='cast-unitg-home-'))
        self.addCleanup(shutil.rmtree, self.home, True)
        env = mock.patch.dict(os.environ, {'HOME': self.home})
        env.start()
        self.addCleanup(env.stop)
        for k in ('CAST_GC_OK', 'CAST_WORKTREE_OK', 'CAST_POLICY_OVERRIDE', 'GIT_DIR',
                  'GIT_COMMON_DIR', 'CLAUDE_SUBPROCESS'):
            os.environ.pop(k, None)
        rec = mock.patch.object(gg, '_record_hatch')
        self.rec = rec.start()
        self.addCleanup(rec.stop)

    def verdict(self, cmd):
        return gg._git_evaluate(cmd)

    def assertBlocks(self, cmd, needle=None):
        code, msg = self.verdict(cmd)
        self.assertEqual(code, 2, f'expected BLOCK, got allow: {cmd!r}')
        if needle:
            self.assertIn(needle, msg)
        return msg

    def assertAllows(self, cmd):
        code, msg = self.verdict(cmd)
        self.assertEqual(code, 0, f'expected ALLOW, got block ({msg!r}): {cmd!r}')


class TestWorktreePruneGcMaintenanceBlocks(_Base):
    BLOCKED = (
        G + ' worktree prune',
        G + ' worktree prune -v',
        G + ' worktree prune --verbose',
        G + ' worktree prune --expire=now',
        G + ' worktree prune --expire now',
        G + ' -C /some/dir worktree prune',
        G + ' --no-pager worktree prune',
        "'" + G + "' 'worktree' 'prune'",
        'cd /x && ' + G + ' worktree prune',
        G + ' worktree prune -n; ' + G + ' worktree prune',
        G + ' gc',
        G + ' gc --aggressive',
        G + ' gc --auto',
        G + ' gc --no-prune',
        G + ' gc --prune',
        G + ' gc --quiet',
        G + ' -C /some/dir gc',
        G + ' -c gc.auto=0 gc',
        "'" + G + "' 'gc'",
        'echo hi && ' + G + ' gc',
        G + ' maintenance run',
        G + ' maintenance run --auto',
        G + ' maintenance run --task=gc',
        G + ' maintenance run --task=commit-graph',
        G + ' maintenance run --task=worktree-prune --task=gc',
        G + ' maintenance run --schedule=daily',
        G + ' -C /some/dir maintenance run',
    )
    ALLOWED = (
        G + ' worktree prune -n',
        G + ' worktree prune --dry-run',
        G + ' worktree prune -nv',
        G + ' worktree prune --dry-run --verbose',
        G + ' worktree list',
        G + ' worktree add ../x -b y',
        G + ' worktree lock x',
        G + ' gcfoo',
        G + ' gc-thing',
        G + ' maintenance start',
        G + ' maintenance register',
        G + ' maintenance unregister',
        G + ' maintenance stop',
        G + ' maintenancerun',
        G + ' status',
        G + ' log --oneline',
    )

    def test_blocked_forms(self):
        for cmd in self.BLOCKED:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_allowed_forms(self):
        for cmd in self.ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_messages_explain_the_hazard_and_name_the_hatch(self):
        m = self.assertBlocks(G + ' worktree prune', 'CAST_WORKTREE_OK=1')
        self.assertIn('symlink', m.lower())
        m = self.assertBlocks(G + ' gc', 'CAST_GC_OK=1')
        self.assertIn('worktree prune', m)
        m = self.assertBlocks(G + ' maintenance run', 'CAST_GC_OK=1')
        self.assertIn('symlink', m.lower())

    def test_worktree_prune_hatch_allows_and_records_once(self):
        self.assertAllows('CAST_WORKTREE_OK=1 ' + G + ' worktree prune')
        self.assertEqual(self.rec.call_count, 1)
        self.assertEqual(self.rec.call_args[0][0], 'CAST_WORKTREE_OK')

    def test_gc_hatch_allows_and_records_once(self):
        for cmd in ('CAST_GC_OK=1 ' + G + ' gc', 'CAST_GC_OK=1 ' + G + ' gc --auto',
                    'CAST_GC_OK=1 ' + G + ' maintenance run --task=gc'):
            with self.subTest(cmd=cmd):
                self.rec.reset_mock()
                self.assertAllows(cmd)
                self.assertEqual(self.rec.call_count, 1)
                self.assertEqual(self.rec.call_args[0][0], 'CAST_GC_OK')

    def test_the_wrong_hatch_does_not_unlock(self):
        self.assertBlocks('CAST_GC_OK=1 ' + G + ' worktree prune')
        self.assertBlocks('CAST_WORKTREE_OK=1 ' + G + ' gc')
        self.assertBlocks('CAST_PRUNE_OK=1 ' + G + ' maintenance run')

    def test_a_hatch_is_scoped_to_its_own_segment(self):
        self.assertBlocks('CAST_GC_OK=1 ' + G + ' gc && ' + G + ' maintenance run')
        self.assertBlocks('CAST_WORKTREE_OK=1 ' + G + ' worktree prune && ' + G + ' gc')

    def test_gc_prune_value_keeps_its_own_message(self):
        # `--prune=<value>` was already blocked; the specific message must not regress.
        self.assertBlocks(G + ' gc --prune=now', '--prune=<value>')

    def test_unrelated_prune_forms_unchanged(self):
        self.assertBlocks(G + ' prune')
        self.assertAllows(G + ' prune -n')
        self.assertAllows(G + ' prune-packed')
        self.assertAllows(G + ' remote prune origin')


class _Repo(_Base):
    """A scratch repo (real `git init`) under a temp dir, no network, HOME = scratch."""

    def setUp(self):
        super().setUp()
        self.root = os.path.realpath(tempfile.mkdtemp(prefix='cast-unitg-repo-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.repo = os.path.join(self.root, 'repo')
        self.git_env = dict(os.environ, HOME=self.home, GIT_CONFIG_NOSYSTEM='1',
                            GIT_CONFIG_GLOBAL=os.devnull)
        self.sh(['init', '-q', self.repo])
        self.common = os.path.join(self.repo, '.git')
        self.victim = os.path.join(self.root, 'victim')
        os.makedirs(self.victim)
        Path(self.victim, 'precious.txt').write_text('keep me\n')

    def sh(self, args, cwd=None):
        subprocess.run(['git'] + args, cwd=cwd, env=self.git_env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def plant_symlink_entry(self, name='evil'):
        wt = os.path.join(self.common, 'worktrees')
        os.makedirs(wt, exist_ok=True)
        os.symlink(self.victim, os.path.join(wt, name))

    def plant_real_entry(self, name='ok', gitdir_symlink=False):
        d = os.path.join(self.common, 'worktrees', name)
        os.makedirs(d)
        if gitdir_symlink:
            os.symlink(os.path.join(self.victim, 'precious.txt'), os.path.join(d, 'gitdir'))
        else:
            Path(d, 'gitdir').write_text(os.path.join(self.root, name, '.git') + '\n')
        return d


class TestSymlinkedWorktreeEntryBlocksAnyGit(_Repo):
    def test_baseline_clean_repo_allows(self):
        self.assertAllows(G + ' -C ' + self.repo + ' status')
        self.assertAllows(G + ' -C ' + self.repo + ' log --oneline')

    def test_symlinked_entry_blocks_via_dash_C(self):
        self.plant_symlink_entry()
        for sub in ('status', 'log --oneline', 'diff', 'worktree list', 'rev-parse HEAD',
                    'branch', 'add -A', 'fetch origin'):
            with self.subTest(sub=sub):
                msg = self.assertBlocks(G + ' -C ' + self.repo + ' ' + sub)
                self.assertIn('SYMLINK', msg)
                self.assertIn('worktrees/evil', msg)

    def test_message_explains_hazard_and_removal(self):
        self.plant_symlink_entry()
        msg = self.assertBlocks(G + ' -C ' + self.repo + ' status')
        self.assertIn('EMPTIES', msg)
        self.assertIn('unlink', msg)          # how to remove the entry without following it
        self.assertIn('CAST_WORKTREE_OK=1', msg)

    def test_symlinked_entry_blocks_via_cwd_and_subdirectory(self):
        self.plant_symlink_entry()
        sub = os.path.join(self.repo, 'a', 'b')
        os.makedirs(sub)
        for cwd in (self.repo, sub):
            with self.subTest(cwd=cwd):
                with mock.patch('os.getcwd', return_value=cwd):
                    self.assertBlocks(G + ' status')

    def test_relative_dash_C_resolved_against_cwd(self):
        self.plant_symlink_entry()
        with mock.patch('os.getcwd', return_value=self.root):
            self.assertBlocks(G + ' -C repo status')
            self.assertBlocks(G + ' -C ./repo/ status')
            self.assertAllows(G + ' -C victim --version')  # not a repo: no entries to find

    def test_nested_dash_C_chain(self):
        self.plant_symlink_entry()
        with mock.patch('os.getcwd', return_value=self.root):
            self.assertBlocks(G + ' -C . -C repo status')

    def test_git_dir_forms(self):
        self.plant_symlink_entry()
        with mock.patch('os.getcwd', return_value=self.victim):
            self.assertBlocks(G + ' --git-dir=' + self.common + ' status')
            self.assertBlocks('GIT_DIR=' + self.common + ' ' + G + ' status')

    def test_quoted_spelling_is_still_a_git_invocation(self):
        self.plant_symlink_entry()
        self.assertBlocks("'" + G + "' -C " + self.repo + ' status')
        self.assertBlocks(G + ' -C "' + self.repo + '" status')

    def test_chained_segments_each_checked(self):
        self.plant_symlink_entry()
        self.assertBlocks('echo hi && ' + G + ' -C ' + self.repo + ' status')

    def test_gitdir_file_symlink_inside_a_real_entry_blocks(self):
        self.plant_real_entry(gitdir_symlink=True)
        self.assertBlocks(G + ' -C ' + self.repo + ' status', 'gitdir')

    def test_real_entry_with_regular_gitdir_allows(self):
        self.plant_real_entry()
        self.assertAllows(G + ' -C ' + self.repo + ' status')

    def test_worktrees_dir_itself_a_symlink_blocks(self):
        os.symlink(self.victim, os.path.join(self.common, 'worktrees'))
        self.assertBlocks(G + ' -C ' + self.repo + ' status', 'worktrees')

    def test_dangling_symlink_entry_blocks(self):
        wt = os.path.join(self.common, 'worktrees')
        os.makedirs(wt)
        os.symlink(os.path.join(self.root, 'does-not-exist'), os.path.join(wt, 'dangling'))
        self.assertBlocks(G + ' -C ' + self.repo + ' status')

    def test_linked_worktree_resolves_to_the_common_dir(self):
        Path(self.repo, 'f').write_text('x')
        self.sh(['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'add', 'f'], cwd=self.repo)
        self.sh(['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'i'],
                cwd=self.repo)
        linked = os.path.join(self.root, 'linked')
        self.sh(['worktree', 'add', '-q', linked, '-b', 'side'], cwd=self.repo)
        self.assertTrue(os.path.isfile(os.path.join(linked, '.git')))     # `.git` is a FILE here
        self.assertAllows(G + ' -C ' + linked + ' status')                # real entry: fine
        self.plant_symlink_entry('evil')
        self.assertBlocks(G + ' -C ' + linked + ' status', 'worktrees/evil')

    def test_bare_repo(self):
        bare = os.path.join(self.root, 'bare.git')
        self.sh(['init', '-q', '--bare', bare])
        os.makedirs(os.path.join(bare, 'worktrees'))
        os.symlink(self.victim, os.path.join(bare, 'worktrees', 'evil'))
        self.assertBlocks(G + ' -C ' + bare + ' log')

    def test_hatch_allows_and_records_once(self):
        self.plant_symlink_entry()
        self.assertAllows('CAST_WORKTREE_OK=1 ' + G + ' -C ' + self.repo + ' status')
        self.assertEqual(self.rec.call_count, 1)
        self.assertEqual(self.rec.call_args[0][0], 'CAST_WORKTREE_OK')

    def test_hatch_is_scoped_to_its_own_segment(self):
        self.plant_symlink_entry()
        self.assertBlocks('CAST_WORKTREE_OK=1 ' + G + ' -C ' + self.repo + ' status && '
                          + G + ' -C ' + self.repo + ' log')

    def test_hatch_on_the_stateful_check_does_not_unlock_gc(self):
        self.plant_symlink_entry()
        self.assertBlocks('CAST_WORKTREE_OK=1 ' + G + ' -C ' + self.repo + ' gc')

    def test_non_git_commands_and_other_repos_unaffected(self):
        self.plant_symlink_entry()
        self.assertAllows('ls -C ' + self.repo)
        self.assertAllows('echo ' + G + ' status')
        other = os.path.join(self.root, 'other')
        self.sh(['init', '-q', other])
        self.assertAllows(G + ' -C ' + other + ' status')

    def test_unlinking_the_entry_restores_access(self):
        self.plant_symlink_entry()
        self.assertBlocks(G + ' -C ' + self.repo + ' status')
        os.unlink(os.path.join(self.common, 'worktrees', 'evil'))
        self.assertAllows(G + ' -C ' + self.repo + ' status')
        self.assertTrue(os.path.isfile(os.path.join(self.victim, 'precious.txt')))

    def test_no_worktrees_dir_allows(self):
        self.assertFalse(os.path.exists(os.path.join(self.common, 'worktrees')))
        self.assertAllows(G + ' -C ' + self.repo + ' status')

    def test_not_a_repo_allows(self):
        self.assertAllows(G + ' -C ' + self.victim + ' status')

    @unittest.skipIf(os.geteuid() == 0, 'chmod 000 does not restrict root')
    def test_unreadable_worktrees_dir_fails_open(self):
        # git (same uid) cannot traverse it either, so there is nothing it could prune through.
        wt = os.path.join(self.common, 'worktrees')
        os.makedirs(wt)
        os.symlink(self.victim, os.path.join(wt, 'evil'))
        os.chmod(wt, 0)
        self.addCleanup(os.chmod, wt, 0o755)
        self.assertAllows(G + ' -C ' + self.repo + ' status')

    def test_over_cap_fails_closed(self):
        wt = os.path.join(self.common, 'worktrees')
        os.makedirs(wt)
        for i in range(gg._MAX_WORKTREE_ENTRIES + 1):
            os.mkdir(os.path.join(wt, f'e{i}'))
        msg = self.assertBlocks(G + ' -C ' + self.repo + ' status')
        self.assertIn(str(gg._MAX_WORKTREE_ENTRIES), msg)

    def test_at_cap_with_only_real_entries_allows(self):
        wt = os.path.join(self.common, 'worktrees')
        os.makedirs(wt)
        for i in range(gg._MAX_WORKTREE_ENTRIES):
            os.mkdir(os.path.join(wt, f'e{i}'))
        self.assertAllows(G + ' -C ' + self.repo + ' status')

    def test_a_check_spawns_no_subprocess(self):
        self.plant_symlink_entry()
        with mock.patch.object(gg.subprocess, 'run', side_effect=AssertionError('spawned')):
            self.assertBlocks(G + ' -C ' + self.repo + ' status')

    def test_latency_on_a_realistic_and_a_large_repo(self):
        for i in range(20):
            self.plant_real_entry(f'w{i}')
        cmd = G + ' -C ' + self.repo + ' status'
        t0 = time.perf_counter()
        for _ in range(200):
            self.assertAllows(cmd)
        per_call = (time.perf_counter() - t0) / 200
        self.assertLess(per_call, 0.02, f'{per_call * 1000:.2f} ms per evaluation')
        # at the cap (every entry needs its `gitdir` lstat): still a few ms
        for i in range(20, gg._MAX_WORKTREE_ENTRIES):
            self.plant_real_entry(f'w{i}')
        t0 = time.perf_counter()
        for _ in range(20):
            self.assertAllows(cmd)
        per_call = (time.perf_counter() - t0) / 20
        self.assertLess(per_call, 0.1, f'{per_call * 1000:.2f} ms per evaluation at the cap')

    def test_result_is_memoised_within_one_evaluation(self):
        self.plant_symlink_entry()
        # 50 git segments, same repo: the entries are listed once, not 50 times.
        real = os.scandir
        calls = []

        def counting(path):
            calls.append(path)
            return real(path)
        cmd = ' && '.join([G + ' -C ' + self.repo + ' status'] * 1)
        with mock.patch.object(gg.os, 'scandir', side_effect=counting):
            gg._git_evaluate('echo a; ' + '; '.join(
                ['CAST_WORKTREE_OK=1 ' + G + ' -C ' + self.repo + ' status'] * 50))
        self.assertLessEqual(len(calls), 1, calls)
        self.assertTrue(cmd)


class TestEmptyInstalledPoliciesFailClosed(_Base):
    def install(self, content):
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg, exist_ok=True)
        Path(cfg, 'policies.json').write_text(content if isinstance(content, str) else json.dumps(content))

    def edit(self):
        return gg.evaluate('Write', {'file_path': os.path.join(self.home, 'proj', 'a.txt')}, SESS)

    def audit_ids(self):
        p = os.path.join(self.home, '.claude', 'logs', 'audit.jsonl')
        if not os.path.isfile(p):
            return []
        return [json.loads(line)['policy_id'] for line in Path(p).read_text().splitlines() if line]

    EMPTY_SHAPES = (
        {},
        {'policies': []},
        {'policies': [{'id': 'w', 'severity': 'warn', 'path_pattern': 'x', 'description': 'd'}]},
        {'version': 1},
        {'policies': [{'id': 'w1', 'severity': 'warn'}, {'id': 'w2', 'severity': 'warn'}]},
    )

    def test_empty_and_warn_only_configs_block(self):
        for shape in self.EMPTY_SHAPES:
            with self.subTest(shape=shape):
                self.install(shape)
                code, msg = self.edit()
                self.assertEqual(code, 2, msg)
                self.assertIn('[CAST-POLICY-BLOCK]', msg)
                self.assertIn('bash install.sh', msg)
                self.assertIn('CAST_POLICY_OVERRIDE=1', msg)

    def test_override_allows_and_audits(self):
        for shape in ({}, {'policies': []}):
            self.install(shape)
            with mock.patch.dict(os.environ, {'CAST_POLICY_OVERRIDE': '1'}):
                self.assertEqual(self.edit()[0], 0)
        self.assertEqual(self.audit_ids(), ['policies-config-invalid'] * 2)

    def test_one_block_policy_is_valid_and_enforced(self):
        self.install({'policies': [
            {'id': 'w', 'severity': 'warn'},
            {'id': 'b', 'severity': 'block', 'path_pattern': r'a\.txt$',
             'description': 'd', 'requires_agent': 'security'}]})
        code, msg = self.edit()
        self.assertEqual(code, 2)
        self.assertIn('Policy "b" blocks this edit', msg)
        self.assertNotIn('bash install.sh', msg)

    def test_real_policies_json_still_loads(self):
        cfg = os.path.join(self.home, '.claude', 'config')
        os.makedirs(cfg)
        shutil.copy(str(_REPO / 'config' / 'policies.json'), os.path.join(cfg, 'policies.json'))
        code, msg = self.edit()
        self.assertEqual((code, msg), (0, ''))   # an ordinary file is allowed, config is valid


class TestHatchValueDoesNotRetokenizeTheSegment(_Base):
    def count_tokens(self, cmd):
        n = [0]

        class Counting(shlex.shlex):
            def read_token(self):
                n[0] += 1
                return super().read_token()
        with mock.patch.object(shlex, 'shlex', Counting):
            result = gg._git_evaluate(cmd)
        return result, n[0]

    def test_value_semantics_unchanged(self):
        hv = gg._hatch_value
        self.assertEqual(hv('CAST_PUSH_OK=1 ' + G + ' push', 'CAST_PUSH_OK'), '1')
        self.assertEqual(hv('A=1 CAST_HATCH_REASON="a b c" ' + G + ' x', 'CAST_HATCH_REASON'), 'a b c')
        self.assertEqual(hv(G + ' push CAST_PUSH_OK=1', 'CAST_PUSH_OK'), '')      # not in the prefix
        self.assertEqual(hv('X=1 ' + G + ' CAST_PUSH_OK=1', 'CAST_PUSH_OK'), '')
        self.assertEqual(hv('', 'CAST_PUSH_OK'), '')
        # an unbalanced quote AFTER the prefix has nothing to do with the hatch value
        self.assertEqual(hv('CAST_PUSH_OK=1 ' + G + ' commit -m "oops', 'CAST_PUSH_OK'), '1')
        # an unbalanced quote INSIDE the prefix falls back to whitespace splitting (as before)
        self.assertEqual(hv('CAST_PUSH_OK=1 CAST_HATCH_REASON="oops ' + G + ' x', 'CAST_PUSH_OK'), '1')

    def test_hatched_segments_are_tokenized_once_not_three_times(self):
        seg = 'CAST_PUSH_OK=1 ' + G + ' push origin main ' + 'a ' * 90000
        self.assertLess(len(seg), gg._MAX_GIT_SEGMENT_LEN)
        cmd = seg + '; ' + seg
        self.assertLessEqual(2 * len(seg), gg._MAX_GIT_TOKENIZE_BYTES)
        unhatched = G + ' log ' + 'a ' * 90000
        baseline_result, baseline = self.count_tokens(unhatched + '; ' + unhatched)
        self.assertEqual(baseline_result, (0, None))
        (code, msg), hatched = self.count_tokens(cmd)
        self.assertEqual((code, msg), (0, None))
        self.assertEqual(self.rec.call_count, 2)    # one audit record per hatched segment
        # normalisation tokenizes each segment once; the hatch lookups must add ~nothing.
        self.assertLessEqual(hatched, baseline * 1.1 + 200,
                             f'hatched={hatched} baseline(unhatched, same size)={baseline}')

    def test_two_195kb_hatched_segments_finish_inside_the_budget(self):
        seg = 'CAST_PUSH_OK=1 ' + G + ' push origin main ' + 'x' * 195000
        self.assertLess(len(seg), gg._MAX_GIT_SEGMENT_LEN)
        cmd = seg + '; ' + seg
        t0 = time.perf_counter()
        code, msg = gg._git_evaluate(cmd)
        elapsed = time.perf_counter() - t0
        self.assertEqual((code, msg), (0, None))
        self.assertLess(elapsed, 2.0, f'{elapsed:.2f} s')


class TestGrepOpenFilesInPagerIsAnAcceptedResidual(_Base):
    def test_program_naming_grep_flags_are_allowed(self):
        for cmd in (G + ' grep -Ocat foo', G + ' grep -O"less -R" foo',
                    G + ' grep --open-files-in-pager=cat foo', G + ' grep --open-files-in-pager foo'):
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_the_residual_is_documented_next_to_upload_pack(self):
        doc = gg.__doc__
        i = doc.index('--upload-pack')
        window = doc[i - 600:i + 900]
        self.assertIn('--open-files-in-pager', window)
        self.assertIn('-O<cmd>', window)


class TestDryRunLastToggleWins(_Repo):
    """F1: `-n` ... `--no-dry-run` is NOT a dry run (measured with real git for clean / worktree
    prune / prune: the later toggle wins, and `--no-d` abbreviates the negation)."""
    BLOCKED = (
        G + ' worktree prune -n --no-dry-run',
        G + ' worktree prune --dry-run --no-dry-run',
        G + ' worktree prune -v --expire=now -n --no-dry-run',
        G + ' worktree prune -nv --no-dry-run',
        G + ' worktree prune -n --no-d',
        G + ' worktree prune -n --no-dry-run --verbose',
        G + ' clean -f -n --no-dry-run',
        G + ' clean -fd --dry-run --no-dry-run',
        G + ' prune -n --no-dry-run',
        G + ' rm -f -n --no-dry-run f',
    )
    ALLOWED = (
        G + ' worktree prune --no-dry-run -n',
        G + ' worktree prune -n --no-dry-run -n',
        G + ' worktree prune --no-dry-run --dry-run',
        G + ' worktree prune --dry-run',
        G + ' worktree prune --no-d --dry-run',
        G + ' clean -fn',
        G + ' clean -f --no-dry-run -n',
        G + ' prune --no-dry-run -n',
        G + ' rm -f --no-dry-run -n f',
    )

    def test_blocked(self):
        for cmd in self.BLOCKED:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd)

    def test_allowed(self):
        for cmd in self.ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_guard_agrees_with_real_git_for_clean(self):
        for tail in ('-n --no-dry-run', '--dry-run --no-dry-run', '--no-dry-run -n', '-n --no-dry-run -n',
                     '--no-d', '-n --no-d', '--no-d -n'):
            with self.subTest(tail=tail):
                f = os.path.join(self.repo, 'u.txt')
                Path(f).write_text('x')
                self.sh(['clean', '-f'] + tail.split(), cwd=self.repo)
                removed = not os.path.exists(f)
                code, _ = self.verdict(G + ' -C ' + self.repo + ' clean -f ' + tail)
                self.assertEqual(code == 0, not removed, f'guard allow={code == 0} but removed={removed}')
                Path(f).unlink() if os.path.exists(f) else None

    def test_toggle_scan_is_linear_on_a_run_of_dry_flags(self):
        cmd = G + ' worktree prune ' + '-n ' * 40000 + '--no-dry-run'
        t0 = time.perf_counter()
        code, _ = self.verdict(cmd)
        self.assertEqual(code, 2)
        self.assertLess(time.perf_counter() - t0, 2.0)


class TestWhereTheGitCommandRuns(_Repo):
    """F2-F4: resolve the repo from cd/pushd targets, `--git-dir <v>`, `env -C`, path-spelled git and
    git's full global-option grammar."""

    def setUp(self):
        super().setUp()
        self.plant_symlink_entry()
        self.clean = os.path.join(self.root, 'clean')
        self.sh(['init', '-q', self.clean])
        os.makedirs(os.path.join(self.repo, 'sub'))
        p = mock.patch('os.getcwd', return_value=self.root)
        p.start()
        self.addCleanup(p.stop)

    def blocks_in_poisoned_only(self, template):
        """`template` with {R} = the poisoned repo / the clean repo (relative to the cwd)."""
        self.assertBlocks(template.format(R='repo'), 'SYMLINK')
        self.assertAllows(template.format(R='clean'))

    def test_cd_pushd_and_subshell(self):
        for t in ('cd {R} && ' + G + ' status', 'cd ./{R}/ && ' + G + ' status',
                  'pushd {R}; ' + G + ' status', '(cd {R}; ' + G + ' status)',
                  'cd "{R}" && ' + G + ' log', "cd '{R}' && " + G + ' diff',
                  'cd -P {R} && ' + G + ' status', 'cd -- {R} && ' + G + ' status',
                  'cd {R} && echo a && ' + G + ' status', 'cd {R} && cd sub && ' + G + ' status',
                  'true && cd {R} && ' + G + ' -C . status',
                  'bash -c "cd {R} && ' + G + ' status"',
                  'if true; then cd {R}; ' + G + ' status; fi',
                  'cd {R} || exit 1; ' + G + ' status'):
            with self.subTest(t=t):
                self.blocks_in_poisoned_only(t)

    def test_cd_into_a_subdirectory_of_the_poisoned_repo(self):
        self.assertBlocks('cd repo/sub && ' + G + ' status', 'SYMLINK')

    def test_cd_alone_and_git_before_the_cd(self):
        self.assertAllows('cd repo')
        self.assertAllows(G + ' status && cd repo')       # git ran BEFORE the cd (at the clean cwd)

    def test_a_dynamic_cd_target_is_not_resolved_documented_residual(self):
        self.assertAllows('D=repo; cd $D && ' + G + ' status')
        self.assertAllows('cd "$(pwd)/repo" && ' + G + ' status')

    def test_every_literal_cd_target_counts_even_after_moving_on(self):
        # over-approximation by design: the union of every literal target seen so far
        self.assertBlocks('cd repo; cd ../clean; ' + G + ' status', 'SYMLINK')

    def test_git_dir_space_and_equals_forms(self):
        for t in (G + ' --git-dir {R}/.git status', G + ' --git-dir={R}/.git status',
                  G + ' --git-dir {R}/.git --work-tree {R} status',
                  'GIT_DIR={R}/.git ' + G + ' status', 'GIT_DIR="{R}/.git" ' + G + ' status'):
            with self.subTest(t=t):
                self.blocks_in_poisoned_only(t)

    def test_env_chdir_forms(self):
        for t in ('env -C {R} ' + G + ' status', 'env --chdir={R} ' + G + ' status',
                  'env --chdir {R} ' + G + ' status', 'env -C {R} FOO=1 ' + G + ' status',
                  'env -i -C {R} ' + G + ' status', 'env -C {R} /usr/bin/git status',
                  'env -C . -C {R} ' + G + ' status'):
            with self.subTest(t=t):
                self.blocks_in_poisoned_only(t)

    def test_path_spelled_and_wrapped_git(self):
        for t in ('/usr/bin/git -C {R} status', '/opt/homebrew/bin/git -C {R} status',
                  "'/usr/bin/git' -C {R} status", 'command ' + G + ' -C {R} status',
                  'xargs /usr/bin/git -C {R} status', 'FOO=1 /usr/bin/git -C {R} status',
                  'g\\it -C {R} status', "'g'i't' -C {R} status", './git -C {R} status',
                  'GIT_DIR={R}/.git /usr/bin/git status'):
            with self.subTest(t=t):
                self.blocks_in_poisoned_only(t)

    def test_unlisted_global_options_before_dash_C(self):
        zero = ('-p', '--paginate', '-P', '--no-pager', '--no-optional-locks', '--bare',
                '--no-replace-objects', '--literal-pathspecs', '--glob-pathspecs',
                '--noglob-pathspecs', '--icase-pathspecs', '--no-lazy-fetch', '--exec-path',
                '--exec-path=/x', '--namespace=x', '--list-cmds=x', '--attr-source=x',
                '--config-env=a.b=B', '--work-tree=W', '--super-prefix=x')
        spaced = ('--namespace x', '--config-env a.b=B', '--work-tree W', '--super-prefix x',
                  '--attr-source x', '--list-cmds x', '-c a.b=c')
        for opt in zero + spaced:
            with self.subTest(opt=opt):
                self.blocks_in_poisoned_only(G + ' ' + opt + ' -C {R} status')

    def test_value_taking_option_value_is_not_a_chdir(self):
        # `--namespace -C` consumes `-C` as its VALUE; the real -C is the one after it.
        self.blocks_in_poisoned_only(G + ' --namespace -C -C {R} status')

    def test_a_dash_C_after_the_subcommand_is_not_a_global_option(self):
        self.assertAllows(G + ' -C clean log -C repo')
        self.assertAllows(G + ' show -C repo')

    def test_help_and_version_forms_do_not_crash_resolution(self):
        for t in (G + ' --version', G + ' -h', G + ' --help', G + ' -C', G + ' -C clean',
                  G + ' --git-dir', G, G + ' --'):
            with self.subTest(t=t):
                self.verdict(t)

    def test_resolution_reads_only_the_prefix_of_a_huge_segment(self):
        t0 = time.perf_counter()
        self.assertBlocks(G + ' -C repo status ' + 'x' * 150000, 'SYMLINK')
        self.assertLess(time.perf_counter() - t0, 1.0)


class TestPlantingASymlinkUnderWorktrees(_Base):
    BLOCKED = (
        'ln -s /x repo/.git/worktrees/evil',
        'ln -sf /x repo/.git/worktrees/evil',
        'ln -sfn /x /abs/repo/.git/worktrees/evil',
        'ln --symbolic /x .git/worktrees/evil',
        'ln -s -- /x .git/worktrees/evil',
        '/bin/ln -s /x .git/worktrees/evil',
        'sudo ln -s /x .git/worktrees/evil',
        'cd repo && ln -s /x .git/worktrees/evil',
        'ln -s /x bare.git/worktrees/evil',
        'ln -s ".git/worktrees/x" y',
        'ln -t .git/worktrees -s /x',
        'FOO=1 ln -s /x .git/worktrees/evil',
    )
    ALLOWED = (
        'ln -s a b',
        'ln a b',
        'ln /x .git/worktrees/evil',          # a HARD link: not a symlink
        'ln -s a ~/worktrees/b',
        'ls .git/worktrees',
        'readlink .git/worktrees/x',
        'echo ln -s a .git/worktrees/x',
        'ln -s ../x .git/hooks',
        'ln -s a y.git',
    )

    def test_blocked(self):
        for cmd in self.BLOCKED:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd, 'CAST_WORKTREE_OK=1')

    def test_allowed(self):
        for cmd in self.ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_hatch_allows_and_records_once(self):
        self.assertAllows('CAST_WORKTREE_OK=1 ln -s /x .git/worktrees/evil')
        self.assertEqual(self.rec.call_count, 1)
        self.assertEqual(self.rec.call_args[0][0], 'CAST_WORKTREE_OK')

    def test_hatch_does_not_leak_to_the_next_segment(self):
        self.assertBlocks('CAST_WORKTREE_OK=1 ln -s /x a && ln -s /x .git/worktrees/evil')


class TestHatchValueMatchesTheOldEagerValue(_Base):
    """C: the lazy `_hatch_value` vs the old eager implementation (kept below as the reference).
    `_hatch_value` only feeds the AUDIT value; the allow/block verdict comes from the `*_ALLOW`
    regexes, so a difference can never recognise a hatch the old code did not."""

    @staticmethod
    def old(segment, variable):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        prefix = f'{variable}='
        for token in tokens:
            if not gg._ENV_ASSIGN.match(token):
                break
            if token.startswith(prefix):
                return token[len(prefix):]
        return ''

    SAME = (
        'CAST_PUSH_OK=1 ' + G + ' push',
        'A=1 CAST_PUSH_OK=1 ' + G + ' push',
        'CAST_HATCH_REASON="a b c" CAST_PUSH_OK=1 ' + G + ' push',
        "CAST_HATCH_REASON='x y' CAST_RESET_OK=1 " + G + ' reset --hard',
        'CAST_PUSH_OK=1 ' + G + ' commit -m "oops',               # unbalanced AFTER the prefix, no spaces in values
        'CAST_PUSH_OK=1 ' + G + " commit -m 'oops",
        'CAST_HATCH_REASON=ok CAST_PUSH_OK=1 ' + G + ' push "x',
        'CAST_PUSH_OK=1 CAST_HATCH_REASON="oops ' + G + ' x',     # unbalanced INSIDE the prefix: same fallback
        G + ' push CAST_PUSH_OK=1',
        'X=1 ' + G + ' y CAST_PUSH_OK=1',
        '',
        'CAST_PUSH_OK=',
        'CAST_PUSH_OK=1',
        '  CAST_PUSH_OK=1 ' + G + ' push',
        'CAST_PUSH_OK=1\t' + G + ' push',
        'CAST_PUSH_OK=a\\ b ' + G + ' push',
        'FOO="$(x)" CAST_PUSH_OK=1 ' + G + ' push',
    )

    def test_same_value_on_the_corpus(self):
        for seg in self.SAME:
            for var in ('CAST_PUSH_OK', 'CAST_HATCH_REASON', 'CAST_RESET_OK', 'NOPE'):
                with self.subTest(seg=seg, var=var):
                    self.assertEqual(gg._hatch_value(seg, var), self.old(seg, var))

    def test_the_one_difference_is_a_more_accurate_audit_value_never_a_new_hatch(self):
        # quoted multi-word reason + an unbalanced quote later: the old code split the whole segment
        # on whitespace and recorded a garbled `"a`; the new code records the real value.
        seg = 'CAST_HATCH_REASON="a b" CAST_PUSH_OK=1 ' + G + ' commit -m "oops'
        self.assertEqual(self.old(seg, 'CAST_HATCH_REASON'), '"a')
        self.assertEqual(gg._hatch_value(seg, 'CAST_HATCH_REASON'), 'a b')
        self.assertEqual(gg._hatch_value(seg, 'CAST_PUSH_OK'), '1')
        # the verdict never depended on `_hatch_value`: it comes from the `*_ALLOW` regexes (the
        # hatch must be exactly `=1`), so the lazy value can neither add nor remove a recognised hatch
        self.assertEqual(gg._git_evaluate('CAST_PUSH_OK=2 ' + G + ' push origin main')[0], 2)
        self.assertEqual(gg._git_evaluate('CAST_PUSH_OK=1 ' + G + ' push origin main')[0], 0)


class TestTrackerWorkIsLinearAndBounded(_Repo):
    """N1: `cd d0; cd d1; ...` nests, so each realpath/normpath walked an ever-longer path (1.7 s at
    20 KB, 12 s at 50 KB, >30 s at 100 KB). Now: at most `_MAX_TRACKED_CDS` literal cds are tracked and
    the path is length-capped; past either the dir is UNKNOWN and every git segment fails CLOSED
    (the same stance as N2), with the work after the cap O(1) per segment."""

    def setUp(self):
        super().setUp()
        p = mock.patch('os.getcwd', return_value=self.root)
        p.start()
        self.addCleanup(p.stop)

    def test_distinct_cds_are_fast_and_fail_closed_in_process(self):
        for kb in (20, 100):
            cmd = '; '.join(f'cd d{i}' for i in range(kb * 1000 // 8)) + '; ' + G + ' status'
            t0 = time.perf_counter()
            code, msg = self.verdict(cmd)
            elapsed = time.perf_counter() - t0
            self.assertEqual(code, 2, kb)
            self.assertIn('too complex', msg)
            self.assertLess(elapsed, 1.0, f'{kb} KB took {elapsed:.2f} s')

    def test_the_cap_boundary(self):
        ok = '; '.join(['cd .'] * (gg._MAX_TRACKED_CDS - 1)) + '; cd repo; ' + G + ' status'
        self.plant_symlink_entry()
        self.assertBlocks(ok, 'SYMLINK')                       # still resolved at the cap
        over = '; '.join(['cd .'] * (gg._MAX_TRACKED_CDS + 1)) + '; ' + G + ' status'
        self.assertBlocks(over, 'too complex')                 # past it: unknown -> closed
        self.assertAllows('; '.join(['cd .'] * (gg._MAX_TRACKED_CDS + 1)))     # cds alone are fine

    def test_a_deep_nested_path_is_capped_by_length(self):
        long_dir = 'x' * 3000
        self.assertBlocks('cd ' + long_dir + '; cd ' + long_dir + '; ' + G + ' status', 'too complex')

    def test_400kb_of_distinct_cds_in_a_fresh_process(self):
        script = (
            'import importlib.util, os, sys, time\n'
            'os.environ["HOME"] = sys.argv[2]\n'
            'sp = importlib.util.spec_from_file_location("g", sys.argv[1])\n'
            'g = importlib.util.module_from_spec(sp); sp.loader.exec_module(g)\n'
            'g._record_hatch = lambda *a, **k: None\n'
            'cmd = "; ".join("cd d%d" % i for i in range(400000 // 8)) + "; " + "gi" + "t status"\n'
            't0 = time.perf_counter(); code, msg = g._git_evaluate(cmd)\n'
            'print(code, round(time.perf_counter() - t0, 3))\n')
        out = subprocess.run([sys.executable, '-I', '-c', script, str(_REPO / 'scripts' / 'cast-git-guard.py'),
                              self.home], capture_output=True, text=True, cwd=self.root, timeout=60)
        code, secs = out.stdout.split()
        self.assertEqual(code, '2', out.stderr)
        self.assertLess(float(secs), 1.0, f'{secs} s')


class TestPrefixCapFailsClosed(_Repo):
    """N2: past the 8 KB / 128-token prefix cap the repo can no longer be resolved; a segment that
    IS a git invocation then fails CLOSED (`too complex`), a long non-git argument list does not."""

    def setUp(self):
        super().setUp()
        self.plant_symlink_entry()
        self.clean = os.path.join(self.root, 'clean')
        self.sh(['init', '-q', self.clean])
        p = mock.patch('os.getcwd', return_value=self.clean)
        p.start()
        self.addCleanup(p.stop)

    CAPPED = (
        G + ' ' + '-c a=b ' * 126 + '-C ../repo status',
        G + ' -c a=' + 'x' * 8200 + ' -C ../repo status',
        G + ' ' + ' ' * 9000 + '-C ../repo status',
        G + ' ' + '-C . ' * 200 + '-C ../repo status',
        'FOO=1 ' * 300 + G + ' -C ../repo status',
        'env ' + 'FOO=1 ' * 300 + G + ' -C ../repo status',
        '/usr/bin/' + G + ' ' + '-c a=b ' * 130 + 'status',
    )

    def test_capped_git_invocations_fail_closed(self):
        for cmd in self.CAPPED:
            with self.subTest(cmd=cmd[:50] + '...'):
                self.assertBlocks(cmd, 'too complex')

    def test_hatch_allows_a_capped_invocation(self):
        self.assertAllows('CAST_WORKTREE_OK=1 ' + G + ' ' + '-c a=b ' * 126 + '-C ../repo status')

    def test_just_under_the_cap_still_resolves_normally(self):
        self.assertBlocks(G + ' ' + '-c a=b ' * 50 + '-C ../repo status', 'SYMLINK')
        self.assertAllows(G + ' ' + '-c a=b ' * 50 + '-C ../clean status')

    def test_long_non_git_text_and_long_subcommand_args_are_not_blocked(self):
        self.assertAllows('echo ' + 'a ' * 5000 + 'digit')
        self.assertAllows('echo ' + 'a ' * 5000 + G)
        self.assertAllows(G + ' log --grep "' + 'a ' * 5000 + '"')
        self.assertAllows(G + ' log ' + 'a ' * 5000)
        self.assertAllows('FOO=1 echo ' + 'a ' * 5000)


class TestPlantDetectionNormalisesThePath(_Repo):
    """N3: the plant check matches a `worktrees` component under a git dir after lowercasing,
    collapsing `//` `/./` `..`, resolving a relative link name against the tracked cwd, and (for a
    bare repo) looking at the filesystem."""

    def setUp(self):
        super().setUp()
        p = mock.patch('os.getcwd', return_value=self.repo)
        p.start()
        self.addCleanup(p.stop)
        self.bare = os.path.join(self.root, 'myrepo')
        self.sh(['init', '-q', '--bare', self.bare])
        os.makedirs(os.path.join(self.root, 'notrepo', 'worktrees'))

    BLOCKED = (
        'ln -s /v .GIT/worktrees/x',
        'ln -s /v .Git/Worktrees/x',
        'ln -s /v .git//worktrees/x',
        'ln -s /v ./.git/./worktrees/x',
        'ln -s /v a/b/../.git/worktrees/x',
        'ln -s /v nope/.git/./worktrees/x',               # nonexistent: only the textual collapse sees it
        'ln -s /v nope/.git/../.git//worktrees/x',
        'ln -s /v .git/modules/sub/worktrees/e',
        'ln -s /v .GIT/modules/sub/worktrees/e',
        'ln -s /v bare.git/worktrees/x',
        'ln -s /v ../myrepo/worktrees/x',
        'ln -t .GIT/worktrees -s /v',
        'ln --target-directory=.git/worktrees -s /v',
        'ln -s /v .git/worktrees',
        'cd .git/worktrees && ln -s /v x',
        'cd .git && ln -s /v worktrees',
        'cd .git; cd worktrees; ln -s /v x',
        'pushd .GIT/worktrees; ln -sf /v x',
        'cd ../myrepo/worktrees && ln -s /v x',
    )
    ALLOWED = (
        'ln -s /v ../notrepo/worktrees/x',      # a plain directory named worktrees (no git dir)
        'ln -s a ~/worktrees/b',
        'ln -s /v worktrees/x',                 # cwd is the repo WORKTREE, not .git
        'cd .git && ln -s /v hooks',
        'cd .git/hooks && ln -s /v x',
        'ln -s /v .git/info/exclude',
        'ln /v .GIT/worktrees/x',               # hard link
        'ln -s /v .gitworktrees/x',
        'ls .GIT/worktrees',
    )

    def test_blocked(self):
        for cmd in self.BLOCKED:
            with self.subTest(cmd=cmd):
                self.assertBlocks(cmd, 'CAST_WORKTREE_OK=1')

    def test_allowed(self):
        for cmd in self.ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertAllows(cmd)

    def test_hatch(self):
        self.assertAllows('CAST_WORKTREE_OK=1 ln -s /v .GIT/worktrees/x')


if __name__ == '__main__':
    unittest.main()
