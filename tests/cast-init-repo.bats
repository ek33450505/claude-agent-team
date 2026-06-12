#!/usr/bin/env bats
# Tests for `cast init-repo` subcommand (_cmd_init_repo in bin/cast)
#
# Coverage:
#   1. Clean dir: creates .claude/cast.json with repo_class and co_author_trailer, exits 0
#   2. Idempotent: second run prints "Already initialized." and exits 0
#   3. Bitbucket remote: sets repo_class=work
#   4. GitHub remote: sets repo_class=personal

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_CLI="$REPO_ROOT/bin/cast"

setup() {
  load 'helpers/setup'
  setup_temp_home
  export TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
  teardown_temp_home
}

@test "clean dir: creates .claude/cast.json with required fields, exits 0" {
  run bash "$CAST_CLI" init-repo
  assert_success
  assert [ -f "$TEST_DIR/.claude/cast.json" ]

  local repo_class
  repo_class="$(python3 -c "import json; d=json.load(open('$TEST_DIR/.claude/cast.json')); print(d['repo_class'])")"
  assert_equal "$repo_class" "personal"

  local trailer
  trailer="$(python3 -c "import json; d=json.load(open('$TEST_DIR/.claude/cast.json')); print(d['co_author_trailer'])")"
  assert_equal "$trailer" "claude"
}

@test "idempotent: second run prints 'Already initialized.' and exits 0" {
  bash "$CAST_CLI" init-repo >/dev/null 2>&1

  run bash "$CAST_CLI" init-repo
  assert_success
  assert_output --partial "Already initialized."
}

@test "bitbucket remote: sets repo_class=work, co_author_trailer=none" {
  git remote add origin https://bitbucket.org/org/repo.git

  run bash "$CAST_CLI" init-repo
  assert_success
  assert [ -f "$TEST_DIR/.claude/cast.json" ]

  local repo_class
  repo_class="$(python3 -c "import json; d=json.load(open('$TEST_DIR/.claude/cast.json')); print(d['repo_class'])")"
  assert_equal "$repo_class" "work"

  local trailer
  trailer="$(python3 -c "import json; d=json.load(open('$TEST_DIR/.claude/cast.json')); print(d['co_author_trailer'])")"
  assert_equal "$trailer" "none"
}

@test "github remote: sets repo_class=personal, co_author_trailer=claude" {
  git remote add origin https://github.com/user/repo.git

  run bash "$CAST_CLI" init-repo
  assert_success
  assert [ -f "$TEST_DIR/.claude/cast.json" ]

  local repo_class
  repo_class="$(python3 -c "import json; d=json.load(open('$TEST_DIR/.claude/cast.json')); print(d['repo_class'])")"
  assert_equal "$repo_class" "personal"

  local trailer
  trailer="$(python3 -c "import json; d=json.load(open('$TEST_DIR/.claude/cast.json')); print(d['co_author_trailer'])")"
  assert_equal "$trailer" "claude"
}
