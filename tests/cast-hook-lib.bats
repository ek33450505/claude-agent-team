#!/usr/bin/env bats
# Tests for scripts/cast-hook-lib.sh
# Covers: cast_hook_read_stdin (empty, piped input), cast_hook_db_path (CAST_DB_PATH override, fallback)
# and re-source guard (_CAST_HOOK_LIB_LOADED), and cast_git_safe (hostile-repo hardening:
# fsmonitor, filter drivers, config-based hooks, submodule-only filters (status/diff/diff-files/
# diff-index), inherited GIT_DIR, ambient GIT_CONFIG_COUNT, fail-closed config read, leading-option
# rejection, promisor lazy-fetch ext::, arg guard, behaviour + caller hygiene).
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
  # Precondition: the SUPERPROJECT config defines no filter; only the submodule's own does.
  [ -z "$(git -C "$1" config --get-regexp '^filter\.' || true)" ]
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
}

# _hl_run_shimmed <config-rc> <log> <repo-dir> <git-args...> — cast_git_safe through the shim.
_hl_run_shimmed() {
  local rc="$1" log="$2" real
  real="$(command -v git)"
  shift 2
  run env PATH="$BATS_TEST_TMPDIR/shim:$PATH" SHIM_LOG="$log" SHIM_CONFIG_RC="$rc" REAL_GIT="$real" \
    bash -c 'set -euo pipefail; . "$1"; shift; cast_git_safe "$@"' _ "$HOOK_LIB" "$@"
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
  [ "$(grep -c . "$log")" -eq 2 ]
  rm -f "$log"
  # Read rc 128 (git died): fail closed, only the read happened.
  _hl_run_shimmed 128 "$log" "$repo" status --porcelain
  assert_failure 3
  assert_output --partial "git NOT run"
  [ "$(grep -c . "$log")" -eq 1 ]
  grep -q -- '--get-regexp' "$log"
  rm -f "$log"
  # Any other rc is fail-closed too.
  _hl_run_shimmed 2 "$log" "$repo" status --porcelain
  assert_failure 3
  [ "$(grep -c . "$log")" -eq 1 ]
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
