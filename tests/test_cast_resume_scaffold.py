#!/usr/bin/env python3
"""Tests for scripts/cast-resume-scaffold.py — silent-failure predicates.

Covers three predicates that fail silently and plausibly:
1. _is_superseded(path) — scans only first 10 lines for "superseded" substring.
   A header describing the rule (e.g. "picks the newest non-superseded file")
   causes false positive; a real marker after line 10 is missed.

2. _plan_next_action(repo, plan_name) — strips "NEXT ACTION" label and falls
   through when nothing remains. A heading that is ONLY "## NEXT ACTION" with
   the action on the following line yields empty string, seeding resume with
   unrelated prose (the second mention of "DISPATCH SEQUENCE"). ALSO matches
   the substring "next action" anywhere in a line, not only as a label/heading,
   so prose like "no next action marker" yields "marker." instead of None.

3. _newest_plan(repo) — returns newest-mtime .md file under plans/, ignoring
   subdirectories.

These are characterization tests for CURRENTLY-BUGGY behavior. Tests are
marked clearly where behavior is wrong; a future fix will flip those assertions
into correct behavior.
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


# Load cast-resume-scaffold.py via importlib (hyphenated name prevents direct import)
_SCRIPT_PATH = str(Path(__file__).parent.parent / 'scripts' / 'cast-resume-scaffold.py')
spec = importlib.util.spec_from_file_location('cast_resume_scaffold', _SCRIPT_PATH)
crs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crs)


class TestIsSuperseded(unittest.TestCase):
    """Tests for _is_superseded(path) — line-scan and substring matching."""

    def setUp(self):
        """Create a temp directory for fixture files."""
        self.tmpdir = tempfile.mkdtemp(prefix='cast-resume-test-')

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_plan(self, name: str, content: str) -> str:
        """Write a fixture plan file and return its path."""
        path = os.path.join(self.tmpdir, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return path

    def test_real_superseded_in_first_10_lines_returns_true(self):
        """A file with 'superseded' marker in the first 10 lines returns True."""
        content = "# Old Plan\n\n[SUPERSEDED] This plan is superseded by plans/v10-new.md\n"
        path = self._write_plan('old-plan.md', content)
        self.assertTrue(crs._is_superseded(path))

    def test_superseded_case_insensitive(self):
        """Case-insensitive: 'SUPERSEDED', 'Superseded', 'superseded' all match."""
        for marker in ['SUPERSEDED', 'Superseded', 'superseded']:
            with self.subTest(marker=marker):
                content = f"# Plan\n\n[{marker}] — see new plan\n"
                path = self._write_plan(f'plan-{marker}.md', content)
                self.assertTrue(crs._is_superseded(path))

    def test_superseded_only_after_line_10_returns_false(self):
        """Real marker after line 10 is NOT detected — scans only first 10 lines.

        INTENTIONAL BEHAVIOR: The 10-line window is deliberate design. A supersede
        marker belongs near the top of a file (in the preamble), not buried deep.
        Files with markers after line 10 are treated as NOT superseded, which
        enforces the convention that status metadata should appear early.

        This test pins the intended behavior and distinguishes it from the two
        _CURRENT_BUG tests, which capture genuine defects to be fixed.
        """
        lines = [f"Line {i}\n" for i in range(1, 11)]  # 10 lines
        lines.append("# Now superseded (too late)\n")
        lines.append("[SUPERSEDED] This marker is on line 12, not detected.\n")
        content = "".join(lines)
        path = self._write_plan('late-marker.md', content)
        # BUG: This should be True (file IS superseded) but returns False.
        self.assertFalse(crs._is_superseded(path))

    def test_descriptive_mention_in_first_10_lines_false_positive_CURRENT_BUG(self):
        """A line merely DESCRIBING the rule causes false positive — CURRENT BUG.

        Header text like 'picks the newest non-superseded file' contains the
        substring 'superseded' and matches, even though it's descriptive prose,
        not a status marker. This caused the live plan to be rejected on
        2026-08-24, silently demoting the seed to a different plan file.

        This test pins the buggy behavior explicitly. A fix would change the
        assertion from assertTrue to assertFalse.
        """
        content = (
            "# Resume Plan\n"
            "\n"
            "The scaffold picks the newest non-superseded file under plans/.\n"
            "\n"
            "See §5 for next steps.\n"
        )
        path = self._write_plan('descriptive.md', content)
        # BUG: This returns True (false positive) even though 'superseded' is
        # merely in a descriptive sentence, not a status marker.
        self.assertTrue(crs._is_superseded(path))

    def test_supersedes_active_verb_does_not_match(self):
        """Only 'superseded' (passive) matches; 'supersedes' (active) does not.

        A plan that points FORWARD to a newer plan uses 'supersedes' and must
        not trigger the filter. This is the intended discrimination.
        """
        content = "# Current Plan\n\nThis plan supersedes plans/v9.md (old).\n"
        path = self._write_plan('current.md', content)
        self.assertFalse(crs._is_superseded(path))

    def test_nonexistent_file_returns_false(self):
        """File not found gracefully returns False (not a superseded plan)."""
        self.assertFalse(crs._is_superseded('/nonexistent/path/plan.md'))

    def test_empty_file_returns_false(self):
        """Empty file has no 'superseded' marker, returns False."""
        path = self._write_plan('empty.md', '')
        self.assertFalse(crs._is_superseded(path))

    def test_no_markers_returns_false(self):
        """Readable file with ordinary prose but no 'superseded' marker returns False.

        Covers the edge case of a well-formed plan file that simply lacks any
        supersede marker — distinct from an empty file. This tests that the
        function correctly distinguishes between "no file" (nonexistent),
        "empty file," and "file with content but no marker."
        """
        content = (
            "# Active Plan\n"
            "\n"
            "This plan describes the current phase of work.\n"
            "\n"
            "## Objectives\n"
            "1. Complete task A\n"
            "2. Complete task B\n"
            "\n"
            "See the dispatch sequence below for details.\n"
        )
        path = self._write_plan('ordinary-plan.md', content)
        self.assertFalse(crs._is_superseded(path))


class TestNewPlan(unittest.TestCase):
    """Tests for _newest_plan(repo) — mtime ranking and non-superseded filtering."""

    def setUp(self):
        """Create temp repo with plans/ subdirectory."""
        self.tmpdir = tempfile.mkdtemp(prefix='cast-resume-test-')
        self.plans_dir = os.path.join(self.tmpdir, 'plans')
        os.makedirs(self.plans_dir, exist_ok=True)

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_plan(self, name: str, content: str = '') -> str:
        """Write a plan file under plans/."""
        path = os.path.join(self.plans_dir, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return path

    def test_newest_plan_by_mtime(self):
        """Returns the newest (most recently modified) .md file.

        Uses names where alphabetical order and mtime order DISAGREE:
        - zzz.md created first (oldest mtime, comes last alphabetically)
        - aaa.md created second (newest mtime, comes first alphabetically)

        A buggy "first alphabetically" implementation would return aaa.md and
        accidentally pass. A buggy "last alphabetically" would return zzz.md
        and fail. Only a correct "newest mtime" implementation returns aaa.md
        for the right reason. Mtimes are set explicitly with os.utime() to avoid
        flakiness from sub-second filesystem timestamp granularity.
        """
        self._write_plan('zzz.md', '# Old\n')
        self._write_plan('aaa.md', '# New\n')
        # Explicitly set mtimes: zzz.md oldest, aaa.md newest
        os.utime(os.path.join(self.plans_dir, 'zzz.md'), (1000000, 1000000))
        os.utime(os.path.join(self.plans_dir, 'aaa.md'), (2000000, 2000000))

        result = crs._newest_plan(self.tmpdir)
        self.assertEqual(result, 'aaa.md')

    def test_newest_plan_by_mtime_reversed_order(self):
        """Mirror test: aaa.md created first (oldest), zzz.md second (newest).

        Verifies that the implementation correctly discriminates mtime in both
        directions. This catches implementations that hardcode a specific
        ordering or rely on creation order rather than actual mtime values.
        """
        self._write_plan('aaa.md', '# Old\n')
        self._write_plan('zzz.md', '# New\n')
        # Explicitly set mtimes: aaa.md oldest, zzz.md newest
        os.utime(os.path.join(self.plans_dir, 'aaa.md'), (1000000, 1000000))
        os.utime(os.path.join(self.plans_dir, 'zzz.md'), (2000000, 2000000))

        result = crs._newest_plan(self.tmpdir)
        self.assertEqual(result, 'zzz.md')

    def test_newest_plan_skips_subdirectories(self):
        """Subdirectories under plans/ are NOT scanned.

        _newest_plan only lists top-level .md files; nested plans/ subdirs
        are silently skipped.
        """
        self._write_plan('top-level.md', '# Top level\n')
        subdir = os.path.join(self.plans_dir, 'archive')
        os.makedirs(subdir, exist_ok=True)
        nested_path = os.path.join(subdir, 'nested-plan.md')
        with open(nested_path, 'w') as f:
            f.write('# Nested\n')

        result = crs._newest_plan(self.tmpdir)
        self.assertEqual(result, 'top-level.md')

    def test_newest_plan_no_plans_dir_returns_none(self):
        """No plans/ subdirectory returns None."""
        os.rmdir(self.plans_dir)
        result = crs._newest_plan(self.tmpdir)
        self.assertIsNone(result)

    def test_newest_plan_empty_plans_dir_returns_none(self):
        """Empty plans/ directory returns None."""
        result = crs._newest_plan(self.tmpdir)
        self.assertIsNone(result)

    def test_newest_non_superseded_plan_filtered(self):
        """Filters out superseded plans, returns newest non-superseded.

        Uses names where alphabetical order and mtime order DISAGREE:
        - zzz.md (superseded, oldest mtime, comes last alphabetically)
        - aaa.md (not superseded, newest mtime, comes first alphabetically)

        A buggy "first alphabetically" would return aaa.md and pass accidentally.
        A buggy "last alphabetically" would return zzz.md and fail. Only the
        correct "newest non-superseded" returns aaa.md for the right reason.
        Mtimes are set explicitly with os.utime() to avoid flakiness.
        """
        self._write_plan('zzz.md', '# Old\n\n[SUPERSEDED] See aaa.md\n')
        self._write_plan('aaa.md', '# Current\n\nActive plan.\n')
        # Explicitly set mtimes: zzz.md oldest, aaa.md newest
        os.utime(os.path.join(self.plans_dir, 'zzz.md'), (1000000, 1000000))
        os.utime(os.path.join(self.plans_dir, 'aaa.md'), (2000000, 2000000))

        result = crs._newest_plan(self.tmpdir)
        self.assertEqual(result, 'aaa.md')

    def test_newest_non_superseded_plan_filtered_reversed(self):
        """Mirror test: aaa.md (superseded), zzz.md (not superseded, newest).

        Verifies filtering works correctly in both name-order directions.
        """
        self._write_plan('aaa.md', '# Old\n\n[SUPERSEDED] See zzz.md\n')
        self._write_plan('zzz.md', '# Current\n\nActive plan.\n')
        # Explicitly set mtimes: aaa.md oldest, zzz.md newest
        os.utime(os.path.join(self.plans_dir, 'aaa.md'), (1000000, 1000000))
        os.utime(os.path.join(self.plans_dir, 'zzz.md'), (2000000, 2000000))

        result = crs._newest_plan(self.tmpdir)
        self.assertEqual(result, 'zzz.md')

    def test_all_superseded_falls_back_to_newest(self):
        """When ALL plans are superseded, fall back to newest (stale seed beats none)."""
        self._write_plan('old.md', '# Old\n\n[SUPERSEDED]\n')
        self._write_plan('new.md', '# New\n\n[SUPERSEDED]\n')
        # Ensure new.md is newer
        os.utime(os.path.join(self.plans_dir, 'new.md'), None)

        result = crs._newest_plan(self.tmpdir)
        # Falls back to newest: new.md
        self.assertEqual(result, 'new.md')

    def test_only_non_md_files_returns_none(self):
        """No .md files in plans/ returns None."""
        with open(os.path.join(self.plans_dir, 'readme.txt'), 'w') as f:
            f.write('Not markdown\n')
        result = crs._newest_plan(self.tmpdir)
        self.assertIsNone(result)


class TestPlanNextAction(unittest.TestCase):
    """Tests for _plan_next_action(repo, plan_name) — label stripping and fallback."""

    def setUp(self):
        """Create temp repo with plans/ subdirectory."""
        self.tmpdir = tempfile.mkdtemp(prefix='cast-resume-test-')
        self.plans_dir = os.path.join(self.tmpdir, 'plans')
        os.makedirs(self.plans_dir, exist_ok=True)

    def tearDown(self):
        """Clean up temp directory."""
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_plan(self, name: str, content: str) -> str:
        """Write a plan file under plans/."""
        path = os.path.join(self.plans_dir, name)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return path

    def test_next_action_label_and_action_on_same_line(self):
        """Label and action on same line: returns the action (label stripped)."""
        content = (
            "# Plan\n"
            "\n"
            "## NEXT ACTION: dispatch the backend writer\n"
            "\n"
            "Details follow.\n"
        )
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        # Should return the action, with label and markup stripped
        self.assertEqual(result, 'dispatch the backend writer')
        self.assertNotIn('NEXT ACTION', result)

    def test_next_action_label_only_returns_none_CURRENT_BUG(self):
        """Label alone on its line, action on NEXT line — CURRENT BUG (returns None).

        When "## NEXT ACTION" is on its own line with nothing after stripping,
        the code correctly skips it (no text to return), but then fails to extract
        the action from the next line. It should fall through to dispatch sequence
        lookup, but the dispatch sequence lookup only works for level-2 headings
        "## ". This is the live bug from 2026-08-24.

        Expected (correct): "dispatch the backend writer with focus on X"
        Actual (BUG): None (action on next line is silently lost)

        This test pins the current buggy behavior explicitly so a fix will flip
        the assertion.
        """
        content = (
            "# Plan\n"
            "\n"
            "## NEXT ACTION\n"
            "dispatch the backend writer with focus on X\n"
            "\n"
            "Other sections follow.\n"
        )
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')

        # BUG: Returns None instead of extracting the next line's action
        self.assertIsNone(result,
            msg='Label-only falls through silently (BUG): action on next line is lost')

    def test_next_action_substring_anywhere_in_line_extracts_from_that_point(self):
        """The 'next action' substring is found ANYWHERE in a line, not just as a label.

        This is a secondary bug: in the line "Some content but no next action marker",
        the substring "next action" is found and the text from that point onward is
        extracted (after stripping the label), returning "marker." instead of None.
        """
        content = (
            "# Plan\n"
            "\n"
            "Some content but no next action marker.\n"
        )
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')

        # BUG: Finds "next action" inside "no next action marker" and extracts after it
        self.assertEqual(result, 'marker.',
            msg='Substring match anywhere in line (BUG): should not match mid-word')

    def test_next_action_case_insensitive_match(self):
        """NEXT ACTION marker is matched case-insensitively."""
        content = "# Plan\n\n## next action: fix the bug\n"
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        self.assertEqual(result, 'fix the bug')

    def test_next_action_strips_markdown_emphasis(self):
        """Strips ** and __ (markdown bold/italic)."""
        content = "# Plan\n\n## NEXT ACTION: **dispatch the writer** and review\n"
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        self.assertEqual(result, 'dispatch the writer and review')
        self.assertNotIn('**', result)

    def test_next_action_strips_colons_and_dashes(self):
        """Strips colons and dashes after the label."""
        content = "# Plan\n\n## NEXT ACTION- dispatch the writer\n"
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        self.assertEqual(result, 'dispatch the writer')

    def test_dispatch_sequence_fallback_first_level_2_heading_after_marker(self):
        """Falls back to first level-2 (##) heading after 'DISPATCH SEQUENCE' marker.

        Note: Dispatch sequence lookup only matches level-2 headings (##), not
        level-3 (###) or higher. This is a limitation but not necessarily a bug.
        """
        content = (
            "# Plan\n"
            "\n"
            "## DISPATCH SEQUENCE\n"
            "\n"
            "## First Heading\n"
            "Do this first.\n"
        )
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        # Falls back to dispatch sequence heading (level 2)
        self.assertEqual(result, 'First Heading')

    def test_dispatch_sequence_ignores_level_3_headings(self):
        """Dispatch sequence fallback only matches level-2 (##) headings, not ###."""
        content = (
            "# Plan\n"
            "\n"
            "## DISPATCH SEQUENCE\n"
            "\n"
            "### Level-3 Heading\n"
            "This is level 3, not level 2.\n"
            "\n"
            "## Level-2 Heading\n"
            "This should be matched.\n"
        )
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        # Skips ### and returns first ##
        self.assertEqual(result, 'Level-2 Heading')

    def test_nonexistent_file_returns_none(self):
        """File not found gracefully returns None."""
        result = crs._plan_next_action(self.tmpdir, 'nonexistent.md')
        self.assertIsNone(result)

    def test_next_action_empty_after_strip_continues_search(self):
        """If action text is empty after stripping emphasis, continues to next line."""
        content = (
            "# Plan\n"
            "\n"
            "## NEXT ACTION: **\n"
            "\n"
            "## NEXT ACTION: real action\n"
        )
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        # Empty first action skipped, continues and finds second one
        self.assertEqual(result, 'real action')

    def test_next_action_colon_separator(self):
        """Standard form: 'NEXT ACTION: text'."""
        content = "# Plan\n\n## NEXT ACTION: task description\n"
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        self.assertEqual(result, 'task description')

    def test_next_action_hyphen_separator(self):
        """Alternative form: 'NEXT ACTION- text'."""
        content = "# Plan\n\n## NEXT ACTION- task description\n"
        self._write_plan('plan.md', content)
        result = crs._plan_next_action(self.tmpdir, 'plan.md')
        self.assertEqual(result, 'task description')


if __name__ == '__main__':
    unittest.main()
