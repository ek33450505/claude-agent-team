"""Tests for the once-per-run transcript index in scripts/cast-record-review.py (audit P-3)."""
import glob
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scripts', 'cast-record-review.py')
spec = importlib.util.spec_from_file_location('cast_record_review', SCRIPT)
crr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crr)

SIDS = ['aaaa1111', 'bbbb2222', 'cccc3333', 'nomatch99']


def old_glob(projects_dir, sid):
    return sorted(glob.glob(os.path.join(projects_dir, '**', f'*{sid}*.jsonl'), recursive=True))


def _touch(path, text='{}\n'):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(text)


class TranscriptIndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        r = self.root
        _touch(f'{r}/proj-a/aaaa1111.jsonl')
        _touch(f'{r}/proj-a/sub/deep/x-aaaa1111-y.jsonl')   # substring match, nested
        _touch(f'{r}/proj-b/bbbb2222.jsonl')
        _touch(f'{r}/proj-b/bbbb2222.txt')                  # wrong extension
        _touch(f'{r}/proj-b/.hidden-cccc3333.jsonl')        # hidden file
        _touch(f'{r}/.hiddendir/cccc3333.jsonl')            # hidden dir
        _touch(f'{r}/cccc3333.jsonl')                       # directly in root
        _touch(f'{r}/proj-c/zz_cccc3333_zz.jsonl')

    def tearDown(self):
        self.tmp.cleanup()

    def test_index_matches_old_glob(self):
        idx = crr._TranscriptIndex(self.root)
        for sid in SIDS:
            self.assertEqual(sorted(idx.find(sid)), old_glob(self.root, sid), sid)
        self.assertEqual(len(idx.find('aaaa1111')), 2)
        self.assertEqual(idx.find('nomatch99'), [])

    def test_tree_walked_once_for_many_events(self):
        _touch(f'{self.root}/p/aaaa1111.jsonl', json.dumps({'timestamp': '2026-01-01T00:00:00Z'}) + '\n')
        idx = crr._TranscriptIndex(self.root)
        real_walk = os.walk
        with mock.patch.object(crr.os, 'walk', side_effect=real_walk) as walk, \
             mock.patch.object(crr.glob, 'glob', side_effect=AssertionError('glob per event')):
            for i in range(50):
                crr._find_transcript_evidence(self.root, SIDS[i % 4], '2026-01-02T00:00:00Z', idx)
        self.assertEqual(walk.call_count, 1)

    def test_missing_projects_dir(self):
        missing = os.path.join(self.root, 'does-not-exist')
        idx = crr._TranscriptIndex(missing)
        self.assertEqual(idx.find('aaaa1111'), old_glob(missing, 'aaaa1111'))
        self.assertEqual(idx.find('aaaa1111'), [])
        self.assertIsNone(crr._find_transcript_evidence(missing, 'aaaa1111', '2026-01-02T00:00:00Z'))

    def test_empty_or_unknown_session_skips_walk(self):
        idx = crr._TranscriptIndex(self.root)
        with mock.patch.object(crr.os, 'walk', side_effect=AssertionError('walked')):
            self.assertIsNone(crr._find_transcript_evidence(self.root, '', 'x', idx))
            self.assertIsNone(crr._find_transcript_evidence(self.root, 'unknown', 'x', idx))


if __name__ == '__main__':
    unittest.main()
