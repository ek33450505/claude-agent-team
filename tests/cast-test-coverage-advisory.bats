#!/usr/bin/env bats
# BATS tests for scripts/cast-test-coverage-advisory.sh
#
# Path precision (test 6) is the reason this script exists: it must match on
# the repo-relative PATH, not the basename — see the script header for the
# measured 187-vs-35 false-positive gap that basename matching produced.

load test_helper/bats-support/load
load test_helper/bats-assert/load

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  export TEST_DIR=$(mktemp -d)
  export TEST_REPO="$TEST_DIR/test-repo"
  mkdir -p "$TEST_REPO/scripts" "$TEST_REPO/bin" "$TEST_REPO/tests"

  cd "$TEST_REPO"
  git init --initial-branch=main >/dev/null 2>&1
  git config user.email "test@example.com"
  git config user.name "BATS Test"

  cp "$REPO_ROOT/scripts/cast-test-coverage-advisory.sh" scripts/
  chmod +x scripts/cast-test-coverage-advisory.sh

  git add scripts/cast-test-coverage-advisory.sh
  git commit -m "seed advisory script" >/dev/null 2>&1
}

teardown() {
  cd "$REPO_ROOT"
  rm -rf "$TEST_DIR"
}

# 1. Positive, specific — output names the covering test and NOT the unrelated one.
@test "advisory: names the covering test file and not an unrelated one" {
  cd "$TEST_REPO"
  cat >tests/alpha.bats <<'EOF'
 @test "covers target" {
  run bash scripts/target.sh
}
EOF
  cat >tests/unrelated.bats <<'EOF'
 @test "covers something else" {
  run bash scripts/other.sh
}
EOF
  cat >scripts/target.sh <<'EOF'
#!/bin/bash
echo "target"
EOF
  git add tests/alpha.bats tests/unrelated.bats scripts/target.sh
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
  assert_output --partial "alpha.bats"
  refute_output --partial "unrelated.bats"
}

# 2. Negative — an orphan script with no covering test is reported explicitly.
@test "advisory: reports explicitly when no test references a scanned file" {
  cd "$TEST_REPO"
  cat >tests/alpha.bats <<'EOF'
 @test "covers target" {
  run bash scripts/target.sh
}
EOF
  cat >scripts/orphan.sh <<'EOF'
#!/bin/bash
echo "orphan"
EOF
  git add tests/alpha.bats scripts/orphan.sh
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
  assert_output --partial "scripts/orphan.sh: no test file references this path"
}

# 3. Count visible — the scanned-count line reports the correct number.
@test "advisory: scanned-count line reports the correct count" {
  cd "$TEST_REPO"
  cat >scripts/one.sh <<'EOF'
#!/bin/bash
echo "one"
EOF
  cat >scripts/two.sh <<'EOF'
#!/bin/bash
echo "two"
EOF
  git add scripts/one.sh scripts/two.sh
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
  assert_output --partial "scanned 2 staged file(s)"
}

# 4. Never blocks — exit status is 0 in every case, including zero coverage.
@test "advisory: exits 0 even when nothing is covered" {
  cd "$TEST_REPO"
  cat >scripts/orphan.sh <<'EOF'
#!/bin/bash
echo "orphan"
EOF
  git add scripts/orphan.sh
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
}

# 5. Non-source excluded — staging only README.md yields a 0 scanned count and exits 0.
@test "advisory: non-scanned paths (e.g. README.md) yield a scanned count of 0" {
  cd "$TEST_REPO"
  echo "# readme" >README.md
  git add README.md
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
  assert_output --partial "scanned 0 staged file(s)"
}

# 6. Path precision — the reason this design exists. A fixture test references
# scripts/other-cast.sh (contains the basename "cast" via "cast.sh") but NOT
# bin/cast. Staging bin/cast must NOT be reported as covered by that test.
# A basename-matching implementation fails this test — that is the point.
@test "advisory: path-precise match — a test referencing scripts/other-cast.sh does not count as covering bin/cast" {
  cd "$TEST_REPO"
  cat >tests/cast-adjacent.bats <<'EOF'
 @test "covers a different cast-named script" {
  run bash scripts/other-cast.sh
}
EOF
  cat >bin/cast <<'EOF'
#!/usr/bin/env bash
echo "cast"
EOF
  git add tests/cast-adjacent.bats bin/cast
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
  assert_output --partial "bin/cast: no test file references this path"
  refute_output --partial "bin/cast: tests/cast-adjacent.bats"
}

# 7. Join separator — multiple covering tests must be joined with comma-space
# ", ", not comma alone. Bash's IFS=', ' only uses the FIRST char of IFS for
# [*] expansion, so a naive `IFS=', '; echo "${listed[*]}"` silently drops the
# space. Fixture filenames are chosen so tests/*.bats glob order (and thus
# grep's match order) is deterministic: aaa.bats sorts before bbb.bats.
@test "advisory: multiple covering tests are joined with comma-space, not comma alone" {
  cd "$TEST_REPO"
  cat >tests/aaa.bats <<'EOF'
 @test "covers target a" {
  run bash scripts/multi.sh
}
EOF
  cat >tests/bbb.bats <<'EOF'
 @test "covers target b" {
  run bash scripts/multi.sh
}
EOF
  cat >scripts/multi.sh <<'EOF'
#!/bin/bash
echo "multi"
EOF
  git add tests/aaa.bats tests/bbb.bats scripts/multi.sh
  run bash scripts/cast-test-coverage-advisory.sh
  assert_success
  assert_output --partial "tests/aaa.bats, tests/bbb.bats"
}
