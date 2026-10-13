#!/usr/bin/env bash
# cast-release.sh — local, reversible SemVer release steps. Fails closed.
#
# Usage:
#   bash scripts/cast-release.sh prepare <patch|minor|major>
#   bash scripts/cast-release.sh tap <X.Y.Z>
#   bash scripts/cast-release.sh --help
#
# prepare: bumps VERSION, stamps the CHANGELOG, rewrites version tokens in
#          README.md and docs/tutorial/getting-started.md, regenerates the
#          plugin/stats artifacts, and verifies the result. It never commits,
#          tags, or pushes.
# tap:     after the GitHub release exists, rewrites the Homebrew formula
#          (url, sha256, test assertion) in the tap checkout. It never commits
#          or pushes.
#
# Env: CAST_TAP_DIR overrides the tap checkout (default:
#      $(brew --repository)/Library/Taps/ek33450505/homebrew-cast).
#      CAST_RELEASE_REMOTE_URL overrides the release remote used by tap mode
#      (TESTING ONLY; defaults to the GitHub repository URL).

set -euo pipefail

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
REPO_SLUG="ek33450505/claude-agent-team"

# Temp files owned by tap mode; removed by cleanup() on any exit.
_rel_tmp=""
_rel_list=""
_rel_unz=""

cleanup() {
  if [[ -n "$_rel_tmp" ]]; then rm -f "$_rel_tmp"; fi
  if [[ -n "$_rel_list" ]]; then rm -f "$_rel_list"; fi
  if [[ -n "$_rel_unz" ]]; then rm -f "$_rel_unz"; fi
  return 0
}

err() {
  printf 'cast-release: ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'cast-release: %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  cast-release.sh prepare <patch|minor|major>   bump version + docs + regenerate (local edits only)
  cast-release.sh tap <X.Y.Z>                   update the Homebrew tap formula (local edits only)
  cast-release.sh --help

Never commits, tags, or pushes. Fails closed on any unmet precondition.

Environment:
  CAST_TAP_DIR              tap checkout (default: brew --repository tap path)
  CAST_RELEASE_REMOTE_URL   release remote for tap mode; for testing only
                            (default: https://github.com/ek33450505/claude-agent-team.git)
EOF
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || err "not inside a git work tree"
}

# Aborts if the tag exists on origin or if that cannot be determined.
require_tag_absent_on_origin() {
  local root="$1" tag="$2" rc=0
  git -C "$root" ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 || rc=$?
  case "$rc" in
  0) err "tag $tag already exists on origin" ;;
  2) return 0 ;;
  *) err "cannot determine whether $tag exists on origin (git ls-remote rc=$rc); failing closed" ;;
  esac
}

# Prints the commit id the tag points at (peeled if annotated); aborts if the
# tag is absent on the remote or the remote cannot be queried.
remote_tag_commit() {
  local url="$1" tag="$2" rc=0 out
  out="$(git ls-remote --exit-code --tags "$url" "refs/tags/$tag" "refs/tags/$tag^{}" 2>/dev/null)" || rc=$?
  case "$rc" in
  0) ;;
  2) err "tag $tag does not exist on the release remote; create the release first" ;;
  *) err "cannot determine whether $tag exists on the release remote (git ls-remote rc=$rc); failing closed" ;;
  esac
  local peeled plain
  peeled="$(printf '%s\n' "$out" | awk -v p="refs/tags/$tag^{}" '$2==p{print $1}' | head -1)"
  plain="$(printf '%s\n' "$out" | awk -v p="refs/tags/$tag" '$2==p{print $1}' | head -1)"
  if [[ -n "$peeled" ]]; then
    printf '%s\n' "$peeled"
  elif [[ -n "$plain" ]]; then
    printf '%s\n' "$plain"
  else
    err "release remote returned no commit for $tag"
  fi
}

# Edits files in place. Args: root old new today
apply_edits() {
  python3 -I - "$@" <<'PY'
import re
import sys

root, old, new, today = sys.argv[1:5]


def read(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def die(msg):
    sys.stderr.write("cast-release: ERROR: " + msg + "\n")
    sys.exit(1)


# CHANGELOG: stamp the Unreleased section as the new release.
path = root + "/CHANGELOG.md"
text = read(path)
lines = text.split("\n")
done = False
for i, line in enumerate(lines):
    if line.rstrip("\r") == "## [Unreleased]":
        lines[i] = "## [Unreleased]\n\n## [" + new + "] — " + today
        done = True
        break
if not done:
    die("CHANGELOG Unreleased header vanished")
write(path, "\n".join(lines))

tok = re.compile(r"(?<![A-Za-z0-9])v" + re.escape(old) + r"(?![0-9])(?!\.[0-9])")

# README: status line first, then remaining tokens.
path = root + "/README.md"
text = read(path)
text, n = re.subn(
    r"Latest release \*\*v[0-9.]+\*\* \([0-9-]+\)",
    lambda m: "Latest release **v" + new + "** (" + today + ")",
    text,
)
if n == 0:
    die("README status line vanished")
text = tok.sub("v" + new, text)
write(path, text)

path = root + "/docs/tutorial/getting-started.md"
write(path, tok.sub("v" + new, read(path)))
PY
}

# Verifies release artifacts. Args: root old new. Prints problems; exits 1 on any.
verify_release() {
  python3 -I - "$@" <<'PY'
import json
import re
import sys

root, old, new = sys.argv[1:4]
bad = []


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        bad.append(path + ": unreadable (" + str(exc) + ")")
        return {}


if read(root + "/VERSION").strip() != new:
    bad.append("VERSION is not " + new)
plugin = load(root + "/plugin/.claude-plugin/plugin.json")
if plugin.get("version") != new:
    bad.append("plugin/.claude-plugin/plugin.json version is " + repr(plugin.get("version")))
stats = load(root + "/cast-stats.json")
if stats.get("version") != new:
    bad.append("cast-stats.json version is " + repr(stats.get("version")))
if stats.get("versionTag") != "v" + new:
    bad.append("cast-stats.json versionTag is " + repr(stats.get("versionTag")))
readme = read(root + "/README.md")
if "/badge/version-" + new + "-" not in readme:
    bad.append("README.md lacks badge version-" + new + "-")
if "Latest release **v" + new + "**" not in readme:
    bad.append("README.md lacks status line Latest release **v" + new + "**")
stale = re.compile(
    r"(?<![A-Za-z0-9])v" + re.escape(old) + r"(?![0-9])(?!\.[0-9])"
    + r"|version-" + re.escape(old) + r"(?![0-9])(?!\.[0-9])"
)
for rel in ("README.md", "docs/tutorial/getting-started.md"):
    if stale.search(read(root + "/" + rel)):
        bad.append(rel + " still references " + old)
if bad:
    for b in bad:
        sys.stderr.write("cast-release: ERROR: verify: " + b + "\n")
    sys.exit(1)
PY
}

modified_hint() {
  {
    printf 'cast-release: the working tree is now MODIFIED (nothing was committed).\n'
    printf 'cast-release: to review and discard, run these yourself (advice only, not executed):\n'
    printf '  git status --short     # review what changed\n'
    printf '  git checkout -- .      # discard edits to tracked files\n'
    printf '  git clean -n           # preview untracked generator output (nothing is removed by -n)\n'
  } >&2
}

# Runs a generator from the repo root with a pinned CAST_REPO_ROOT so an
# inherited value cannot redirect it.
run_gen() {
  local root="$1" label="$2"
  shift 2
  if ! (cd "$root" && CAST_REPO_ROOT="$root" "$@") >/dev/null; then
    modified_hint
    err "$label failed"
  fi
}

# Prints one of: none | dup | empty | ok
changelog_state() {
  python3 -I - "$1" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    lines = fh.read().split("\n")
heads = 0
in_section = False
in_comment = False
content = False
for raw in lines:
    line = raw.rstrip("\r")
    if line == "## [Unreleased]":
        heads += 1
        in_section = True
        continue
    if not in_section:
        continue
    if line.startswith("## ["):
        in_section = False
        in_comment = False
        continue
    s = line.strip()
    if in_comment:
        if "-->" in s:
            in_comment = False
        continue
    if not s or re.match(r"^#+(\s|$)", s):
        continue
    if s.startswith("<!--"):
        if "-->" not in s:
            in_comment = True
        continue
    content = True
if heads == 0:
    print("none")
elif heads > 1:
    print("dup")
elif content:
    print("ok")
else:
    print("empty")
PY
}

cmd_prepare() {
  local level="${1:-}"
  case "$level" in
  patch | minor | major) ;;
  *)
    usage >&2
    exit 2
    ;;
  esac

  local root
  root="$(repo_root)"

  # ---- preconditions (no edits before all pass) ----
  local porcelain
  porcelain="$(git -C "$root" status --porcelain)" || err "git status failed"
  [[ -z "$porcelain" ]] || err "working tree is not clean (tracked or untracked changes present)"

  local branch
  branch="$(git -C "$root" symbolic-ref -q --short HEAD)" || err "detached HEAD; check out a release branch"
  case "$branch" in
  main | master) err "refusing to prepare a release on $branch; use a release branch" ;;
  esac

  local f
  for f in scripts/gen-plugin.sh scripts/gen-stats.sh scripts/gen-cast-stats.sh \
    README.md docs/tutorial/getting-started.md VERSION CHANGELOG.md; do
    [[ -f "$root/$f" ]] || err "required file missing: $f"
  done

  local old
  old="$(cat "$root/VERSION")"
  [[ "$old" =~ $SEMVER_RE ]] || err "VERSION is not strict X.Y.Z: '$old'"
  local x="${BASH_REMATCH[1]}" y="${BASH_REMATCH[2]}" z="${BASH_REMATCH[3]}"

  local cl_state
  cl_state="$(changelog_state "$root/CHANGELOG.md")" || err "could not inspect CHANGELOG.md"
  case "$cl_state" in
  ok) ;;
  none) err "CHANGELOG.md has no '## [Unreleased]' header" ;;
  dup) err "CHANGELOG.md has more than one '## [Unreleased]' header" ;;
  empty) err "CHANGELOG.md '## [Unreleased]' section has no content (headings and comments do not count)" ;;
  *) err "unexpected CHANGELOG state: $cl_state" ;;
  esac

  grep -Eq 'Latest release \*\*v[0-9.]+\*\* \([0-9-]+\)' "$root/README.md" ||
    err "README.md has no 'Latest release **vX.Y.Z** (YYYY-MM-DD)' status line"

  local new
  case "$level" in
  patch) new="$x.$y.$((z + 1))" ;;
  minor) new="$x.$((y + 1)).0" ;;
  major) new="$((x + 1)).0.0" ;;
  esac

  if git -C "$root" rev-parse -q --verify "refs/tags/v$new" >/dev/null 2>&1; then
    err "tag v$new already exists locally"
  fi
  require_tag_absent_on_origin "$root" "v$new"

  local today
  today="$(date +%F)"

  # ---- edits ----
  info "preparing $old -> $new ($level)"
  printf '%s\n' "$new" >"$root/VERSION"
  if ! apply_edits "$root" "$old" "$new" "$today"; then
    modified_hint
    err "applying edits failed"
  fi

  # ---- regenerate ----
  run_gen "$root" "gen-plugin.sh" bash "$root/scripts/gen-plugin.sh" "$root/plugin"
  run_gen "$root" "gen-stats.sh" bash "$root/scripts/gen-stats.sh"
  run_gen "$root" "gen-cast-stats.sh" bash "$root/scripts/gen-cast-stats.sh"

  # ---- verify ----
  if ! verify_release "$root" "$old" "$new"; then
    modified_hint
    err "verification failed"
  fi

  echo
  info "prepared v$new (was v$old). Changed files:"
  git -C "$root" status --short
  cat <<EOF

Next steps (nothing was committed, tagged, or pushed):
  1. Commit on this branch via the commit agent.
  2. Open a PR and squash-merge it.
  3. Create the release server-side:
       gh release create v$new --target main --notes-file <changelog section for $new>
  4. Update the Homebrew tap:
       bash scripts/cast-release.sh tap $new
EOF
}

sha256_of() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    return 1
  fi
}

# Rewrites the formula in place. Args: formula-path version sha url
rewrite_formula() {
  python3 -I - "$@" <<'PY'
import re
import sys

path, ver, sha, url = sys.argv[1:5]
with open(path, encoding="utf-8", newline="") as fh:
    text = fh.read()


def fail(msg):
    sys.stderr.write("cast-release: ERROR: " + msg + "\n")
    sys.exit(1)


if len(re.findall(r"^[ \t]*sha256[ \t]", text, re.M)) != 1:
    fail("formula must contain exactly one sha256 line")

url_re = re.compile(
    r'^([ \t]*url[ \t]+"[^"\n]*/archive/refs/tags/)v[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz")', re.M
)
sha_re = re.compile(r'^([ \t]*sha256[ \t]+")[0-9a-f]{64}(")', re.M)
assert_re = re.compile(
    r'(assert_match[ \t]+")[0-9]+\.[0-9]+\.[0-9]+(",[ \t]*shell_output\("#\{bin\}/cast --version"\))'
)

for name, rx in (("url", url_re), ("sha256", sha_re), ("assert_match", assert_re)):
    if len(rx.findall(text)) != 1:
        fail("formula pattern '" + name + "' not found exactly once")

text = url_re.sub(lambda m: m.group(1) + "v" + ver + m.group(2), text)
text = sha_re.sub(lambda m: m.group(1) + sha + m.group(2), text)
text = assert_re.sub(lambda m: m.group(1) + ver + m.group(2), text)

written = re.search(r'^[ \t]*url[ \t]+"([^"\n]*)"', text, re.M)
if written is None or written.group(1) != url:
    fail("rewritten formula url does not equal the downloaded url")

with open(path, "w", encoding="utf-8", newline="") as fh:
    fh.write(text)
PY
}

cmd_tap() {
  local ver="${1:-}"
  if [[ -z "$ver" ]]; then
    usage >&2
    exit 2
  fi
  [[ "$ver" =~ $SEMVER_RE ]] || err "version must be X.Y.Z, got '$ver'"

  local remote="${CAST_RELEASE_REMOTE_URL:-https://github.com/$REPO_SLUG.git}"
  if [[ -n "${CAST_RELEASE_REMOTE_URL:-}" ]]; then
    printf 'cast-release: WARN: CAST_RELEASE_REMOTE_URL is set (%s); testing override in use\n' \
      "$CAST_RELEASE_REMOTE_URL" >&2
  fi
  local tag_commit
  tag_commit="$(remote_tag_commit "$remote" "v$ver")"
  [[ "$tag_commit" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || err "release remote returned a malformed commit id for v$ver"

  local tap
  if [[ -n "${CAST_TAP_DIR:-}" ]]; then
    tap="$CAST_TAP_DIR"
  else
    command -v brew >/dev/null 2>&1 || err "brew not found and CAST_TAP_DIR not set"
    tap="$(brew --repository)/Library/Taps/ek33450505/homebrew-cast"
  fi
  [[ -d "$tap" ]] || err "tap directory not found: $tap"
  [[ ! -L "$tap/Formula" && ! -L "$tap/Formula/cast.rb" ]] || err "refusing symlinked Formula path in tap: $tap"
  [[ -f "$tap/Formula/cast.rb" ]] || err "tap formula not found: $tap/Formula/cast.rb"
  local tap_top tap_real
  tap_top="$(git -C "$tap" rev-parse --show-toplevel 2>/dev/null)" || err "tap is not a git work tree: $tap"
  tap_real="$(cd "$tap" && pwd -P)"
  [[ "$tap_top" == "$tap_real" ]] || err "tap directory is not the top level of its git repository ($tap_real vs $tap_top)"
  local tap_status
  tap_status="$(git -C "$tap" status --porcelain)" || err "git status failed in tap $tap"
  [[ -z "$tap_status" ]] || err "tap working tree is not clean: $tap"

  trap cleanup EXIT
  _rel_tmp="$(mktemp "${TMPDIR:-/tmp}/cast-release.XXXXXX")" || err "mktemp failed"
  _rel_list="$(mktemp "${TMPDIR:-/tmp}/cast-release-list.XXXXXX")" || err "mktemp failed"
  _rel_unz="$(mktemp "${TMPDIR:-/tmp}/cast-release-unz.XXXXXX")" || err "mktemp failed"

  local url="https://github.com/$REPO_SLUG/archive/refs/tags/v$ver.tar.gz"
  curl --proto '=https' --proto-redir '=https' --max-redirs 5 \
    --connect-timeout 15 --max-time 300 -fsSL -o "$_rel_tmp" "$url" ||
    err "download failed: $url"
  [[ -s "$_rel_tmp" ]] || err "downloaded tarball is empty: $url"

  # Full listing must succeed: a truncated or corrupt archive fails here.
  tar -tzf "$_rel_tmp" >"$_rel_list" 2>/dev/null ||
    err "download is not a valid gzip tar archive (truncated or corrupt?)"
  local first
  first="$(head -1 "$_rel_list")"
  [[ "$first" == "claude-agent-team-$ver/"* ]] ||
    err "tarball is not rooted at claude-agent-team-$ver/ (first entry: '${first}')"

  # Tie the tarball to the tag commit (GitHub archives embed the commit id).
  local tar_commit
  gzip -dc "$_rel_tmp" >"$_rel_unz" 2>/dev/null || err "gzip could not decompress the tarball"
  tar_commit="$(git get-tar-commit-id <"$_rel_unz" 2>/dev/null || true)"
  [[ -n "$tar_commit" ]] || err "tarball carries no commit id; cannot tie it to the tag"
  [[ "$tar_commit" == "$tag_commit" ]] ||
    err "tarball commit $tar_commit does not match tag v$ver commit $tag_commit"

  local tar_ver
  tar_ver="$(tar -xOzf "$_rel_tmp" "claude-agent-team-$ver/VERSION" 2>/dev/null)" ||
    err "cannot read claude-agent-team-$ver/VERSION from the tarball"
  [[ "$tar_ver" == "$ver" ]] || err "tarball VERSION is '$tar_ver', expected '$ver'"

  local sha
  sha="$(sha256_of "$_rel_tmp")" || err "neither shasum nor sha256sum available"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || err "could not compute sha256"

  rewrite_formula "$tap/Formula/cast.rb" "$ver" "$sha" "$url" || err "formula rewrite failed (formula untouched)"

  info "tap formula updated to v$ver (sha256 $sha)"
  info "trust note: this sha pins what GitHub served for the tag (trust on first use),"
  info "cross-checked against the tag commit $tag_commit."
  git -C "$tap" diff
  cat <<EOF

Next step (nothing was committed or pushed): review the diff above, then commit
and push the tap yourself:
  git -C "$tap" commit -am "cast $ver" && git -C "$tap" push
EOF
}

main() {
  local mode="${1:-}"
  case "$mode" in
  -h | --help | help)
    usage
    ;;
  prepare)
    shift
    cmd_prepare "$@"
    ;;
  tap)
    shift
    cmd_tap "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
}

main "$@"
