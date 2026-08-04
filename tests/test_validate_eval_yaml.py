#!/usr/bin/env python3
"""
Unit tests for scripts/eval-graders/validate-eval-yaml.py.

Covers:
  - Required top-level key validation
  - id field must match filename
  - corpus_source and cost_tier value validation
  - Grader type and field validation
  - on_error='fail' rejection (three-outcome discipline)
  - {output} injection guard
  - expected_behaviors and forbidden_behaviors non-empty validation
"""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).parent.parent / 'scripts' / 'eval-graders'
_SCRIPT_PATH = _SCRIPTS_DIR / 'validate-eval-yaml.py'

# Load module via importlib (hyphenated name cannot be imported normally)
_spec = importlib.util.spec_from_file_location('validate_eval_yaml', str(_SCRIPT_PATH))
validate_eval_yaml = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate_eval_yaml)


class TestValidateValidYaml(unittest.TestCase):
    """Test validation of correct YAML."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_valid_complete_yaml(self):
        """A fully valid YAML should return 0."""
        yaml_content = """---
id: test-case
version: 1
agent: code-reviewer
description: Test for missing status block
corpus_source: manual
failure_type: missing_status_block
cost_tier: cheap
tags:
  - critical
  - status
trigger: Code reviewer finishes without Status line
expected_behaviors:
  - Status block is always present
forbidden_behaviors:
  - No Status: DONE_WITH_CONCERNS
graders:
  - id: grep-status
    type: programmatic
    pass_criteria: "count == 1"
    on_error: skip
    command: "grep -c 'Status:' {output_file}"
  - id: llm-check
    type: llm_judge
    pass_criteria: "response indicates status block is present"
    on_error: error
    prompt: "Does this response have a Status block?"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-case.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)


class TestValidateMissingRequiredKeys(unittest.TestCase):
    """Test detection of missing required keys."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_missing_id_key(self):
        """Missing 'id' key should return 1."""
        yaml_content = """---
version: 1
agent: code-reviewer
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: []
trigger: Test trigger
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'missing-id.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_missing_multiple_keys(self):
        """Missing multiple required keys should return 1."""
        yaml_content = """---
id: test
version: 1
"""
        yaml_path = os.path.join(self.tmpdir, 'test.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)


class TestValidateIdMatchesFilename(unittest.TestCase):
    """Test that id field must match filename stem."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_id_matches_filename(self):
        """id matching filename stem should pass."""
        yaml_content = """---
id: my-test-case
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'my-test-case.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_id_does_not_match_filename(self):
        """id not matching filename stem should return 1."""
        yaml_content = """---
id: wrong-id
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'correct-id.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)


class TestValidateCorpusSource(unittest.TestCase):
    """Test corpus_source value validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _make_yaml(self, corpus_source):
        """Helper to create a YAML with given corpus_source."""
        yaml_content = f"""---
id: test-cs
version: 1
agent: test-agent
description: Test
corpus_source: {corpus_source}
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {{output_file}}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-cs.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)
        return yaml_path

    def test_corpus_source_honesty_tables(self):
        """corpus_source='honesty_tables' should pass."""
        yaml_path = self._make_yaml('honesty_tables')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_corpus_source_manual(self):
        """corpus_source='manual' should pass."""
        yaml_path = self._make_yaml('manual')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_corpus_source_bats_failure(self):
        """corpus_source='bats_failure' should pass."""
        yaml_path = self._make_yaml('bats_failure')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_corpus_source_agent_run(self):
        """corpus_source='agent_run' should pass."""
        yaml_path = self._make_yaml('agent_run')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_corpus_source_invalid(self):
        """Invalid corpus_source should return 1."""
        yaml_path = self._make_yaml('invalid_source')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)


class TestValidateCostTier(unittest.TestCase):
    """Test cost_tier value validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _make_yaml(self, cost_tier):
        """Helper to create a YAML with given cost_tier."""
        yaml_content = f"""---
id: test-ct
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: {cost_tier}
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {{output_file}}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-ct.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)
        return yaml_path

    def test_cost_tier_cheap(self):
        """cost_tier='cheap' should pass."""
        yaml_path = self._make_yaml('cheap')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_cost_tier_medium(self):
        """cost_tier='medium' should pass."""
        yaml_path = self._make_yaml('medium')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_cost_tier_expensive(self):
        """cost_tier='expensive' should pass."""
        yaml_path = self._make_yaml('expensive')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_cost_tier_invalid(self):
        """Invalid cost_tier should return 1."""
        yaml_path = self._make_yaml('ultra-expensive')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)


class TestValidateGraders(unittest.TestCase):
    """Test grader validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_graders_empty_list_rejected(self):
        """Empty graders list should return 1."""
        yaml_content = """---
id: test-graders
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders: []
"""
        yaml_path = os.path.join(self.tmpdir, 'test-graders.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_grader_missing_id(self):
        """Grader missing 'id' should return 1."""
        yaml_content = """---
id: test-g-id
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-g-id.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_grader_missing_type(self):
        """Grader missing 'type' should return 1."""
        yaml_content = """---
id: test-g-type
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-g-type.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_grader_missing_pass_criteria(self):
        """Grader missing 'pass_criteria' should return 1."""
        yaml_content = """---
id: test-g-pc
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-g-pc.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_grader_missing_on_error(self):
        """Grader missing 'on_error' should return 1."""
        yaml_content = """---
id: test-g-oe
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-g-oe.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)


class TestValidateOnError(unittest.TestCase):
    """Test on_error value validation — 'fail' is forbidden."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_on_error_skip_allowed(self):
        """on_error='skip' should pass."""
        yaml_content = """---
id: test-oe-skip
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-oe-skip.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_on_error_error_allowed(self):
        """on_error='error' should pass."""
        yaml_content = """---
id: test-oe-error
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: error
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-oe-error.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_on_error_fail_rejected(self):
        """on_error='fail' should return 1 — explicitly forbidden."""
        yaml_content = """---
id: test-oe-fail
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: fail
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-oe-fail.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)


class TestValidateProgrammaticGrader(unittest.TestCase):
    """Test programmatic grader command validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_programmatic_grader_requires_command(self):
        """Programmatic grader missing 'command' should return 1."""
        yaml_content = """---
id: test-prog-cmd
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-cmd.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_programmatic_grader_prose_stub_rejected(self):
        """Programmatic grader command that looks like prose should return 1."""
        yaml_content = """---
id: test-prog-stub
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "This is just a prose description of what to check"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-stub.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_programmatic_grader_grep_allowed(self):
        """Programmatic grader with 'grep' token should pass."""
        yaml_content = """---
id: test-prog-grep
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep -c 'Status:' {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-grep.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_programmatic_grader_test_command_allowed(self):
        """Programmatic grader with 'test ' token should pass."""
        yaml_content = """---
id: test-prog-test
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "test -f {output_file} && echo pass"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-test.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_programmatic_grader_python3_allowed(self):
        """Programmatic grader with 'python3' token should pass."""
        yaml_content = """---
id: test-prog-py
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "python3 scripts/check_output.py {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-py.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_programmatic_grader_output_guard(self):
        """{output} in command should return 1 — use {output_file} instead."""
        yaml_content = """---
id: test-prog-output
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "echo '{output}' | grep Status"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-output.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_programmatic_grader_output_file_allowed(self):
        """{output_file} should pass (safe for programmatic graders)."""
        yaml_content = """---
id: test-prog-outfile
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep Status {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-prog-outfile.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)


class TestValidateLlmJudgeGrader(unittest.TestCase):
    """Test llm_judge grader validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_llm_judge_grader_requires_prompt(self):
        """llm_judge grader missing 'prompt' should return 1."""
        yaml_content = """---
id: test-llm-prompt
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: llm_judge
    pass_criteria: "agent_response indicates compliance"
    on_error: skip
"""
        yaml_path = os.path.join(self.tmpdir, 'test-llm-prompt.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_llm_judge_grader_with_prompt(self):
        """llm_judge grader with prompt should pass."""
        yaml_content = """---
id: test-llm-ok
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: llm_judge
    pass_criteria: "agent follows status block format"
    on_error: skip
    prompt: "Does the response include a Status block?"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-llm-ok.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)

    def test_llm_judge_can_use_output_token(self):
        """{output} is allowed in llm_judge prompts (not shell-executed)."""
        yaml_content = """---
id: test-llm-output
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [bad]
graders:
  - id: g1
    type: llm_judge
    pass_criteria: "response good"
    on_error: skip
    prompt: "Review this output: {output}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-llm-output.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)


class TestValidateBehaviors(unittest.TestCase):
    """Test expected_behaviors and forbidden_behaviors validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_expected_behaviors_empty_rejected(self):
        """Empty expected_behaviors should return 1."""
        yaml_content = """---
id: test-exp-empty
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: []
forbidden_behaviors: [test]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-exp-empty.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_forbidden_behaviors_empty_rejected(self):
        """Empty forbidden_behaviors should return 1."""
        yaml_content = """---
id: test-forb-empty
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: []
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-forb-empty.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_both_behaviors_present(self):
        """Both expected and forbidden behaviors present should pass."""
        yaml_content = """---
id: test-behaviors
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors:
  - Agent produces status block
  - Status block is properly formatted
forbidden_behaviors:
  - Agent skips status block
  - Status block has typos
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep Status {output_file}"
"""
        yaml_path = os.path.join(self.tmpdir, 'test-behaviors.yaml')
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 0)


class TestValidateFileValidation(unittest.TestCase):
    """Test file existence and format validation."""

    def setUp(self):
        """Create a temp directory for test files."""
        self.tmpdir = tempfile.mkdtemp(prefix='eval-yaml-test-')

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_file_not_found(self):
        """Non-existent file should return 1."""
        yaml_path = os.path.join(self.tmpdir, 'missing.yaml')
        result = validate_eval_yaml.validate(yaml_path)
        self.assertEqual(result, 1)

    def test_wrong_extension_json(self):
        """.json extension should return 1 (only .yaml/.yml allowed)."""
        json_path = os.path.join(self.tmpdir, 'test.json')
        with open(json_path, 'w') as f:
            f.write('{}')

        result = validate_eval_yaml.validate(json_path)
        self.assertEqual(result, 1)

    def test_wrong_extension_txt(self):
        """.txt extension should return 1."""
        txt_path = os.path.join(self.tmpdir, 'test.txt')
        with open(txt_path, 'w') as f:
            f.write('test')

        result = validate_eval_yaml.validate(txt_path)
        self.assertEqual(result, 1)

    def test_yml_extension_accepted(self):
        """.yml extension should be accepted (not just .yaml)."""
        yaml_content = """---
id: test-yml
version: 1
agent: test-agent
description: Test
corpus_source: manual
failure_type: test
cost_tier: cheap
tags: [test]
trigger: Test
expected_behaviors: [test]
forbidden_behaviors: [test]
graders:
  - id: g1
    type: programmatic
    pass_criteria: "true"
    on_error: skip
    command: "grep test {output_file}"
"""
        yml_path = os.path.join(self.tmpdir, 'test-yml.yml')
        with open(yml_path, 'w') as f:
            f.write(yaml_content)

        result = validate_eval_yaml.validate(yml_path)
        self.assertEqual(result, 0)


if __name__ == '__main__':
    unittest.main()
