#!/usr/bin/env python3
"""Tests for scripts/cast_memory_meta.py (shared auto-memory frontmatter helpers).

Stdlib unittest only. Filesystem fixtures live in temp dirs; nothing touches HOME.
"""

import importlib.util
import os
import tempfile
import unittest
from datetime import date
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "cast_memory_meta.py"

_spec = importlib.util.spec_from_file_location("cast_memory_meta", MODULE_PATH)
cmm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cmm)


class ParseVerifiedAtTests(unittest.TestCase):
    def test_reads_top_level_verified_at(self):
        content = "---\nname: feedback-foo\nverified_at: 2026-06-02\n---\nbody\n"
        self.assertEqual(cmm.parse_verified_at(content), date(2026, 6, 2))

    def test_reads_verified_at_indented_under_metadata(self):
        # Known past bug: the real file format indents verified_at under metadata:.
        # Without strip() before startswith() this returns None (0 stale found, not 14).
        content = (
            "---\n"
            "name: feedback-foo\n"
            "metadata:\n"
            "  verified_at: 2026-06-02\n"
            "---\n"
            "body\n"
        )
        self.assertEqual(cmm.parse_verified_at(content), date(2026, 6, 2))

    def test_strips_surrounding_quotes_from_value(self):
        content = '---\nmetadata:\n  verified_at: "2026-03-15"\n---\n'
        self.assertEqual(cmm.parse_verified_at(content), date(2026, 3, 15))

    def test_returns_none_when_key_absent(self):
        content = "---\nname: x\ndescription: no date here\n---\nbody\n"
        self.assertIsNone(cmm.parse_verified_at(content))

    def test_returns_none_when_no_frontmatter(self):
        content = "# Just a heading\nverified_at: 2026-06-02\n"
        self.assertIsNone(cmm.parse_verified_at(content))

    def test_returns_none_for_unparseable_date(self):
        content = "---\nverified_at: not-a-date\n---\n"
        self.assertIsNone(cmm.parse_verified_at(content))

    def test_ignores_verified_at_after_frontmatter_closes(self):
        content = "---\nname: x\n---\nverified_at: 2026-06-02\n"
        self.assertIsNone(cmm.parse_verified_at(content))

    def test_empty_content_returns_none(self):
        self.assertIsNone(cmm.parse_verified_at(""))


class HasConcreteRefTests(unittest.TestCase):
    def test_detects_scripts_path(self):
        self.assertTrue(cmm.has_concrete_ref("see repo/scripts/cast-foo.py"))

    def test_detects_claude_home_path(self):
        self.assertTrue(cmm.has_concrete_ref("lives in ~/.claude/cast.db"))

    def test_detects_function_call_reference(self):
        self.assertTrue(cmm.has_concrete_ref("call parse_thing() first"))

    def test_detects_cli_flag(self):
        self.assertTrue(cmm.has_concrete_ref("pass --confirm to proceed"))

    def test_plain_prose_has_no_concrete_ref(self):
        self.assertFalse(cmm.has_concrete_ref("Users prefer short answers."))

    def test_empty_string_has_no_concrete_ref(self):
        self.assertFalse(cmm.has_concrete_ref(""))


class IterMemoryFilesTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def _touch(self, rel: str) -> None:
        path = os.path.join(self.base, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        Path(path).write_text("x")

    def test_returns_sorted_memory_files_across_projects(self):
        self._touch("proj-b/memory/feedback_b.md")
        self._touch("proj-a/memory/project_a.md")
        self._touch("proj-a/memory/reference_a.md")
        found = cmm.iter_memory_files(self.base)
        self.assertEqual(
            [os.path.relpath(p, self.base) for p in found],
            [
                os.path.join("proj-a", "memory", "project_a.md"),
                os.path.join("proj-a", "memory", "reference_a.md"),
                os.path.join("proj-b", "memory", "feedback_b.md"),
            ],
        )

    def test_skips_memory_index_file(self):
        self._touch("proj-a/memory/MEMORY.md")
        self._touch("proj-a/memory/feedback_a.md")
        found = cmm.iter_memory_files(self.base)
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].endswith("feedback_a.md"))

    def test_ignores_non_markdown_and_wrong_depth(self):
        self._touch("proj-a/memory/notes.txt")
        self._touch("proj-a/memory/nested/deep.md")
        self._touch("loose.md")
        self.assertEqual(cmm.iter_memory_files(self.base), [])

    def test_missing_base_dir_returns_empty_list(self):
        missing = os.path.join(self.base, "does-not-exist")
        self.assertEqual(cmm.iter_memory_files(missing), [])


if __name__ == "__main__":
    unittest.main()
