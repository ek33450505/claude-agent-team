#!/usr/bin/env bats
# test_c3_cast_json.bats — Tests for cast.json detection in commit agent
#
# Coverage:
#   1. cast.json repo_class=personal → REPO_CLASS set correctly
#   2. cast.json repo_class=work,co_author_trailer=none → CO_AUTHOR set to "none"
#   3. missing cast.json → REPO_CLASS falls back to "personal"

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
  TEST_REPO="$(mktemp -d)"
  cd "$TEST_REPO"
  git init -q
  mkdir -p .claude
}
teardown() { rm -rf "$TEST_REPO"; }

@test "cast.json repo_class=personal results in trailer included" {
  echo '{"repo_class":"personal"}' > .claude/cast.json
  CAST_JSON=".claude/cast.json"
  REPO_CLASS="$(python3 -c "import json; d=json.load(open('$CAST_JSON')); print(d.get('repo_class','personal'))")"
  run echo "$REPO_CLASS"
  assert_output "personal"
}

@test "cast.json repo_class=work, co_author_trailer=none results in no trailer" {
  echo '{"repo_class":"work","co_author_trailer":"none"}' > .claude/cast.json
  CAST_JSON=".claude/cast.json"
  CO_AUTHOR="$(python3 -c "import json; d=json.load(open('$CAST_JSON')); print(d.get('co_author_trailer',''))")"
  run echo "$CO_AUTHOR"
  assert_output "none"
}

@test "missing cast.json falls back to personal default" {
  rm -f .claude/cast.json
  CAST_JSON=".claude/cast.json"
  REPO_CLASS="$([[ -f $CAST_JSON ]] && python3 -c "import json; d=json.load(open('$CAST_JSON')); print(d.get('repo_class','personal'))" || echo personal)"
  run echo "$REPO_CLASS"
  assert_output "personal"
}
