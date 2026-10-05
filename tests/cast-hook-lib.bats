#!/usr/bin/env bats
# Tests for scripts/cast-hook-lib.sh
# Covers: cast_hook_read_stdin (empty, piped input), cast_hook_db_path (CAST_DB_PATH override, fallback)
# and re-source guard (_CAST_HOOK_LIB_LOADED), and cast_git_safe (hostile-repo hardening:
# fsmonitor, filter drivers, config-based hooks, submodule-only filters (status/diff/diff-files/
# diff-index), inherited GIT_DIR, ambient GIT_CONFIG_COUNT, fail-closed config read, leading-option
# rejection, promisor lazy-fetch ext::, arg guard, behaviour + caller hygiene, diff.<drv>.command/
# textconv suppression on the diff family, commit/tag/push gpgSign=false, missing-subcommand rc 2).
# Uses isolated temp HOME + temp CAST_DB_PATH — never touches real ~/.claude.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK_LIB="$REPO_DIR/scripts/cast-hook-lib.sh"

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
  mkdir -p "$HOME/.claude"
}

teardown() {
  teardown_temp_home
}

# --- cast_hook_read_stdin: piped input ---

@test "cast_hook_read_stdin captures piped input" {
  run bash -c "source '$HOOK_LIB'; cast_hook_read_stdin; echo \"\$INPUT\"" <<< 'hello'
  assert_success
  assert_output "hello"
}

@test "cast_hook_read_stdin handles multiline input" {
  run bash -c "source '$HOOK_LIB'; cast_hook_read_stdin; echo \"\$INPUT\"" <<< $'line1\nline2'
  assert_success
  assert_output "line1
line2"
}

# --- cast_hook_read_stdin: empty/closed stdin ---

@test "cast_hook_read_stdin with empty stdin sets INPUT to empty string" {
  run bash -c ". '$HOOK_LIB'; printf '' | cast_hook_read_stdin; echo \"[\$INPUT]\""
  assert_success
  assert_output "[]"
}

@test "cast_hook_read_stdin exits 0 on closed stdin (never aborts)" {
  run bash -c ". '$HOOK_LIB'; cast_hook_read_stdin </dev/null; echo ok"
  assert_success
  assert_output "ok"
}

# --- cast_hook_db_path: CAST_DB_PATH override ---

@test "cast_hook_db_path uses CAST_DB_PATH when set" {
  run bash -c "export CAST_DB_PATH='/custom/path.db'; . '$HOOK_LIB'; cast_hook_db_path; echo \"\$DB_PATH\""
  assert_success
  assert_output "/custom/path.db"
}

# --- cast_hook_db_path: fallback to HOME ---

@test "cast_hook_db_path falls back to \$HOME/.claude/cast.db when CAST_DB_PATH unset" {
  run bash -c "unset CAST_DB_PATH; . '$HOOK_LIB'; cast_hook_db_path; echo \"\$DB_PATH\""
  assert_success
  assert_output "$HOME/.claude/cast.db"
}

# --- Re-source guard ---

@test "re-sourcing cast-hook-lib.sh returns early and keeps functions defined" {
  run bash -c "
    . '$HOOK_LIB'
    old_func=\"\$(declare -f cast_hook_read_stdin)\"
    . '$HOOK_LIB'  # second source
    new_func=\"\$(declare -f cast_hook_read_stdin)\"
    [[ \"\$old_func\" == \"\$new_func\" ]] && echo 'functions identical'
  "
  assert_success
  assert_output "functions identical"
}

@test "sourcing multiple times does not error" {
  run bash -c "
    . '$HOOK_LIB'
    . '$HOOK_LIB'
    . '$HOOK_LIB'
    echo 'ok'
  "
  assert_success
  assert_output "ok"
}

# --- cast_git_safe: hostile-repo hardening ---
#
# Every probe has a CONTROL: the same git command run plainly MUST create the marker file,
# proving the probe can detect execution. Only then must cast_git_safe leave it absent.
# All fixtures live under $BATS_TEST_TMPDIR; canaries only `touch` a marker file.

# _hl_run_safe <repo-dir> <git-args...> — cast_git_safe under the caller's set -euo pipefail.
_hl_run_safe() {
  run bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$@"
}

# _hl_mode <path> — octal permission bits; BSD vs GNU stat chosen by $OSTYPE (GNU `stat -f` is
# filesystem status and succeeds, so a `stat -f … || stat -c …` fallback never runs on Linux).
_hl_mode() {
  if [[ "$OSTYPE" == darwin* ]]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

# _hl_repo <dir> — a repo with one committed file (tracked.txt).
_hl_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'one\n' > "$1/tracked.txt"
  git -C "$1" add tracked.txt
  git -C "$1" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init
}

# _hl_canary <script> <marker> [cat] — executable script that touches <marker>; with "cat" it
# then drains stdin (a clean-filter driver is fed the file on stdin).
_hl_canary() {
  printf '#!/bin/sh\ntouch "%s"\n' "$2" > "$1"
  if [ "${3:-}" = cat ]; then printf 'cat\n' >> "$1"; fi
  printf 'exit 0\n' >> "$1"
  chmod +x "$1"
}

# _hl_dirty <file> <stamp> — make a committed file stat-dirty (same content, new mtime) so a
# status run must re-hash it (and therefore run any clean filter). A plain `git status` refreshes
# the index, so the caller re-dirties with a NEW stamp before every run it cares about.
_hl_dirty() {
  touch -t "$2" "$1"
}

# _hl_sub_fixture <repo> <marker> — a superproject <repo> with a populated submodule "sm" whose OWN
# config (not the superproject's) defines filter.evil.clean=<canary>; sm/.gitattributes maps every
# file to it. Built locally, no network.
_hl_sub_fixture() {
  local sub="$BATS_TEST_TMPDIR/sm-src"
  _hl_repo "$sub"
  printf '* filter=evil\n' > "$sub/.gitattributes"
  git -C "$sub" add .gitattributes
  git -C "$sub" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m attrs
  _hl_repo "$1"
  git -C "$1" -c protocol.file.allow=always submodule add -q "$sub" sm > /dev/null 2>&1
  git -C "$1" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m "add sm"
  _hl_canary "$BATS_TEST_TMPDIR/sm-canary.sh" "$2" cat
  git -C "$1/sm" config filter.evil.clean "$BATS_TEST_TMPDIR/sm-canary.sh"
  # Precondition: the SUPERPROJECT's own (local) config defines no filter; only the submodule's does.
  # --local: global/system config may legitimately define filters (e.g. git-lfs on CI runners).
  [ -z "$(git -C "$1" config --local --get-regexp '^filter\.' || true)" ]
}

# _hl_sub_probe <repo> <marker> <stamp-control> <stamp-safe> <git-args...> — CONTROL (plain git
# must fire the submodule filter), then the hardened run (must not). Re-dirties before each run.
_hl_sub_probe() {
  local repo="$1" marker="$2" s1="$3" s2="$4"
  shift 4
  _hl_dirty "$repo/sm/tracked.txt" "$s1"
  git -C "$repo" "$@" > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_dirty "$repo/sm/tracked.txt" "$s2"
  _hl_run_safe "$repo" "$@"
  assert_success
  [ ! -e "$marker" ]
}

# _hl_shim — a PATH shim for git that logs every call to $SHIM_LOG, fails any `--get-regexp` call
# (the hardening read) with $SHIM_CONFIG_RC, and otherwise execs the real git ($REAL_GIT).
_hl_shim() {
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat > "$BATS_TEST_TMPDIR/shim/git" << 'SHIM'
#!/bin/sh
echo "$*" >> "$SHIM_LOG"
case "$*" in
  *--get-regexp*) exit "${SHIM_CONFIG_RC:-128}" ;;
esac
exec "$REAL_GIT" "$@"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/git"
  # The lib refuses a git in a group/other-writable dir; pin the shim dir's mode.
  chmod 755 "$BATS_TEST_TMPDIR/shim"
}

# _hl_lib_with_git <git-path> — prints the path of a COPY of the lib whose trusted-git list is just
# <git-path> (the lib never consults PATH for git, so a PATH shim cannot be used). Fails the test if
# the substitution did not apply (a vacuous shim would silently run the real git).
_hl_lib_with_git() {
  local out="$BATS_TEST_TMPDIR/lib-shimmed.sh"
  sed "s|^  local git_candidates=(.*)\$|  local git_candidates=(\"$1\")|" "$HOOK_LIB" > "$out"
  grep -qF "local git_candidates=(\"$1\")" "$out"
  printf '%s' "$out"
}

# _hl_run_shimmed <config-rc> <log> <repo-dir> <git-args...> — cast_git_safe through the shim.
_hl_run_shimmed() {
  local rc="$1" log="$2" real lib
  real="$(command -v git)"
  shift 2
  lib="$(_hl_lib_with_git "$BATS_TEST_TMPDIR/shim/git")"
  run env SHIM_LOG="$log" SHIM_CONFIG_RC="$rc" REAL_GIT="$real" \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$lib" "$@"
}

@test "cast_git_safe: core.fsmonitor canary does not run (control fires)" {
  local repo="$BATS_TEST_TMPDIR/fsm" marker="$BATS_TEST_TMPDIR/fsm.marker"
  _hl_repo "$repo"
  _hl_canary "$BATS_TEST_TMPDIR/fsm-canary.sh" "$marker"
  git -C "$repo" config core.fsmonitor "$BATS_TEST_TMPDIR/fsm-canary.sh"
  # CONTROL: plain git must execute the planted fsmonitor program.
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
}

@test "cast_git_safe: filter.<drv>.clean canary does not run (control fires)" {
  local repo="$BATS_TEST_TMPDIR/flt" marker="$BATS_TEST_TMPDIR/flt.marker"
  _hl_repo "$repo"
  printf '* filter=evil\n' > "$repo/.gitattributes"
  git -C "$repo" add .gitattributes
  git -C "$repo" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m attrs
  _hl_canary "$BATS_TEST_TMPDIR/flt-canary.sh" "$marker" cat
  git -C "$repo" config filter.evil.clean "$BATS_TEST_TMPDIR/flt-canary.sh"
  # CONTROL: plain git re-hashes the stat-dirty file through the clean filter.
  _hl_dirty "$repo/tracked.txt" 202001010000
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  # Re-dirty with a NEW stamp (the control refreshed the index), then the hardened run.
  _hl_dirty "$repo/tracked.txt" 202002020000
  _hl_run_safe "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
}

@test "cast_git_safe: filter driver name containing '=' is still blanked (control fires)" {
  local repo="$BATS_TEST_TMPDIR/flteq" marker="$BATS_TEST_TMPDIR/flteq.marker"
  _hl_repo "$repo"
  printf '* filter=a=b\n' > "$repo/.gitattributes"
  git -C "$repo" add .gitattributes
  git -C "$repo" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m attrs
  _hl_canary "$BATS_TEST_TMPDIR/flteq-canary.sh" "$marker" cat
  if ! git -C "$repo" config 'filter.a=b.clean' "$BATS_TEST_TMPDIR/flteq-canary.sh"; then
    skip "git rejects '=' in a filter driver name"
  fi
  # CONTROL
  _hl_dirty "$repo/tracked.txt" 202001010000
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_dirty "$repo/tracked.txt" 202002020000
  _hl_run_safe "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
}

@test "cast_git_safe: filter.<drv>.process canary does not run (control fires)" {
  local repo="$BATS_TEST_TMPDIR/fltp" marker="$BATS_TEST_TMPDIR/fltp.marker"
  _hl_repo "$repo"
  printf '* filter=evil\n' > "$repo/.gitattributes"
  git -C "$repo" add .gitattributes
  git -C "$repo" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m attrs
  _hl_canary "$BATS_TEST_TMPDIR/fltp-canary.sh" "$marker"
  git -C "$repo" config filter.evil.process "$BATS_TEST_TMPDIR/fltp-canary.sh"
  # CONTROL
  _hl_dirty "$repo/tracked.txt" 202001010000
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_dirty "$repo/tracked.txt" 202002020000
  _hl_run_safe "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
}

@test "cast_git_safe: promisor lazy-fetch ext:: canary does not run (control fires)" {
  local src="$BATS_TEST_TMPDIR/lf-src" bare="$BATS_TEST_TMPDIR/lf.git" clone="$BATS_TEST_TMPDIR/lf-clone"
  local marker="$BATS_TEST_TMPDIR/lf.marker" ext="$BATS_TEST_TMPDIR/lf-ext.sh" blob
  _hl_repo "$src"
  git clone -q --bare "$src" "$bare"
  git -C "$bare" config uploadpack.allowFilter true
  git -C "$bare" config uploadpack.allowAnySHA1InWant true
  git clone -q --no-checkout --filter=blob:none "file://$bare" "$clone"
  blob="$(git -C "$bare" rev-parse HEAD:tracked.txt)"
  # Precondition: the blob really is missing locally (so reading it needs a lazy fetch).
  run env GIT_NO_LAZY_FETCH=1 git -C "$clone" cat-file -e "$blob"
  assert_failure
  # Point the promisor remote at an ext:: transport that runs the canary.
  _hl_canary "$ext" "$marker"
  git -C "$clone" config remote.origin.url "ext::$ext"
  git -C "$clone" config protocol.ext.allow always
  # CONTROL: plain git lazily fetches the missing blob through the ext:: remote.
  git -C "$clone" cat-file -p "$blob" > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$clone" cat-file -p "$blob"
  assert_failure
  [ ! -e "$marker" ]
}

@test "cast_git_safe: empty or dash-leading repo-dir returns 2 and runs no git" {
  local cwdrepo="$BATS_TEST_TMPDIR/cwd" marker="$BATS_TEST_TMPDIR/cwd.marker"
  _hl_repo "$cwdrepo"
  _hl_canary "$BATS_TEST_TMPDIR/cwd-canary.sh" "$marker"
  git -C "$cwdrepo" config core.fsmonitor "$BATS_TEST_TMPDIR/cwd-canary.sh"
  cd "$cwdrepo"
  # CONTROL: plain git in the CWD repo would run the canary.
  git status --porcelain > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "" status
  assert_failure 2
  _hl_run_safe "-x" status
  assert_failure 2
  _hl_run_safe "--version"
  assert_failure 2
  [ ! -e "$marker" ]
}

@test "cast_git_safe: behaviour preserved on a benign repo (output and exit status are git's own)" {
  local repo="$BATS_TEST_TMPDIR/benign" plain_top plain_status plain_rc safe_rc
  _hl_repo "$repo"
  printf 'dirty\n' >> "$repo/tracked.txt"
  git -C "$repo" config filter.nodot value # key with no driver segment: enumerated, skipped
  plain_top="$(git -C "$repo" rev-parse --show-toplevel)"
  plain_status="$(git -C "$repo" status --porcelain)"
  [ "$plain_status" = " M tracked.txt" ] # non-vacuous: the dirty file really is reported
  _hl_run_safe "$repo" rev-parse --show-toplevel
  assert_success
  assert_output "$plain_top"
  _hl_run_safe "$repo" status --porcelain
  assert_success
  assert_output "$plain_status"
  plain_rc=0
  git -C "$repo" rev-parse --verify -q refs/heads/nope > /dev/null 2>&1 || plain_rc=$?
  _hl_run_safe "$repo" rev-parse --verify -q refs/heads/nope
  safe_rc="$status"
  [ "$plain_rc" -ne 0 ]
  [ "$safe_rc" -eq "$plain_rc" ]
}

@test "cast_git_safe: leaks no variables, functions or exports into the caller" {
  local repo="$BATS_TEST_TMPDIR/hyg"
  _hl_repo "$repo"
  git -C "$repo" config filter.x.clean cat # exercise the enumeration loop's locals too
  run bash -c '
    set -euo pipefail
    . "$1"
    vars_before= funcs_before= vars_after= funcs_after= count_before= count_after=
    vars_before="$(compgen -v | sort)"
    funcs_before="$(declare -F | sort)"
    # The ambient env may already carry GIT_CONFIG_COUNT (e.g. a sandbox): compare, not "unset".
    count_before="${GIT_CONFIG_COUNT-<unset>}"
    cast_git_safe "$2" status --porcelain > /dev/null
    vars_after="$(compgen -v | sort)"
    funcs_after="$(declare -F | sort)"
    count_after="${GIT_CONFIG_COUNT-<unset>}"
    [ "$count_before" = "$count_after" ] || { echo "GIT_CONFIG_COUNT changed: $count_before -> $count_after"; exit 1; }
    [ "$vars_before" = "$vars_after" ] || { echo "VARS LEAKED"; diff <(echo "$vars_before") <(echo "$vars_after"); exit 1; }
    [ "$funcs_before" = "$funcs_after" ] || { echo "FUNCS LEAKED"; exit 1; }
    for v in _n _env _key _drv _k dir n key name drv knob cfg rc unset_env env_assignments; do
      [ -z "${!v+x}" ] || { echo "leaked: $v"; exit 1; }
    done
    echo clean
  ' _ "$HOOK_LIB" "$repo"
  assert_success
  assert_output "clean"
}

# H1: git 2.54+ config-based hooks (hook.<name>.event/.command) are NOT gated by core.hooksPath.
@test "cast_git_safe: config-based hooks (hook.<name>.command) do not run on branch -d (control fires)" {
  local repo="$BATS_TEST_TMPDIR/hook" m1="$BATS_TEST_TMPDIR/hook1.marker" m2="$BATS_TEST_TMPDIR/hook2.marker"
  _hl_repo "$repo"
  _hl_canary "$BATS_TEST_TMPDIR/hook1-canary.sh" "$m1" cat
  _hl_canary "$BATS_TEST_TMPDIR/hook2-canary.sh" "$m2" cat
  git -C "$repo" branch doomed
  git -C "$repo" config hook.x.event reference-transaction
  git -C "$repo" config hook.x.command "$BATS_TEST_TMPDIR/hook1-canary.sh"
  # A second hook whose NAME contains '.' and '=' (the last ".<knob>" is what gets stripped).
  git -C "$repo" config 'hook.v1.2=x.event' reference-transaction
  git -C "$repo" config 'hook.v1.2=x.command' "$BATS_TEST_TMPDIR/hook2-canary.sh"
  # CONTROL: plain git runs both config hooks when the ref transaction happens.
  git -C "$repo" branch -d doomed > /dev/null 2>&1 || true
  if [ ! -e "$m1" ] || [ ! -e "$m2" ]; then
    skip "config-based hooks need git >= 2.54"
  fi
  git -C "$repo" branch doomed # re-create (this fires the hooks again)
  rm -f "$m1" "$m2"
  _hl_run_safe "$repo" branch -d doomed
  assert_success
  [ ! -e "$m1" ]
  [ ! -e "$m2" ]
  [ -z "$(git -C "$repo" branch --list doomed)" ] # the delete itself still happened
}

# H2: a filter defined ONLY in a populated submodule's own config runs during `status` unless
# submodules are ignored (the superproject-level enumeration cannot see it).
@test "cast_git_safe: filter defined only in a submodule's own config does not run on status (control fires)" {
  local repo="$BATS_TEST_TMPDIR/sm" marker="$BATS_TEST_TMPDIR/sm.marker"
  _hl_sub_fixture "$repo" "$marker"
  # CONTROL (inside the probe): plain git status descends into the submodule and re-hashes through
  # its filter. NOTE: the caller passes no --ignore-submodules; the helper injects it.
  _hl_sub_probe "$repo" "$marker" 202001010000 202002020000 status --porcelain
}

# M-2: the injection also covers diff, diff-files and diff-index (each descends into submodules).
@test "cast_git_safe: submodule-only filter does not run on diff / diff-files / diff-index (controls fire)" {
  local repo="$BATS_TEST_TMPDIR/smd" marker="$BATS_TEST_TMPDIR/smd.marker"
  _hl_sub_fixture "$repo" "$marker"
  _hl_sub_probe "$repo" "$marker" 202001010000 202002020000 diff-files
  _hl_sub_probe "$repo" "$marker" 202003030000 202004040000 diff-index HEAD
  _hl_sub_probe "$repo" "$marker" 202005050000 202006060000 diff
}

# M2: an inherited GIT_DIR (e.g. a caller invoked from a git hook) overrides -C.
@test "cast_git_safe: inherited GIT_DIR does not redirect git to another repo (control: it does for plain git)" {
  local repo="$BATS_TEST_TMPDIR/gd-repo" other="$BATS_TEST_TMPDIR/gd-other" want other_dir plain
  _hl_repo "$repo"
  _hl_repo "$other"
  want="$(git -C "$repo" rev-parse --absolute-git-dir)"
  other_dir="$(git -C "$other" rev-parse --absolute-git-dir)"
  [ "$want" != "$other_dir" ]
  # CONTROL: plain git honours the inherited GIT_DIR over -C.
  plain="$(GIT_DIR="$other/.git" git -C "$repo" rev-parse --absolute-git-dir)"
  [ "$plain" = "$other_dir" ]
  run env GIT_DIR="$other/.git" bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$repo" rev-parse --absolute-git-dir
  assert_success
  assert_output "$want"
}

# M-1a: an ambient GIT_CONFIG_COUNT must not break the hardening read (it used to: a malformed
# count made the read die, `|| true` swallowed it, the filter list came back empty and nothing was
# blanked). Probed with a filter canary (works on every git version, unlike config hooks).
@test "cast_git_safe: ambient GIT_CONFIG_COUNT, malformed or well-formed, neither blinds nor defeats the hardening (control fires)" {
  local repo="$BATS_TEST_TMPDIR/amb" marker="$BATS_TEST_TMPDIR/amb.marker"
  _hl_repo "$repo"
  printf '* filter=evil\n' > "$repo/.gitattributes"
  git -C "$repo" add .gitattributes
  git -C "$repo" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m attrs
  _hl_canary "$BATS_TEST_TMPDIR/amb-canary.sh" "$marker" cat
  git -C "$repo" config filter.evil.clean "$BATS_TEST_TMPDIR/amb-canary.sh"
  # CONTROL 1: plain git fires the filter on a stat-dirty file.
  _hl_dirty "$repo/tracked.txt" 202001010000
  git -C "$repo" status --porcelain > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  # CONTROL 2: COUNT=12 with sparse keys really is fatal to plain git (so the read really would die).
  run env GIT_CONFIG_COUNT=12 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/nonexistent \
    git -C "$repo" status --porcelain
  assert_failure
  # Malformed ambient count: hardening still established, filter blanked.
  _hl_dirty "$repo/tracked.txt" 202002020000
  run env GIT_CONFIG_COUNT=12 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/nonexistent \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
  # Well-formed ambient count: still works, filter still blanked.
  _hl_dirty "$repo/tracked.txt" 202003030000
  run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/nonexistent \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
}

# M-1b: fail CLOSED. If the hardening read fails for ANY reason (rc other than 0/1) the helper
# returns 3 and never runs git. Driven through a git shim so the failure is independent of (a).
@test "cast_git_safe: failed hardening read returns 3 and runs no git; rc 1 (no matches) proceeds" {
  local repo="$BATS_TEST_TMPDIR/fc" log="$BATS_TEST_TMPDIR/shim.log"
  _hl_repo "$repo"
  _hl_shim
  # CONTROL: read rc 1 = "no matches" is fine; both the read and the main call ran.
  _hl_run_shimmed 1 "$log" "$repo" status --porcelain
  assert_success
  # Two calls: hardening read, main call.
  [ "$(grep -c . "$log")" -eq 2 ]
  rm -f "$log"
  # Read rc 128 (git died): fail closed, only the read happened.
  _hl_run_shimmed 128 "$log" "$repo" status --porcelain
  assert_failure 3
  assert_output --partial "git NOT run"
  # Only the failed read; the main call (--no-pager) never happened.
  [ "$(grep -c . "$log")" -eq 1 ]
  grep -q -- '--get-regexp' "$log"
  [ "$(grep -c -- '--no-pager' "$log")" -eq 0 ]
  rm -f "$log"
  # Any other rc is fail-closed too.
  _hl_run_shimmed 2 "$log" "$repo" status --porcelain
  assert_failure 3
  [ "$(grep -c . "$log")" -eq 1 ]
  [ "$(grep -c -- '--no-pager' "$log")" -eq 0 ]
}

# M-2: a leading option hides the subcommand from the --ignore-submodules injection, so reject it.
@test "cast_git_safe: a first git arg starting with '-' returns 2 and runs no git" {
  local repo="$BATS_TEST_TMPDIR/lo" log="$BATS_TEST_TMPDIR/shim.log"
  _hl_repo "$repo"
  _hl_shim
  # CONTROL: subcommand first runs git (through the shim, so the log proves it).
  _hl_run_shimmed 1 "$log" "$repo" status --porcelain
  assert_success
  [ -s "$log" ]
  rm -f "$log"
  _hl_run_shimmed 1 "$log" "$repo" -c x=y status
  assert_failure 2
  [ ! -e "$log" ]
  _hl_run_shimmed 1 "$log" "$repo" --no-pager status
  assert_failure 2
  [ ! -e "$log" ]
}

# --- U3a-r2: diff family (--no-ext-diff/--no-textconv), gpgSign, missing subcommand ---

# _hl_diff_fixture <repo> — a repo whose tracked.txt is modified in the worktree and mapped to the
# diff driver "evil" by .gitattributes (untracked: attributes are read from the worktree).
_hl_diff_fixture() {
  _hl_repo "$1"
  printf '*.txt diff=evil\n' > "$1/.gitattributes"
  printf 'two\n' > "$1/tracked.txt"
}

@test "cast_git_safe: diff.<drv>.command canary does not run on diff (control fires)" {
  local repo="$BATS_TEST_TMPDIR/dcmd" marker="$BATS_TEST_TMPDIR/dcmd.marker"
  _hl_diff_fixture "$repo"
  _hl_canary "$BATS_TEST_TMPDIR/dcmd-canary.sh" "$marker"
  git -C "$repo" config diff.evil.command "$BATS_TEST_TMPDIR/dcmd-canary.sh"
  # CONTROL: plain git diff runs the external diff program.
  git -C "$repo" diff > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$repo" diff
  assert_success
  assert_output --partial '+two'
  [ ! -e "$marker" ]
}

@test "cast_git_safe: diff.<drv>.textconv canary does not run on diff (control fires)" {
  local repo="$BATS_TEST_TMPDIR/dtc" marker="$BATS_TEST_TMPDIR/dtc.marker"
  _hl_diff_fixture "$repo"
  printf '#!/bin/sh\ntouch "%s"\ncat "$1"\n' "$marker" > "$BATS_TEST_TMPDIR/dtc-canary.sh"
  chmod +x "$BATS_TEST_TMPDIR/dtc-canary.sh"
  git -C "$repo" config diff.evil.textconv "$BATS_TEST_TMPDIR/dtc-canary.sh"
  # CONTROL: plain git diff runs the textconv program.
  git -C "$repo" diff > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$repo" diff
  assert_success
  assert_output --partial '+two'
  [ ! -e "$marker" ]
}

# diff-files/diff-index default to NO external diff, so a canary cannot discriminate there; assert
# the injected argv through the shim instead (and that real git accepts both flags on all three).
@test "cast_git_safe: diff, diff-files and diff-index get --no-ext-diff --no-textconv; status does not" {
  local repo="$BATS_TEST_TMPDIR/inj" log="$BATS_TEST_TMPDIR/shim.log" sub
  _hl_repo "$repo"
  printf 'two\n' > "$repo/tracked.txt"
  _hl_shim
  for sub in "diff" "diff-files -p" "diff-index -p HEAD"; do
    rm -f "$log"
    # shellcheck disable=SC2086
    _hl_run_shimmed 1 "$log" "$repo" $sub
    assert_success
    grep -q -- '--ignore-submodules=all --no-ext-diff --no-textconv' "$log"
  done
  for sub in "diff" "diff-files -p" "diff-index -p HEAD"; do
    # shellcheck disable=SC2086
    _hl_run_safe "$repo" $sub
    assert_success
    assert_output --partial '+two'
  done
  rm -f "$log"
  _hl_run_shimmed 1 "$log" "$repo" status --porcelain
  assert_success
  grep -q -- '--ignore-submodules=all' "$log"
  [ "$(grep -c -- '--no-ext-diff' "$log")" -eq 0 ]
}

@test "cast_git_safe: commit is refused (rc 2) and a commit.gpgSign gpg.program canary does not run (control fires)" {
  local repo="$BATS_TEST_TMPDIR/gpgc" marker="$BATS_TEST_TMPDIR/gpgc.marker"
  _hl_repo "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name t
  _hl_canary "$BATS_TEST_TMPDIR/gpgc-canary.sh" "$marker"
  git -C "$repo" config gpg.program "$BATS_TEST_TMPDIR/gpgc-canary.sh"
  git -C "$repo" config commit.gpgSign true
  # CONTROL: plain git commit invokes gpg.program (the canary produces no signature, so the
  # commit itself may fail; only the marker matters).
  git -C "$repo" commit -q --allow-empty -m control > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$repo" commit -q --allow-empty -m x
  assert_failure 2
  [ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]
  [ ! -e "$marker" ]
}

@test "cast_git_safe: tag is refused (rc 2) and a tag.gpgSign gpg.program canary does not run (control fires)" {
  local repo="$BATS_TEST_TMPDIR/gpgt" marker="$BATS_TEST_TMPDIR/gpgt.marker"
  _hl_repo "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name t
  _hl_canary "$BATS_TEST_TMPDIR/gpgt-canary.sh" "$marker"
  git -C "$repo" config gpg.program "$BATS_TEST_TMPDIR/gpgt-canary.sh"
  git -C "$repo" config tag.gpgSign true
  git -C "$repo" tag -m control v0 > /dev/null 2>&1 || true
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$repo" tag -m x v1
  assert_failure 2
  [ -z "$(git -C "$repo" tag -l v1)" ]
  [ ! -e "$marker" ]
}

# push.gpgSign only reaches gpg when the server advertises push certs, so check the env instead.
@test "cast_git_safe: commit/tag/push gpgSign=false are env entries 4-6; gc/maintenance 7-8; enumerated entries start at 9" {
  local repo="$BATS_TEST_TMPDIR/envk" log="$BATS_TEST_TMPDIR/env.log"
  _hl_repo "$repo"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat > "$BATS_TEST_TMPDIR/shim/git" << 'SHIM'
#!/bin/sh
case "$*" in
  *--get-regexp*) printf 'filter.d.clean\n'; exit 0 ;;
esac
env | sort > "$SHIM_LOG"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/git"
  chmod 755 "$BATS_TEST_TMPDIR/shim"
  run env SHIM_LOG="$log" \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$(_hl_lib_with_git "$BATS_TEST_TMPDIR/shim/git")" "$repo" status
  assert_success
  grep -qx 'GIT_CONFIG_KEY_4=commit.gpgSign' "$log"
  grep -qx 'GIT_CONFIG_VALUE_4=false' "$log"
  grep -qx 'GIT_CONFIG_KEY_5=tag.gpgSign' "$log"
  grep -qx 'GIT_CONFIG_VALUE_5=false' "$log"
  grep -qx 'GIT_CONFIG_KEY_6=push.gpgSign' "$log"
  grep -qx 'GIT_CONFIG_VALUE_6=false' "$log"
  grep -qx 'GIT_CONFIG_KEY_7=gc.auto' "$log"
  grep -qx 'GIT_CONFIG_VALUE_7=0' "$log"
  grep -qx 'GIT_CONFIG_KEY_8=maintenance.auto' "$log"
  grep -qx 'GIT_CONFIG_VALUE_8=false' "$log"
  # One filter driver = clean, smudge, process, required (4 entries) after the 9 fixed ones.
  grep -qx 'GIT_CONFIG_KEY_9=filter.d.clean' "$log"
  grep -qx 'GIT_CONFIG_COUNT=13' "$log"
}

# _hl_gc_fixture <repo> <victim> — a repo whose OWN config makes plain git auto-gc on any gc --auto
# (gc.auto=1, no detach), with >1 loose object in objects/17 (what the loose-object trigger counts),
# and an agent-planted symlinked worktree entry .git/worktrees/zz -> <victim> with NO gitdir file.
# `git worktree prune` (run by gc) follows that symlink and empties the victim.
_hl_gc_fixture() {
  local repo="$1" victim="$2" i=0 n17=0
  _hl_repo "$repo"
  mkdir -p "$victim"
  printf 'precious\n' > "$victim/keep.txt"
  mkdir -p "$repo/.git/worktrees"
  ln -s "$victim" "$repo/.git/worktrees/zz"
  git -C "$repo" config gc.auto 1
  git -C "$repo" config gc.autoDetach false
  mkdir -p "$BATS_TEST_TMPDIR/objsrc"
  while [ "$n17" -lt 3 ] && [ "$i" -lt 20 ]; do
    local j=0
    while [ "$j" -lt 600 ]; do
      printf 'obj-%s-%s\n' "$i" "$j" > "$BATS_TEST_TMPDIR/objsrc/f$j"
      j=$((j + 1))
    done
    git -C "$repo" hash-object -w --stdin-paths < <(find "$BATS_TEST_TMPDIR/objsrc" -type f) > /dev/null
    i=$((i + 1))
    n17="$(find "$repo/.git/objects/17" -type f 2> /dev/null | wc -l | tr -d ' ')"
  done
  [ "$n17" -ge 3 ]
}

@test "cast_git_safe: gc --auto is refused (rc 2) and does not empty a symlinked .git/worktrees/<id> target (control fires)" {
  local ctl="$BATS_TEST_TMPDIR/gcc" ctlv="$BATS_TEST_TMPDIR/gcc-victim"
  local repo="$BATS_TEST_TMPDIR/gcs" victim="$BATS_TEST_TMPDIR/gcs-victim"
  _hl_gc_fixture "$ctl" "$ctlv"
  _hl_gc_fixture "$repo" "$victim"
  # CONTROL (identical fixture): plain git gc --auto must wipe the victim, or the fixture is vacuous.
  [ -e "$ctlv/keep.txt" ]
  git -C "$ctl" gc --auto > /dev/null 2>&1 || true
  [ ! -e "$ctlv/keep.txt" ]
  _hl_run_safe "$repo" gc --auto
  assert_failure 2
  [ -e "$victim/keep.txt" ]
}

@test "cast_git_safe: a missing or empty first git arg returns 2 and runs no git" {
  local repo="$BATS_TEST_TMPDIR/nosub" log="$BATS_TEST_TMPDIR/shim.log"
  _hl_repo "$repo"
  _hl_shim
  # CONTROL: a real subcommand reaches git (the shim log proves it).
  _hl_run_shimmed 1 "$log" "$repo" status --porcelain
  assert_success
  [ -s "$log" ]
  rm -f "$log"
  _hl_run_shimmed 1 "$log" "$repo"
  assert_failure 2
  [ ! -e "$log" ]
  _hl_run_shimmed 1 "$log" "$repo" ""
  assert_failure 2
  [ ! -e "$log" ]
}

@test "cast_git_safe: a PATH-planted env is not used (absolute /usr/bin/env; control: plain env is shadowed)" {
  local repo="$BATS_TEST_TMPDIR/penv" marker="$BATS_TEST_TMPDIR/penv.marker"
  _hl_repo "$repo"
  mkdir -p "$BATS_TEST_TMPDIR/envshim"
  printf '#!/bin/sh\ntouch "%s"\nexec /usr/bin/env "$@"\n' "$marker" > "$BATS_TEST_TMPDIR/envshim/env"
  chmod +x "$BATS_TEST_TMPDIR/envshim/env"
  # CONTROL: with the shim first on PATH, a bare `env` resolves to it.
  PATH="$BATS_TEST_TMPDIR/envshim:$PATH" bash -c 'env true'
  [ -e "$marker" ]
  rm -f "$marker"
  run env PATH="$BATS_TEST_TMPDIR/envshim:$PATH" \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$repo" status --porcelain
  assert_success
  [ ! -e "$marker" ]
}

# --- U4a: prune-capable subcommands, aliases, PATH, pager ---

# _hl_wt_fixture <repo> <victim> — repo plus an agent-planted symlinked .git/worktrees/zz -> <victim>
# (no gitdir file). Plain `git worktree prune` / `git gc` / `git maintenance run` empty the victim.
_hl_wt_fixture() {
  mkdir -p "$2"
  printf 'precious\n' > "$2/keep.txt"
  git init -q "$1"
  mkdir -p "$1/.git/worktrees"
  ln -s "$2" "$1/.git/worktrees/zz"
}

# _hl_no_repo_call <shim-log> <repo> — succeeds only if no git call against <repo> was logged (an
# absent log means no git ran at all). Explicit test, not `! grep`: in bats `!` never fails a test.
_hl_no_repo_call() {
  [ ! -e "$1" ] || [ "$(grep -c -- "-C $2" "$1")" -eq 0 ]
}

@test "cast_git_safe: gc, maintenance run and worktree prune are refused (rc 2); victim intact (control: plain git empties it)" {
  local c i=0 repo victim ctl ctlv
  for c in "gc" "maintenance run" "worktree prune" "worktree --porcelain prune"; do
    i=$((i + 1))
    ctl="$BATS_TEST_TMPDIR/pc$i" ctlv="$BATS_TEST_TMPDIR/pcv$i"
    repo="$BATS_TEST_TMPDIR/ps$i" victim="$BATS_TEST_TMPDIR/psv$i"
    _hl_wt_fixture "$ctl" "$ctlv"
    _hl_wt_fixture "$repo" "$victim"
    # CONTROL (identical fixture): plain git must empty the victim, or the fixture is vacuous.
    # shellcheck disable=SC2086
    git -C "$ctl" ${c/ --porcelain/} > /dev/null 2>&1 || true
    [ ! -e "$ctlv/keep.txt" ]
    # shellcheck disable=SC2086
    _hl_run_safe "$repo" $c
    assert_failure 2
    [ -e "$victim/keep.txt" ]
  done
}

@test "cast_git_safe: prune, repack, maintenance, worktree repair|move are refused (rc 2) and run no git (control: worktree list runs)" {
  local repo="$BATS_TEST_TMPDIR/pr" log="$BATS_TEST_TMPDIR/shim.log" c
  _hl_repo "$repo"
  _hl_shim
  # CONTROL: a benign worktree subcommand reaches git (the shim log proves it).
  _hl_run_shimmed 1 "$log" "$repo" worktree list
  assert_success
  grep -q -- "-C $repo" "$log"
  for c in "prune" "repack -ad" "maintenance run" "worktree repair" "worktree move a b" "worktree -q repair" "worktree" "show HEAD" "log -p" "help status" "gc --auto" "credential fill" "difftool -x true" "bisect run true"; do
    rm -f "$log"
    # shellcheck disable=SC2086
    _hl_run_shimmed 1 "$log" "$repo" $c
    assert_failure 2
    # Nothing ran against the repo (a builtin-list call, if any, never carries -C <repo>).
    _hl_no_repo_call "$log" "$repo"
  done
}

@test "cast_git_safe: a repo alias is not expanded; non-builtin first arg returns 2 (control: plain git runs the alias)" {
  local repo="$BATS_TEST_TMPDIR/al" marker="$BATS_TEST_TMPDIR/al.marker" log="$BATS_TEST_TMPDIR/shim.log"
  _hl_repo "$repo"
  git -C "$repo" config alias.zz "!touch $marker"
  # CONTROL: plain git executes the alias.
  git -C "$repo" zz > /dev/null 2>&1
  [ -e "$marker" ]
  rm -f "$marker"
  _hl_run_safe "$repo" zz
  assert_failure 2
  assert_output --partial "not allowed"
  [ ! -e "$marker" ]
  # A made-up subcommand and one with an embedded newline are refused too, before any repo git.
  _hl_shim
  _hl_run_shimmed 1 "$log" "$repo" frobnicate
  assert_failure 2
  _hl_no_repo_call "$log" "$repo"
  _hl_run_safe "$repo" $'status\nrev-parse'
  assert_failure 2
  # Builtins still work.
  _hl_run_safe "$repo" rev-parse --is-inside-work-tree
  assert_success
  assert_output "true"
}

@test "cast_git_safe: a planted ./git (cwd, empty or relative PATH entry) is never run; PATH of only relative entries falls back (control: plain git runs it)" {
  local repo="$BATS_TEST_TMPDIR/pg" cwd="$BATS_TEST_TMPDIR/pgcwd" marker="$BATS_TEST_TMPDIR/pg.marker" p
  _hl_repo "$repo"
  mkdir -p "$cwd/rel" "$cwd/abs"
  printf '#!/bin/sh\ntouch "%s"\necho PLANTED\n' "$marker" > "$cwd/git"
  cp "$cwd/git" "$cwd/rel/git"
  cp "$cwd/git" "$cwd/abs/git"
  chmod +x "$cwd/git" "$cwd/rel/git" "$cwd/abs/git"
  # The ABSOLUTE agent-style dir variant: not "unsafe" by any PATH-sanitising rule, so only the
  # fixed trusted-git list keeps it out.
  for p in ".:$PATH" ":$PATH" "rel:$PATH" "$cwd/abs:$PATH"; do
    rm -f "$marker"
    # CONTROL: with this PATH, plain `git` from that cwd resolves to the planted one.
    run bash -c 'cd "$1" && PATH="$2" git rev-parse --is-inside-work-tree' _ "$cwd" "$p"
    [ -e "$marker" ]
    rm -f "$marker"
    run bash -c 'cd "$1" && PATH="$2" && . "$3" && cast_git_safe "$4" rev-parse --is-inside-work-tree' _ "$cwd" "$p" "$HOOK_LIB" "$repo"
    assert_success
    assert_output "true"
    [ ! -e "$marker" ]
  done
  # Only relative entries left: fall back to the standard dirs, still the real git, still no plant.
  run bash -c 'cd "$1" && PATH=".:rel" && . "$2" && cast_git_safe "$3" rev-parse --is-inside-work-tree' _ "$cwd" "$HOOK_LIB" "$repo"
  assert_success
  assert_output "true"
  [ ! -e "$marker" ]
}

@test "cast_git_safe: --no-pager is passed to the main git call (argv-recording shim)" {
  local repo="$BATS_TEST_TMPDIR/np" log="$BATS_TEST_TMPDIR/np.log"
  _hl_repo "$repo"
  _hl_shim
  _hl_run_shimmed 1 "$log" "$repo" status --porcelain
  assert_success
  # The main call is the line carrying -C <repo> and the subcommand; it must carry --no-pager.
  grep -- "-C $repo status" "$log" | grep -q -- '--no-pager'
  # CONTROL for the probe itself: the hardening read (not the main call) carries no --no-pager.
  [ "$(grep -- '--get-regexp' "$log" | grep -c -- '--no-pager' || true)" -eq 0 ]
}

# --- U4a redesign: ALLOWLIST, fixed trusted git, env, editors ---

# _hl_wtremove_fixture <repo> <victim> <wt-path> — a linked worktree whose admin dir
# .git/worktrees/<id> was replaced by a symlink to <victim> (a copy of the admin files, commondir made
# absolute so git still validates it, plus keep.txt). Plain `git worktree remove <wt-path>` succeeds
# (rc 0, no --force) and EMPTIES the victim.
_hl_wtremove_fixture() {
  local repo="$1" victim="$2" wt="$3" id
  id="$(basename "$wt")"
  _hl_repo "$repo"
  git -C "$repo" worktree add -q --detach "$wt" HEAD
  mkdir -p "$victim"
  cp -R "$repo/.git/worktrees/$id/." "$victim/"
  printf 'precious\n' > "$victim/keep.txt"
  printf '%s\n' "$(cd "$repo" && pwd -P)/.git" > "$victim/commondir"
  rm -rf "${repo:?}/.git/worktrees/${id:?}"
  ln -s "$victim" "$repo/.git/worktrees/$id"
}

@test "cast_git_safe: worktree remove is refused (rc 2); victim intact (control: plain git empties it)" {
  local ctl="$BATS_TEST_TMPDIR/wrc" ctlv="$BATS_TEST_TMPDIR/wrcv" ctlw="$BATS_TEST_TMPDIR/wrcw"
  local repo="$BATS_TEST_TMPDIR/wrs" victim="$BATS_TEST_TMPDIR/wrsv" wt="$BATS_TEST_TMPDIR/wrsw"
  _hl_wtremove_fixture "$ctl" "$ctlv" "$ctlw"
  _hl_wtremove_fixture "$repo" "$victim" "$wt"
  # CONTROL (identical fixture): plain git worktree remove must wipe the victim.
  [ -e "$ctlv/keep.txt" ]
  git -C "$ctl" worktree remove "$ctlw" > /dev/null 2>&1
  [ ! -e "$ctlv/keep.txt" ]
  _hl_run_safe "$repo" worktree remove "$wt"
  assert_failure 2
  [ -e "$victim/keep.txt" ]
}

@test "cast_git_safe: help (man.<tool>.cmd via help.format=man) is refused (rc 2); canary absent (control: plain git fires it)" {
  local ctl="$BATS_TEST_TMPDIR/hpc" repo="$BATS_TEST_TMPDIR/hps"
  local cm="$BATS_TEST_TMPDIR/hpc.marker" sm="$BATS_TEST_TMPDIR/hps.marker" r m
  for r in "$ctl:$cm" "$repo:$sm"; do
    m="${r#*:}"
    _hl_repo "${r%%:*}"
    _hl_canary "$BATS_TEST_TMPDIR/hp-canary-${m##*/}.sh" "$m"
    git -C "${r%%:*}" config help.format man
    git -C "${r%%:*}" config man.viewer evil
    git -C "${r%%:*}" config man.evil.cmd "$BATS_TEST_TMPDIR/hp-canary-${m##*/}.sh"
  done
  # CONTROL: plain git help runs the configured man viewer command (output/rc irrelevant).
  git -C "$ctl" help status > /dev/null 2>&1 || true
  [ -e "$cm" ]
  _hl_run_safe "$repo" help status
  assert_failure 2
  [ ! -e "$sm" ]
}

@test "cast_git_safe: branch --edit-description never launches a repo core.editor (GIT_EDITOR=: set; control: plain git fires it)" {
  local ctl="$BATS_TEST_TMPDIR/edc" repo="$BATS_TEST_TMPDIR/eds"
  local cm="$BATS_TEST_TMPDIR/edc.marker" sm="$BATS_TEST_TMPDIR/eds.marker" r m branch
  for r in "$ctl:$cm" "$repo:$sm"; do
    m="${r#*:}"
    _hl_repo "${r%%:*}"
    _hl_canary "$BATS_TEST_TMPDIR/ed-canary-${m##*/}.sh" "$m"
    git -C "${r%%:*}" config core.editor "$BATS_TEST_TMPDIR/ed-canary-${m##*/}.sh"
  done
  branch="$(git -C "$ctl" rev-parse --abbrev-ref HEAD)"
  # CONTROL: plain git branch --edit-description launches core.editor (the canary does not edit,
  # so the command's own rc is irrelevant; only the marker matters).
  # (An ambient GIT_EDITOR outranks core.editor, so it is cleared for the control.)
  env -u GIT_EDITOR -u VISUAL -u EDITOR TERM=xterm git -C "$ctl" branch --edit-description "$branch" > /dev/null 2>&1 || true
  [ -e "$cm" ]
  # A GIT_EDITOR / GIT_SEQUENCE_EDITOR inherited from the caller must not matter either.
  run env -u VISUAL -u EDITOR TERM=xterm GIT_EDITOR="$BATS_TEST_TMPDIR/ed-canary-${sm##*/}.sh" GIT_SEQUENCE_EDITOR="$BATS_TEST_TMPDIR/ed-canary-${sm##*/}.sh" \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$repo" branch --edit-description "$branch"
  [ ! -e "$sm" ]
}

@test "cast_git_safe: inherited exec/pager/ssh/askpass/template env is stripped, editors forced to ':' (control: shim sees them unfiltered)" {
  local repo="$BATS_TEST_TMPDIR/envu" log="$BATS_TEST_TMPDIR/envu.log" v
  _hl_repo "$repo"
  mkdir -p "$BATS_TEST_TMPDIR/shim"
  cat > "$BATS_TEST_TMPDIR/shim/git" << 'SHIM'
#!/bin/sh
case "$*" in
  *--get-regexp*) exit 1 ;;
esac
env | sort > "$SHIM_LOG"
SHIM
  chmod +x "$BATS_TEST_TMPDIR/shim/git"
  chmod 755 "$BATS_TEST_TMPDIR/shim"
  local evil=(GIT_EXEC_PATH=/evil GIT_PAGER=evil PAGER=evil GIT_EXTERNAL_DIFF=evil GIT_SSH=evil
    GIT_SSH_COMMAND=evil GIT_ASKPASS=evil SSH_ASKPASS=evil GIT_TEMPLATE_DIR=/evil GIT_PROXY_COMMAND=evil
    GIT_EDITOR=evil GIT_SEQUENCE_EDITOR=evil DEVELOPER_DIR=/evil)
  # CONTROL: invoked directly with the evil env, the shim's dump contains every variable.
  env "${evil[@]}" SHIM_LOG="$log" "$BATS_TEST_TMPDIR/shim/git" status
  for v in "${evil[@]}"; do grep -qx "$v" "$log"; done
  rm -f "$log"
  run env "${evil[@]}" SHIM_LOG="$log" \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$(_hl_lib_with_git "$BATS_TEST_TMPDIR/shim/git")" "$repo" status
  assert_success
  for v in GIT_EXEC_PATH GIT_PAGER PAGER GIT_EXTERNAL_DIFF GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS GIT_TEMPLATE_DIR GIT_PROXY_COMMAND DEVELOPER_DIR; do
    [ "$(grep -c "^${v}=" "$log")" -eq 0 ]
  done
  grep -qx 'GIT_EDITOR=:' "$log"
  grep -qx 'GIT_SEQUENCE_EDITOR=:' "$log"
}

@test "cast_git_safe: every allowlisted caller subcommand is accepted (table-driven), incl. worktree list" {
  local repo="$BATS_TEST_TMPDIR/allow" c
  _hl_repo "$repo"
  while IFS= read -r c; do
    # shellcheck disable=SC2086
    _hl_run_safe "$repo" $c
    [ "$status" -ne 2 ] || { echo "refused: $c: $output" >&2; return 1; }
  done << 'CALLS'
status --porcelain
rev-parse --show-toplevel
rev-list --count HEAD
for-each-ref --format=%(refname)
ls-files -s
cherry HEAD HEAD
branch --list
branch -vv
diff --quiet
diff-files --quiet
diff-index --quiet HEAD
worktree list
worktree list --porcelain
worktree -q list
CALLS
  # CONTROL: the same check does fire on a refused subcommand.
  _hl_run_safe "$repo" gc
  [ "$status" -eq 2 ]
}

# --- U4a trusted-dir rule: dir owned by root or the invoking user AND not world-writable ---

# _hl_dir_shim <dir> <mode> <marker> — dir/git logs its dir to <marker> then execs the real git.
_hl_dir_shim() {
  local real
  real="$(command -v git)"
  mkdir -p "$1"
  printf '#!/bin/sh\necho "%s" >> "%s"\nexec "%s" "$@"\n' "$1" "$3" "$real" > "$1/git"
  chmod +x "$1/git"
  chmod "$2" "$1"
}

# _hl_lib_with_two_git <git-a> <git-b> — COPY of the lib whose trusted-git list is (<a> <b>); the
# rewrite is asserted so a vacuous copy cannot pass.
_hl_lib_with_two_git() {
  local out="$BATS_TEST_TMPDIR/lib-two.sh"
  sed "s|^  local git_candidates=(.*)\$|  local git_candidates=(\"$1\" \"$2\")|" "$HOOK_LIB" > "$out"
  grep -qF "local git_candidates=(\"$1\" \"$2\")" "$out"
  printf '%s' "$out"
}

@test "cast_git_safe: a user-owned GROUP-writable git dir is ACCEPTED (control: same shim runs)" {
  local repo="$BATS_TEST_TMPDIR/tdg" log="$BATS_TEST_TMPDIR/tdg.log" lib
  _hl_repo "$repo"
  : > "$log"
  _hl_dir_shim "$BATS_TEST_TMPDIR/gw" 775 "$log"
  [ "$(_hl_mode "$BATS_TEST_TMPDIR/gw")" = "775" ]
  lib="$(_hl_lib_with_two_git "$BATS_TEST_TMPDIR/gw/git" "$BATS_TEST_TMPDIR/gw/git")"
  run bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$lib" "$repo" rev-parse --git-dir
  [ "$status" -eq 0 ]
  [ "$output" = ".git" ]
  grep -qF "$BATS_TEST_TMPDIR/gw" "$log"
}

@test "cast_git_safe: a WORLD-writable git dir is SKIPPED (rc 3, shim never runs); a later trusted candidate is used" {
  local repo="$BATS_TEST_TMPDIR/tdw" log="$BATS_TEST_TMPDIR/tdw.log" lib
  _hl_repo "$repo"
  : > "$log"
  _hl_dir_shim "$BATS_TEST_TMPDIR/ww" 777 "$log"
  _hl_dir_shim "$BATS_TEST_TMPDIR/ok" 755 "$log"
  [ "$(_hl_mode "$BATS_TEST_TMPDIR/ww")" = "777" ]
  # Only the world-writable candidate: refused, nothing ran.
  lib="$(_hl_lib_with_two_git "$BATS_TEST_TMPDIR/ww/git" "$BATS_TEST_TMPDIR/ww/git")"
  run bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$lib" "$repo" rev-parse --git-dir
  [ "$status" -eq 3 ]
  [ ! -s "$log" ]
  case "$output" in *"no trusted git binary"*) ;; *) echo "unexpected: $output" >&2; return 1 ;; esac
  # CONTROL: world-writable first, trusted second -> the trusted one is used, the 777 one is not.
  lib="$(_hl_lib_with_two_git "$BATS_TEST_TMPDIR/ww/git" "$BATS_TEST_TMPDIR/ok/git")"
  run bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$lib" "$repo" rev-parse --git-dir
  [ "$status" -eq 0 ]
  grep -qF "$BATS_TEST_TMPDIR/ok" "$log"
  [ "$(grep -cF "$BATS_TEST_TMPDIR/ww" "$log")" -eq 0 ]
}

# --- U4d: branch symlink check (H1), uid from /usr/bin/id (M1), denied flags (L1) ---

# _hl_h1_reflog_fixture <repo> <victim-dir> — ref feature/settings.json at HEAD whose reflog dir
# .git/logs/refs/heads/feature is a symlink to <victim-dir> holding settings.json = "precious".
_hl_h1_reflog_fixture() {
  _hl_repo "$1"
  mkdir -p "$2"
  printf 'precious\n' > "$2/settings.json"
  git -C "$1" branch feature/settings.json
  [[ "$1" == "$BATS_TEST_TMPDIR"/* ]]
  rm -rf "$1/.git/logs/refs/heads/feature"
  ln -s "$2" "$1/.git/logs/refs/heads/feature"
}

# _hl_h1_refs_fixture <repo> <victim-dir> — .git/refs/heads/dir is a symlink to <victim-dir>, whose
# file y holds a valid object id (so a branch delete of dir/y resolves it through the symlink).
_hl_h1_refs_fixture() {
  _hl_repo "$1"
  mkdir -p "$2"
  git -C "$1" rev-parse HEAD > "$2/y"
  ln -s "$2" "$1/.git/refs/heads/dir"
}

@test "cast_git_safe: branch -D through a symlinked reflog dir is refused (rc 3); victim intact (control: plain git empties it)" {
  local repo="$BATS_TEST_TMPDIR/h1r" vict="$BATS_TEST_TMPDIR/h1r-vict"
  local crepo="$BATS_TEST_TMPDIR/h1r-ctl" cvict="$BATS_TEST_TMPDIR/h1r-cvict"
  _hl_h1_reflog_fixture "$crepo" "$cvict"
  # CONTROL: plain git unlinks the victim's file through the symlink.
  CAST_BRANCH_OK=1 git -C "$crepo" branch -D -- feature/settings.json > /dev/null 2>&1 || true
  [ ! -e "$cvict/settings.json" ]
  _hl_h1_reflog_fixture "$repo" "$vict"
  _hl_run_safe "$repo" branch -D -- feature/settings.json
  [ "$status" -eq 3 ]
  case "$output" in *"git NOT run"*) ;; *) echo "unexpected: $output" >&2; return 1 ;; esac
  [ "$(cat "$vict/settings.json")" = "precious" ]
  git -C "$repo" rev-parse --verify -q refs/heads/feature/settings.json > /dev/null
}

@test "cast_git_safe: branch -D through a symlinked refs dir is refused (rc 3); victim intact (control: plain git deletes it)" {
  local repo="$BATS_TEST_TMPDIR/h1f" vict="$BATS_TEST_TMPDIR/h1f-vict"
  local crepo="$BATS_TEST_TMPDIR/h1f-ctl" cvict="$BATS_TEST_TMPDIR/h1f-cvict"
  _hl_h1_refs_fixture "$crepo" "$cvict"
  # CONTROL: plain git removes victim_dir/y through the symlinked refs/heads/dir.
  CAST_BRANCH_OK=1 git -C "$crepo" branch -D -- dir/y > /dev/null 2>&1 || true
  [ ! -e "$cvict/y" ]
  _hl_h1_refs_fixture "$repo" "$vict"
  _hl_run_safe "$repo" branch -D -- dir/y
  [ "$status" -eq 3 ]
  [ -s "$vict/y" ]
}

@test "cast_git_safe: a symlinked .git/logs itself makes branch refuse (rc 3)" {
  local repo="$BATS_TEST_TMPDIR/h1l"
  _hl_repo "$repo"
  git -C "$repo" branch somebranch
  [[ "$repo" == "$BATS_TEST_TMPDIR"/* ]]
  mv "$repo/.git/logs" "$repo/.git/logs.real"
  ln -s logs.real "$repo/.git/logs"
  _hl_run_safe "$repo" branch -D -- somebranch
  [ "$status" -eq 3 ]
  git -C "$repo" rev-parse --verify -q refs/heads/somebranch > /dev/null
}

@test "cast_git_safe: branch on a clean repo works (delete rc 0 and branch gone; --list rc 0)" {
  local repo="$BATS_TEST_TMPDIR/h1ok"
  _hl_repo "$repo"
  git -C "$repo" branch somebranch
  _hl_run_safe "$repo" branch --list
  [ "$status" -eq 0 ]
  case "$output" in *somebranch*) ;; *) echo "unexpected: $output" >&2; return 1 ;; esac
  _hl_run_safe "$repo" branch -D -- somebranch
  [ "$status" -eq 0 ]
  run git -C "$repo" rev-parse --verify -q refs/heads/somebranch
  [ "$status" -ne 0 ]
}

@test "cast_git_safe: trust uses /usr/bin/id, not an imported EUID (user-owned git dir still trusted under EUID=99999)" {
  local repo="$BATS_TEST_TMPDIR/m1" log="$BATS_TEST_TMPDIR/m1.log" lib
  _hl_repo "$repo"
  : > "$log"
  # A user-owned 755 dir (NOT root-owned): trust depends on the uid compare, so this fails if the
  # lib consults an EUID imported from the environment.
  _hl_dir_shim "$BATS_TEST_TMPDIR/m1d" 755 "$log"
  lib="$(_hl_lib_with_two_git "$BATS_TEST_TMPDIR/m1d/git" "$BATS_TEST_TMPDIR/m1d/git")"
  # CONTROL: this bash imports EUID from the environment (bash 3.2 does; bash 5 does not).
  if [ "$(env EUID=99999 /bin/bash -c 'echo $EUID')" != "99999" ]; then
    echo "(/bin/bash does not import EUID from env; the M1 spoof is not reproducible here)" >&2
  fi
  run env EUID=99999 /bin/bash -c "source '$lib'; cast_git_safe '$repo' status"
  [ "$status" -eq 0 ]
  grep -qF "$BATS_TEST_TMPDIR/m1d" "$log"
}

@test "cast_git_safe: denied flags (--ext-diff --textconv --output --no-index --alternate-refs --ignore-submodules) return 2 and run no git" {
  local repo="$BATS_TEST_TMPDIR/l1t" log="$BATS_TEST_TMPDIR/l1t.log" f
  _hl_repo "$repo"
  _hl_shim
  # CONTROL: a permitted diff reaches git (the shim log proves it), incl. the allowed --no-* forms.
  _hl_run_shimmed 1 "$log" "$repo" diff --quiet --no-ext-diff --no-textconv
  [ "$status" -eq 0 ]
  [ -s "$log" ]
  for f in --ext-diff --textconv --output "--output=$BATS_TEST_TMPDIR/l1t.out" --no-index --alternate-refs \
    --ignore-submodules --ignore-submodules=none --ignore-submodules=all; do
    : > "$log"
    _hl_run_shimmed 1 "$log" "$repo" diff "$f"
    [ "$status" -eq 2 ]
    [ ! -s "$log" ]
  done
  # Caught in any position and on diff-index / status too.
  : > "$log"
  _hl_run_shimmed 1 "$log" "$repo" diff-index HEAD --output=x
  [ "$status" -eq 2 ]
  _hl_run_shimmed 1 "$log" "$repo" status --ignore-submodules=none
  [ "$status" -eq 2 ]
  [ ! -s "$log" ]
}

@test "cast_git_safe: diff --output=<path> writes nothing (rc 2); control: plain git writes it" {
  local repo="$BATS_TEST_TMPDIR/l1o" f="$BATS_TEST_TMPDIR/l1o.out" f2="$BATS_TEST_TMPDIR/l1o.out2"
  _hl_diff_fixture "$repo"
  git -C "$repo" diff --output="$f2" > /dev/null 2>&1 || true
  [ -e "$f2" ]
  _hl_run_safe "$repo" diff --output="$f"
  [ "$status" -eq 2 ]
  [ ! -e "$f" ]
  _hl_run_safe "$repo" diff-index --output="$f" HEAD
  [ "$status" -eq 2 ]
  [ ! -e "$f" ]
}

@test "cast_git_safe: diff --ext-diff and --textconv canaries do not fire (rc 2); control: plain git fires them" {
  local repo="$BATS_TEST_TMPDIR/l1e" me="$BATS_TEST_TMPDIR/l1e.ext" mt="$BATS_TEST_TMPDIR/l1e.tc"
  _hl_diff_fixture "$repo"
  _hl_canary "$BATS_TEST_TMPDIR/l1e-ext.sh" "$me"
  git -C "$repo" config diff.external "$BATS_TEST_TMPDIR/l1e-ext.sh"
  printf '#!/bin/sh\ntouch "%s"\ncat "$1"\n' "$mt" > "$BATS_TEST_TMPDIR/l1e-tc.sh"
  chmod +x "$BATS_TEST_TMPDIR/l1e-tc.sh"
  git -C "$repo" config diff.evil.textconv "$BATS_TEST_TMPDIR/l1e-tc.sh"
  # CONTROL: plain git fires both.
  git -C "$repo" diff --ext-diff > /dev/null 2>&1 || true
  [ -e "$me" ]
  # (An external diff program outranks textconv, so drop it for the textconv control only.)
  git -C "$repo" config --unset diff.external
  git -C "$repo" diff --textconv > /dev/null 2>&1 || true
  [ -e "$mt" ]
  git -C "$repo" config diff.external "$BATS_TEST_TMPDIR/l1e-ext.sh"
  rm -f "$me" "$mt"
  _hl_run_safe "$repo" diff --ext-diff
  [ "$status" -eq 2 ]
  _hl_run_safe "$repo" diff --textconv
  [ "$status" -eq 2 ]
  [ ! -e "$me" ]
  [ ! -e "$mt" ]
  # The permitted forms still work and still do not fire either.
  _hl_run_safe "$repo" diff --no-ext-diff --no-textconv
  [ "$status" -eq 0 ]
  [ ! -e "$me" ]
  [ ! -e "$mt" ]
}

# --- U4d follow-up: branch symlink scan also covers worktrees, config and reftable ---

@test "cast_git_safe: branch -m with a symlinked worktrees/<id>/logs/HEAD is refused (rc 3); victim unchanged (control: plain git appends)" {
  local repo="$BATS_TEST_TMPDIR/wa" vict="$BATS_TEST_TMPDIR/wa-vict.txt"
  local crepo="$BATS_TEST_TMPDIR/wa-ctl" cvict="$BATS_TEST_TMPDIR/wa-cvict.txt" r v sum
  for r in "$crepo:$cvict" "$repo:$vict"; do
    _hl_repo "${r%%:*}"
    git -C "${r%%:*}" worktree add -q -b wtb "${r%%:*}-wt"
    printf 'precious\n' > "${r#*:}"
    [[ "${r%%:*}" == "$BATS_TEST_TMPDIR"/* ]]
    mkdir -p "${r%%:*}/.git/worktrees/$(basename "${r%%:*}-wt")/logs"
    rm -f "${r%%:*}/.git/worktrees/$(basename "${r%%:*}-wt")/logs/HEAD"
    ln -s "${r#*:}" "${r%%:*}/.git/worktrees/$(basename "${r%%:*}-wt")/logs/HEAD"
  done
  # CONTROL: plain git appends a reflog line to the victim through the symlink.
  CAST_BRANCH_OK=1 git -C "$crepo" branch -m wtb wtb2 > /dev/null 2>&1 || true
  [ "$(cat "$cvict")" != "precious" ]
  sum="$(cksum < "$vict")"
  _hl_run_safe "$repo" branch -m wtb wtb2
  [ "$status" -eq 3 ]
  [ "$(cksum < "$vict")" = "$sum" ]
  git -C "$repo" rev-parse --verify -q refs/heads/wtb > /dev/null
}

@test "cast_git_safe: branch -D with .git/config symlinked to a victim is refused (rc 3); victim byte-identical (control: plain git rewrites it)" {
  local repo="$BATS_TEST_TMPDIR/wb" vict="$BATS_TEST_TMPDIR/wb-vict.cfg"
  local crepo="$BATS_TEST_TMPDIR/wb-ctl" cvict="$BATS_TEST_TMPDIR/wb-cvict.cfg" r sum
  for r in "$crepo:$cvict" "$repo:$vict"; do
    _hl_repo "${r%%:*}"
    git -C "${r%%:*}" branch feature
    git -C "${r%%:*}" config branch.feature.remote origin
    [[ "${r%%:*}" == "$BATS_TEST_TMPDIR"/* ]]
    mv "${r%%:*}/.git/config" "${r#*:}"
    ln -s "${r#*:}" "${r%%:*}/.git/config"
  done
  # CONTROL: plain git removes the [branch "feature"] section from the victim.
  sum="$(cksum < "$cvict")"
  CAST_BRANCH_OK=1 git -C "$crepo" branch -D -- feature > /dev/null 2>&1 || true
  [ "$(cksum < "$cvict")" != "$sum" ]
  sum="$(cksum < "$vict")"
  _hl_run_safe "$repo" branch -D -- feature
  [ "$status" -eq 3 ]
  [ "$(cksum < "$vict")" = "$sum" ]
  git -C "$repo" rev-parse --verify -q refs/heads/feature > /dev/null
}

# _hl_reftable_repo <dir> — a commit-bearing repo using the reftable ref backend.
_hl_reftable_repo() {
  mkdir -p "$1"
  git -C "$1" init -q --ref-format=reftable
  printf 'one\n' > "$1/tracked.txt"
  git -C "$1" add tracked.txt
  git -C "$1" -c user.email=test@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init
}

@test "cast_git_safe: branch -D with .git/reftable symlinked to another repo is refused (rc 3); other repo keeps its ref (control: plain git deletes it)" {
  local repo="$BATS_TEST_TMPDIR/wc" other="$BATS_TEST_TMPDIR/wc-other"
  local crepo="$BATS_TEST_TMPDIR/wc-ctl" cother="$BATS_TEST_TMPDIR/wc-cother" r
  if [ "$(git --version | awk -F'[ .]' '{print $3*1000+$4}')" -lt 2045 ]; then
    skip "git < 2.45 has no --ref-format=reftable"
  fi
  for r in "$crepo:$cother" "$repo:$other"; do
    _hl_reftable_repo "${r%%:*}"
    _hl_reftable_repo "${r#*:}"
    git -C "${r#*:}" branch victimbr
    [[ "${r%%:*}" == "$BATS_TEST_TMPDIR"/* ]]
    rm -rf "${r%%:*}/.git/reftable"
    ln -s "${r#*:}/.git/reftable" "${r%%:*}/.git/reftable"
  done
  # CONTROL: plain git deletes victimbr in the OTHER repo through the symlink.
  CAST_BRANCH_OK=1 git -C "$crepo" branch -D -- victimbr > /dev/null 2>&1 || true
  run git -C "$cother" rev-parse --verify -q refs/heads/victimbr
  [ "$status" -ne 0 ]
  _hl_run_safe "$repo" branch -D -- victimbr
  [ "$status" -eq 3 ]
  git -C "$other" rev-parse --verify -q refs/heads/victimbr > /dev/null
}

@test "cast_git_safe: branch -D on a repo with a normal linked worktree (no symlinks) still works (rc 0)" {
  local repo="$BATS_TEST_TMPDIR/wp"
  _hl_repo "$repo"
  git -C "$repo" worktree add -q -b wtp "$repo-wt"
  git -C "$repo" branch other
  [ -d "$repo/.git/worktrees" ]
  _hl_run_safe "$repo" branch -D -- other
  [ "$status" -eq 0 ]
  run git -C "$repo" rev-parse --verify -q refs/heads/other
  [ "$status" -ne 0 ]
  # Also from inside the linked worktree (git-dir != common-dir).
  git -C "$repo" branch other2
  _hl_run_safe "$repo-wt" branch -D -- other2
  [ "$status" -eq 0 ]
}
