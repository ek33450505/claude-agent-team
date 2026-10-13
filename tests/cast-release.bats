#!/usr/bin/env bats
# Tests for scripts/cast-release.sh (prepare + tap modes) against a throwaway
# fixture repo with a bare origin, stub generators, and a PATH-shimmed curl.
# Nothing here touches the real repo, real tap, or real network.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
OLD="1.2.3"

setup() {
  setup_temp_home
  FIX="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  build_fixture
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------- fixtures

fixture_git() {
  git -C "$FIX" "$@"
}

build_fixture() {
  git init -q --bare "$ORIGIN"
  mkdir -p "$FIX/scripts" "$FIX/docs/tutorial" "$FIX/plugin/.claude-plugin"
  git init -q -b main "$FIX"
  fixture_git config user.name "Fixture"
  fixture_git config user.email "fixture@example.invalid"
  fixture_git config commit.gpgsign false
  fixture_git config tag.gpgsign false
  fixture_git remote add origin "$ORIGIN"

  printf '%s\n' "$OLD" >"$FIX/VERSION"
  cat >"$FIX/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- Added a thing

## [1.2.3] — 2026-01-01

- Older thing
EOF
  cat >"$FIX/README.md" <<'EOF'
<img src="https://img.shields.io/badge/version-1.2.3-blue" alt="Version">

> **Status.** Latest release **v1.2.3** (2026-01-01). More text.

Runs on CAST v1.2.3 today. Leave v1.2.31 and v1.2.3.4 alone.
See CAST v1.2.3.
EOF
  cat >"$FIX/docs/tutorial/getting-started.md" <<'EOF'
Install CAST v1.2.3 and go. Pin v1.2.31 stays as is.
EOF
  printf '{"name":"cast","version":"%s"}\n' "$OLD" >"$FIX/plugin/.claude-plugin/plugin.json"
  printf '{"version":"%s","versionTag":"v%s"}\n' "$OLD" "$OLD" >"$FIX/cast-stats.json"

  cat >"$FIX/scripts/gen-plugin.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$(cat "$ROOT/VERSION")"
printf '{"name":"cast","version":"%s"}\n' "$v" >"$1/.claude-plugin/plugin.json"
EOF
  cat >"$FIX/scripts/gen-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$(cat "$ROOT/VERSION")"
sed "s#badge/version-[0-9.]*-#badge/version-${v}-#" "$ROOT/README.md" >"$ROOT/README.md.tmp"
mv "$ROOT/README.md.tmp" "$ROOT/README.md"
EOF
  cat >"$FIX/scripts/gen-cast-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$(cat "$ROOT/VERSION")"
printf '{"version":"%s","versionTag":"v%s"}\n' "$v" "$v" >"$ROOT/cast-stats.json"
EOF
  cp "$REPO_DIR/scripts/cast-release.sh" "$FIX/scripts/cast-release.sh"

  fixture_git add -A
  fixture_git commit -q -m "fixture"
  fixture_git push -q origin main
  fixture_git checkout -q -b release/v1.2.4
}

recommit() {
  fixture_git add -A
  fixture_git commit -q -m "fixture tweak"
}

prepare() {
  (cd "$FIX" && bash scripts/cast-release.sh prepare "$1" 2>&1)
}

json_field() {
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

assert_bumped() {
  local new="$1"
  [ "$(cat "$FIX/VERSION")" = "$new" ]
  [ "$(json_field "$FIX/plugin/.claude-plugin/plugin.json" version)" = "$new" ]
  [ "$(json_field "$FIX/cast-stats.json" version)" = "$new" ]
  [ "$(json_field "$FIX/cast-stats.json" versionTag)" = "v$new" ]
  grep -qF "/badge/version-$new-" "$FIX/README.md"
}

# ------------------------------------------------------------ prepare: happy

@test "help prints usage and exits 0" {
  run bash "$REPO_DIR/scripts/cast-release.sh" --help
  assert_success
  assert_output --partial "prepare <patch|minor|major>"
}

@test "unknown level is a usage error" {
  run prepare bogus
  assert_failure
  assert_output --partial "Usage:"
}

@test "prepare patch bumps 1.2.3 to 1.2.4" {
  run prepare patch
  assert_success
  assert_bumped "1.2.4"
  assert_output --partial "gh release create v1.2.4 --target main"
  assert_output --partial "cast-release.sh tap 1.2.4"
}

@test "prepare minor bumps 1.2.3 to 1.3.0" {
  run prepare minor
  assert_success
  assert_bumped "1.3.0"
}

@test "prepare major bumps 1.2.3 to 2.0.0" {
  run prepare major
  assert_success
  assert_bumped "2.0.0"
}

@test "CHANGELOG gains a dated header and keeps an empty Unreleased" {
  run prepare patch
  assert_success
  local today
  today="$(date +%F)"
  run cat "$FIX/CHANGELOG.md"
  assert_output --partial "## [Unreleased]

## [1.2.4] — $today

- Added a thing"
  # the older release section is untouched
  assert_output --partial "## [1.2.3] — 2026-01-01"
}

@test "README status line and version tokens are replaced; v1.2.31 is untouched" {
  run prepare patch
  assert_success
  local today
  today="$(date +%F)"
  run cat "$FIX/README.md"
  assert_output --partial "Latest release **v1.2.4** ($today)"
  assert_output --partial "Runs on CAST v1.2.4 today."
  assert_output --partial "See CAST v1.2.4."
  assert_output --partial "v1.2.31"
  assert_output --partial "v1.2.3.4"
  refute_output --partial "v1.2.3 "
  run cat "$FIX/docs/tutorial/getting-started.md"
  assert_output --partial "Install CAST v1.2.4 and go."
  assert_output --partial "v1.2.31"
}

@test "prepare never commits, tags, or pushes" {
  local before
  before="$(fixture_git rev-parse HEAD)"
  run prepare patch
  assert_success
  [ "$(fixture_git rev-parse HEAD)" = "$before" ]
  [ -z "$(fixture_git tag -l)" ]
  [ -n "$(fixture_git status --porcelain)" ]
}

# ---------------------------------------------------------- prepare: aborts

@test "abort on dirty tree (untracked file) with no edits made" {
  : >"$FIX/stray.txt"
  run prepare patch
  assert_failure
  assert_output --partial "cast-release: ERROR:"
  assert_output --partial "not clean"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
  [ "$(fixture_git status --porcelain)" = "?? stray.txt" ]
}

@test "abort on dirty tree (tracked modification)" {
  echo "x" >>"$FIX/README.md"
  run prepare patch
  assert_failure
  assert_output --partial "not clean"
}

@test "abort on main" {
  fixture_git checkout -q main
  run prepare patch
  assert_failure
  assert_output --partial "refusing to prepare a release on main"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "abort when Unreleased section is empty" {
  cat >"$FIX/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]


## [1.2.3] — 2026-01-01

- Older thing
EOF
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "section has no content"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
  [ -z "$(fixture_git status --porcelain)" ]
}

@test "abort when CHANGELOG has no Unreleased header" {
  printf '# Changelog\n\n## [1.2.3] — 2026-01-01\n\n- x\n' >"$FIX/CHANGELOG.md"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "has no '## [Unreleased]' header"
}

@test "abort on a duplicate Unreleased header" {
  printf '# Changelog\n\n## [Unreleased]\n\n- a\n\n## [Unreleased]\n\n- b\n' >"$FIX/CHANGELOG.md"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "more than one"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "abort when Unreleased holds only headings and comments" {
  printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n<!-- todo -->\n<!--\nmulti\nline\n-->\n\n## [1.2.3] — 2026-01-01\n\n- x\n' >"$FIX/CHANGELOG.md"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "section has no content"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "Unreleased with a heading plus a real bullet is accepted" {
  printf '# Changelog\n\n## [Unreleased]\n\n### Added\n\n- real\n\n## [1.2.3] — 2026-01-01\n\n- x\n' >"$FIX/CHANGELOG.md"
  recommit
  run prepare patch
  assert_success
}

@test "abort on detached HEAD" {
  fixture_git checkout -q --detach
  run prepare patch
  assert_failure
  assert_output --partial "detached HEAD"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "abort when the README status line is missing, before any edit" {
  sed 's/Latest release/Newest release/' "$FIX/README.md" >"$FIX/README.new"
  mv "$FIX/README.new" "$FIX/README.md"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "status line"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
  [ -z "$(fixture_git status --porcelain)" ]
}

@test "abort when a generator script is missing, before any edit" {
  rm "$FIX/scripts/gen-plugin.sh"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "required file missing: scripts/gen-plugin.sh"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
  [ -z "$(fixture_git status --porcelain)" ]
}

@test "abort when the tutorial file is missing, before any edit" {
  rm "$FIX/docs/tutorial/getting-started.md"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "required file missing: docs/tutorial/getting-started.md"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "abort when VERSION has a leading zero" {
  printf '01.2.3\n' >"$FIX/VERSION"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "VERSION is not strict X.Y.Z"
}

@test "abort when VERSION is not X.Y.Z" {
  printf '1.2\n' >"$FIX/VERSION"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "VERSION is not strict X.Y.Z"
}

@test "abort when the tag already exists locally" {
  fixture_git tag v1.2.4
  run prepare patch
  assert_failure
  assert_output --partial "already exists locally"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "abort when the tag already exists on origin" {
  fixture_git tag v1.2.4
  fixture_git push -q origin v1.2.4
  fixture_git tag -d v1.2.4 >/dev/null
  run prepare patch
  assert_failure
  assert_output --partial "already exists on origin"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
}

@test "abort (fail closed) when origin is unreachable" {
  fixture_git remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  run prepare patch
  assert_failure
  assert_output --partial "failing closed"
  [ "$(cat "$FIX/VERSION")" = "$OLD" ]
  [ -z "$(fixture_git status --porcelain)" ]
}

@test "abort when a generator stub fails, and say the tree is modified" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FIX/scripts/gen-stats.sh"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "gen-stats.sh failed"
  assert_output --partial "MODIFIED"
  assert_output --partial "git status --short"
  assert_output --partial "git checkout -- ."
  assert_output --partial "git clean -n"
  # advice only: the edits are still present
  [ "$(cat "$FIX/VERSION")" = "1.2.4" ]
}

@test "abort when verification finds a stale artifact" {
  # gen-cast-stats stub that forgets to update the version
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FIX/scripts/gen-cast-stats.sh"
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "verify: cast-stats.json version"
  assert_output --partial "MODIFIED"
}

@test "abort when a generator re-inserts the old version token into README" {
  cat >"$FIX/scripts/gen-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$(cat "$ROOT/VERSION")"
sed "s#badge/version-[0-9.]*-#badge/version-${v}-#" "$ROOT/README.md" >"$ROOT/README.md.tmp"
mv "$ROOT/README.md.tmp" "$ROOT/README.md"
printf 'Stale mention: CAST v1.2.3 again.\n' >>"$ROOT/README.md"
EOF
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "README.md still references 1.2.3"
  assert_output --partial "MODIFIED"
}

@test "generators run with CAST_REPO_ROOT pinned to the repo root" {
  local rec="$BATS_TEST_TMPDIR/recorded-root"
  cat >"$FIX/scripts/gen-cast-stats.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${CAST_REPO_ROOT:-unset}" >"$rec"
ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
v="\$(cat "\$ROOT/VERSION")"
printf '{"version":"%s","versionTag":"v%s"}\n' "\$v" "\$v" >"\$ROOT/cast-stats.json"
EOF
  recommit
  export CAST_REPO_ROOT="/nonexistent/elsewhere"
  run prepare patch
  assert_success
  [ "$(cat "$rec")" = "$(cd "$FIX" && pwd -P)" ] || [ "$(cat "$rec")" = "$FIX" ]
}

@test "verify catches a generator that rewrites the README status line back" {
  # Rewrites only the status line to an unrelated version, so the stale-token
  # scan stays quiet and only the status-line check in verify can catch it.
  cat >"$FIX/scripts/gen-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
v="$(cat "$ROOT/VERSION")"
sed -e "s#badge/version-[0-9.]*-#badge/version-${v}-#" \
  -e 's#Latest release \*\*v[0-9.]*\*\*#Latest release **v0.0.1**#' \
  "$ROOT/README.md" >"$ROOT/README.md.tmp"
mv "$ROOT/README.md.tmp" "$ROOT/README.md"
EOF
  recommit
  run prepare patch
  assert_failure
  assert_output --partial "verify: README.md lacks status line Latest release **v1.2.4**"
  refute_output --partial "still references"
}

@test "a bullet-less line starting with a hash-number counts as Unreleased content" {
  printf '# Changelog\n\n## [Unreleased]\n\n#1234 fix the thing\n\n## [1.2.3] — 2026-01-01\n\n- x\n' >"$FIX/CHANGELOG.md"
  recommit
  run prepare patch
  assert_success
}

# ---------------------------------------------------------------------- tap

TAP_VER="1.2.4"

build_tap() {
  TAP="$BATS_TEST_TMPDIR/tap"
  mkdir -p "$TAP/Formula"
  git init -q -b main "$TAP"
  git -C "$TAP" config user.name "Fixture"
  git -C "$TAP" config user.email "fixture@example.invalid"
  git -C "$TAP" config commit.gpgsign false
  cat >"$TAP/Formula/cast.rb" <<'EOF'
class Cast < Formula
  desc "Fixture formula"
  homepage "https://example.invalid"
  url "https://github.com/ek33450505/claude-agent-team/archive/refs/tags/v10.0.1.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  def install
    bin.install "bin/cast"
  end

  test do
    assert_match "10.0.1", shell_output("#{bin}/cast --version")
  end
end
EOF
  git -C "$TAP" add -A
  git -C "$TAP" commit -q -m "tap fixture"
  export CAST_TAP_DIR="$TAP"
}

# release_commit <version> [annotated]: commit VERSION=<version> (plus an
# incompressible blob so truncation tests have a long stream), tag v$TAP_VER
# on it, and push the tag to the fixture origin.
release_commit() {
  printf '%s\n' "$1" >"$FIX/VERSION"
  head -c 20000 /dev/urandom >"$FIX/zz-blob.bin"
  recommit
  if [[ "${2:-}" == "annotated" ]]; then
    fixture_git tag -a -m "release" "v$TAP_VER"
  else
    fixture_git tag "v$TAP_VER"
  fi
  fixture_git push -q origin "v$TAP_VER"
}

# build_tarball <rev> <prefix>: git archive embeds the commit id as GitHub does.
build_tarball() {
  TARBALL="$BATS_TEST_TMPDIR/release.tar.gz"
  fixture_git archive --format=tar.gz --prefix="$2/" -o "$TARBALL" "$1"
  export SHIM_TARBALL="$TARBALL"
}

install_curl_shim() {
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat >"$BATS_TEST_TMPDIR/shim/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s ' "$@" >"${SHIM_ARGV:-/dev/null}"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    out="$2"
    shift
  fi
  shift
done
if [[ -n "${SHIM_CURL_FAIL:-}" ]]; then
  exit 22
fi
cp "$SHIM_TARBALL" "$out"
EOF
  chmod +x "$BATS_TEST_TMPDIR/shim/curl"
  export PATH="$BATS_TEST_TMPDIR/shim:$PATH"
}

run_tap() {
  (cd "$FIX" && bash scripts/cast-release.sh tap "$1" 2>&1)
}

expected_sha() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Tap + curl shim + release remote, with a good tarball for the tagged commit.
tap_setup_ok() {
  build_tap
  install_curl_shim
  export CAST_RELEASE_REMOTE_URL="$ORIGIN"
  release_commit "$TAP_VER" "${1:-}"
  build_tarball "v$TAP_VER" "claude-agent-team-$TAP_VER"
}

@test "tap updates url, sha256 and the test assertion; sha matches the tarball" {
  tap_setup_ok
  run run_tap "$TAP_VER"
  assert_success
  local sha
  sha="$(expected_sha "$TARBALL")"
  run cat "$TAP/Formula/cast.rb"
  assert_output --partial "archive/refs/tags/v$TAP_VER.tar.gz\""
  assert_output --partial "sha256 \"$sha\""
  assert_output --partial "assert_match \"$TAP_VER\", shell_output(\"#{bin}/cast --version\")"
  refute_output --partial "10.0.1"
  # never commits
  [ -n "$(git -C "$TAP" status --porcelain)" ]
  [ "$(git -C "$TAP" rev-list --count HEAD)" = "1" ]
}

@test "tap invokes curl with https-only, redirect, and time limits" {
  tap_setup_ok
  export SHIM_ARGV="$BATS_TEST_TMPDIR/curl-argv"
  run run_tap "$TAP_VER"
  assert_success
  run cat "$SHIM_ARGV"
  assert_output --partial "--proto =https "
  assert_output --partial "--proto-redir =https "
  assert_output --partial "--max-redirs 5 "
  assert_output --partial "--connect-timeout 15 "
  assert_output --partial "--max-time 300 "
  assert_output --partial "https://github.com/ek33450505/claude-agent-team/archive/refs/tags/v$TAP_VER.tar.gz"
}

@test "tap leaves no temp files behind after a successful run" {
  tap_setup_ok
  export TMPDIR="$BATS_TEST_TMPDIR/rel-tmp"
  mkdir -p "$TMPDIR"
  run run_tap "$TAP_VER"
  assert_success
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "tap leaves no temp files behind after a failed run" {
  tap_setup_ok
  echo "later" >"$FIX/extra.txt"
  recommit
  build_tarball HEAD "claude-agent-team-$TAP_VER"
  export TMPDIR="$BATS_TEST_TMPDIR/rel-tmp"
  mkdir -p "$TMPDIR"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "does not match tag"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "tap warns on stderr when the release remote override is in use" {
  tap_setup_ok
  bats_require_minimum_version 1.5.0
  # Not run_tap: that helper merges stderr into stdout, which would hide the stream.
  run --separate-stderr bash -c 'cd "$1" && bash scripts/cast-release.sh tap "$2"' _ "$FIX" "$TAP_VER"
  assert_success
  [[ "$stderr" == *"WARN: CAST_RELEASE_REMOTE_URL is set"* ]]
  [[ "$output" != *"WARN: CAST_RELEASE_REMOTE_URL"* ]]
}

@test "tap accepts an annotated tag (peeled commit is compared)" {
  tap_setup_ok annotated
  run run_tap "$TAP_VER"
  assert_success
}

@test "tap prints the diff, the trust note and the next step" {
  tap_setup_ok
  run run_tap "$TAP_VER"
  assert_success
  assert_output --partial "diff --git"
  assert_output --partial "trust on first use"
  assert_output --partial "push the tap yourself"
}

@test "tap rejects a malformed version" {
  tap_setup_ok
  run run_tap "1.2"
  assert_failure
  assert_output --partial "X.Y.Z"
}

@test "tap aborts when the tag is missing on the release remote" {
  build_tap
  install_curl_shim
  export CAST_RELEASE_REMOTE_URL="$ORIGIN"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "does not exist on the release remote"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts (fail closed) when the release remote is unreachable" {
  tap_setup_ok
  export CAST_RELEASE_REMOTE_URL="$BATS_TEST_TMPDIR/does-not-exist.git"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "failing closed"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when curl fails" {
  tap_setup_ok
  export SHIM_CURL_FAIL=1
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "download failed"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when the tarball is empty" {
  tap_setup_ok
  : >"$BATS_TEST_TMPDIR/empty.tar.gz"
  export SHIM_TARBALL="$BATS_TEST_TMPDIR/empty.tar.gz"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "tarball is empty"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when the download is not a tarball" {
  tap_setup_ok
  echo "<html>404</html>" >"$BATS_TEST_TMPDIR/notatar.tar.gz"
  export SHIM_TARBALL="$BATS_TEST_TMPDIR/notatar.tar.gz"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "not a valid gzip tar archive"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts on a gzip tarball truncated after its first members" {
  tap_setup_ok
  local size
  size="$(wc -c <"$TARBALL" | tr -d ' ')"
  head -c $((size - 200)) "$TARBALL" >"$BATS_TEST_TMPDIR/trunc.tar.gz"
  export SHIM_TARBALL="$BATS_TEST_TMPDIR/trunc.tar.gz"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "not a valid gzip tar archive"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when the tarball top directory is wrong" {
  tap_setup_ok
  build_tarball "v$TAP_VER" "wrong-dir-$TAP_VER"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "is not rooted at claude-agent-team-$TAP_VER/"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when the tarball was built from a different commit" {
  tap_setup_ok
  echo "later" >"$FIX/extra.txt"
  recommit
  build_tarball HEAD "claude-agent-team-$TAP_VER"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "does not match tag v$TAP_VER commit"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when the tarball carries no commit id" {
  tap_setup_ok
  mkdir -p "$BATS_TEST_TMPDIR/plain/claude-agent-team-$TAP_VER"
  echo "$TAP_VER" >"$BATS_TEST_TMPDIR/plain/claude-agent-team-$TAP_VER/VERSION"
  tar -czf "$BATS_TEST_TMPDIR/plain.tar.gz" -C "$BATS_TEST_TMPDIR/plain" "claude-agent-team-$TAP_VER"
  export SHIM_TARBALL="$BATS_TEST_TMPDIR/plain.tar.gz"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "carries no commit id"
}

@test "tap aborts when the tarball VERSION differs from the requested version" {
  build_tap
  install_curl_shim
  export CAST_RELEASE_REMOTE_URL="$ORIGIN"
  release_commit "9.9.9"
  build_tarball "v$TAP_VER" "claude-agent-team-$TAP_VER"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "tarball VERSION is '9.9.9'"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}

@test "tap aborts when the tap tree is dirty" {
  tap_setup_ok
  : >"$TAP/stray"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "tap working tree is not clean"
}

@test "tap aborts when the tap directory is missing" {
  tap_setup_ok
  export CAST_TAP_DIR="$BATS_TEST_TMPDIR/no-such-tap"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "tap directory not found"
}

@test "tap aborts when the formula is missing" {
  tap_setup_ok
  git -C "$TAP" rm -q Formula/cast.rb
  git -C "$TAP" commit -q -m "drop formula"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "tap formula not found"
}

@test "tap aborts when the tap dir is a subdirectory of a repository" {
  tap_setup_ok
  mkdir -p "$TAP/sub/Formula"
  cp "$TAP/Formula/cast.rb" "$TAP/sub/Formula/cast.rb"
  export CAST_TAP_DIR="$TAP/sub"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "not the top level of its git repository"
}

@test "tap aborts when Formula/cast.rb is a symlink" {
  tap_setup_ok
  mv "$TAP/Formula/cast.rb" "$TAP/real-cast.rb"
  ln -s ../real-cast.rb "$TAP/Formula/cast.rb"
  git -C "$TAP" add -A
  git -C "$TAP" commit -q -m "symlink formula"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "symlinked Formula path"
}

@test "tap aborts when a formula pattern is not found exactly once" {
  tap_setup_ok
  sed 's#assert_match "10.0.1"#assert_match "latest"#' "$TAP/Formula/cast.rb" >"$TAP/Formula/cast.rb.new"
  mv "$TAP/Formula/cast.rb.new" "$TAP/Formula/cast.rb"
  git -C "$TAP" add -A
  git -C "$TAP" commit -q -m "drop assert"
  run run_tap "$TAP_VER"
  assert_failure
  assert_output --partial "assert_match"
  [ -z "$(git -C "$TAP" status --porcelain)" ]
}
