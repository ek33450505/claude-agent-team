#!/usr/bin/env bats
# Regression tests for the repo-root anchor fix (2026-08-16) in
# scripts/gen-completions.sh and scripts/gen-rules-manifest.sh.
#
# Both generators used to resolve their working root via a bare
# `cd "$(git rev-parse --show-toplevel)"` — with no `-C`, that resolves
# against the CALLER's cwd at invocation time, not the script's own
# location on disk. A copy of either script run from an unrelated repo
# would silently escape and rewrite THAT repo's tracked files instead of
# the copy's own. This was caught only by planting a phantom string in a
# real tracked file and watching an unrelated suite run erase it.
#
# The fix anchors resolution to the script's own location:
#   cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
#
# Covers, per generator:
#   1. escape is closed: a copy of the generator placed in repo A, run with
#      cwd set to unrelated repo B, writes only into A — B's own tracked
#      output file(s) are byte-for-byte untouched.
#
# Repo B is given real, generator-consumable inputs (its own bin/cast /
# rules-core tree, distinct from A's) rather than empty/missing ones. This
# matters: with the OLD unanchored cd, an escaped run against an EMPTY B
# used to abort outright (`awk: can't open file bin/cast` /
# `find: rules-core: No such file or directory`), so the pre-run/post-run
# comparison below was never actually exercised — the test caught the bug
# only incidentally, via a crash that happened not to occur for every B.
# With real inputs, the OLD code's escaped run SUCCEEDS and clobbers B's
# output with B's own generator-derived content, making the comparison the
# thing that actually fires.
#
# Mutation-tested by hand against a copy carrying the OLD bare
# `cd "$(git rev-parse --show-toplevel)"` line: with the old line, both
# tests fail — at the pre-run/post-run comparison assertion, not at an
# earlier `assert_success` — and restoring the anchor fix makes both pass
# again, byte-identical to the pre-mutation script. See the dispatch report
# for both runs' exact failing-assertion output.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_BIN="$REPO_DIR/bin/cast"
COMPLETIONS="$REPO_DIR/completions/cast.bash"
ZSH_COMPLETIONS="$REPO_DIR/completions/_cast"
COMPLETIONS_GEN="$REPO_DIR/scripts/gen-completions.sh"
RULES_MANIFEST_GEN="$REPO_DIR/scripts/gen-rules-manifest.sh"

@test "gen-completions.sh: does not escape into an unrelated repo B when run with cwd=B" {
  local repoA repoB
  repoA="$(mktemp -d)"
  repoB="$(mktemp -d)"
  git -C "$repoA" init -q
  git -C "$repoB" init -q

  # Repo A: a copy of the generator plus the inputs it needs to run.
  mkdir -p "$repoA/bin" "$repoA/completions" "$repoA/scripts"
  cp "$CAST_BIN" "$repoA/bin/cast"
  cp "$COMPLETIONS" "$repoA/completions/cast.bash"
  cp "$ZSH_COMPLETIONS" "$repoA/completions/_cast"
  cp "$COMPLETIONS_GEN" "$repoA/scripts/gen-completions.sh"

  # Repo B: an unrelated tracked file the generator would have clobbered
  # if it escaped to the ambient cwd instead of resolving from its own
  # location. Same relative path as the file A's copy writes. B also gets
  # its OWN bin/cast with a dispatch table distinct from A's (a fake
  # `b-only-cmd` subcommand) plus real, sentinel-valid copies of the
  # completions files so that an escaped run under the OLD unanchored cd
  # does not merely crash (`awk: can't open file bin/cast` — B previously
  # had no bin/cast at all) — it succeeds and overwrites B's completions
  # with B's OWN dispatch-derived content. Without this, the old code is
  # caught only incidentally (a crash from a file that happens not to
  # exist in B), and the sentinel comparisons below are never actually
  # exercised as the detector.
  mkdir -p "$repoB/bin" "$repoB/completions"
  cp "$COMPLETIONS" "$repoB/completions/cast.bash"
  cp "$ZSH_COMPLETIONS" "$repoB/completions/_cast"
  cat > "$repoB/bin/cast" <<'CASTEOF'
case "$SUBCOMMAND" in
  b-only-cmd)
    echo "b-only-cmd"
    ;;
esac

_cmd_memory() {
  case "$subcmd" in
    search)
      _memory_search "$@"
      ;;
  esac
}
CASTEOF
  local sentinel_bash_before sentinel_zsh_before
  sentinel_bash_before="$(cat "$repoB/completions/cast.bash")"
  sentinel_zsh_before="$(cat "$repoB/completions/_cast")"

  # Run A's copy with the CWD set to B — the exact shape of the original
  # incident (a script run from outside its own repo).
  run bash -c 'cd "$1" && bash "$2"' _ "$repoB" "$repoA/scripts/gen-completions.sh"
  assert_success

  # A's own completions files were written (generator ran successfully).
  run grep -q 'BEGIN GENERATED SUBCOMMANDS' "$repoA/completions/cast.bash"
  assert_success

  # B's sentinel is byte-for-byte untouched.
  run cat "$repoB/completions/cast.bash"
  assert_output "$sentinel_bash_before"
  run cat "$repoB/completions/_cast"
  assert_output "$sentinel_zsh_before"

  rm -rf "$repoA" "$repoB"
}

@test "gen-rules-manifest.sh: does not escape into an unrelated repo B when run with cwd=B" {
  local repoA repoB
  repoA="$(mktemp -d)"
  repoB="$(mktemp -d)"
  git -C "$repoA" init -q
  git -C "$repoB" init -q

  # Repo A: a copy of the generator plus a minimal rules-core tree.
  mkdir -p "$repoA/scripts" "$repoA/rules-core" "$repoA/.github"
  cp "$RULES_MANIFEST_GEN" "$repoA/scripts/gen-rules-manifest.sh"
  printf '# fixture rule\n' > "$repoA/rules-core/fixture.md"

  # Repo B: an unrelated tracked manifest the generator would have
  # clobbered if it escaped to the ambient cwd. B also gets its OWN
  # rules-core/ tree (distinct filename from A's) so that an escaped run
  # under the OLD unanchored cd does not merely crash on a missing
  # `rules-core` directory (find: rules-core: No such file or directory)
  # — it succeeds and overwrites B's manifest. Without this, the old code
  # gets caught only incidentally (a crash from a directory that happens
  # not to exist in B), and the sentinel comparison below is never
  # actually exercised as the detector.
  mkdir -p "$repoB/.github" "$repoB/rules-core"
  printf '# repo B rule — must never be read by A.s generator\n' > "$repoB/rules-core/b-only.md"
  printf 'SENTINEL-DO-NOT-TOUCH  fixture.md\n' > "$repoB/.github/rules-core.manifest"
  local sentinel_before
  sentinel_before="$(cat "$repoB/.github/rules-core.manifest")"

  run bash -c 'cd "$1" && bash "$2"' _ "$repoB" "$repoA/scripts/gen-rules-manifest.sh"
  assert_success

  # B's sentinel is byte-for-byte untouched. Checked BEFORE the "A wrote its
  # own manifest" assertion below: B's rules-core/ fixture above means an
  # escaped OLD-code run succeeds and clobbers B, so if this negative
  # control ran second it would never fire — the earlier "A's manifest
  # exists" check would fail first instead (A is never written when the
  # escape lands in B), masking whether this comparison actually detects a
  # clobber. Ordering it first makes it the assertion that bites.
  run cat "$repoB/.github/rules-core.manifest"
  assert_output "$sentinel_before"

  # A's own manifest was written (generator ran successfully).
  run grep -q 'fixture.md' "$repoA/.github/rules-core.manifest"
  assert_success

  rm -rf "$repoA" "$repoB"
}
