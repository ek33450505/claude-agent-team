#!/usr/bin/env bats
# Tests for scripts/cast-files-api.sh (S4-1 D-E): Anthropic Files API adapter (bin/cast files).
# curl and `security` (macOS keychain) are PATH-shimmed: no network call and no keychain read is ever made.
# The fake key is deliberately not credential-shaped.

bats_require_minimum_version 1.5.0

load 'helpers/setup'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/cast-files-api.sh"
FAKE_KEY="FAKEKEY_do_not_log_0123456789"

setup() {
  setup_temp_home
  unset ANTHROPIC_API_KEY ANTHROPIC_API_BASE CLAUDE_SUBPROCESS CAST_AGENT_NAME
  SHIM="$HOME/shim"
  mkdir -p "$SHIM"
  export CURL_LOG="$HOME/curl-argv.log"
  export CURL_BODY='{"id":"file_test123","type":"file"}'
  export CURL_FILE_CONTENT="downloaded-bytes"
  export CURL_RC=0
  cat > "$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGV-BEGIN\n'; for a in "$@"; do printf '%s\n' "$a"; done; printf 'ARGV-END\n'; } >> "$CURL_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then printf '%s' "$CURL_FILE_CONTENT" > "$out"; else printf '%s' "$CURL_BODY"; fi
exit "${CURL_RC:-0}"
STUB
  # `security` shim: the keychain is never consulted (exit 44 = item not found), unless a test overrides it
  cat > "$SHIM/security" <<'STUB'
#!/usr/bin/env bash
exit 44
STUB
  chmod +x "$SHIM/curl" "$SHIM/security"
  export PATH="$SHIM:$PATH"
  cd "$HOME"
  printf 'payload\n' > "$HOME/doc.txt"
}

teardown() {
  cd /
  teardown_temp_home
}

_args() { tr '\n' ' ' < "$CURL_LOG"; }

# ---------- API key ----------

@test "missing API key fails cleanly: non-zero, clear message, no curl call" {
  run bash "$SCRIPT" upload "$HOME/doc.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ANTHROPIC_API_KEY not set"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "missing API key also fails for delete and download without calling curl" {
  run bash "$SCRIPT" delete file_x
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" download file_x "$HOME/out.bin"
  [ "$status" -ne 0 ]
  [ ! -f "$CURL_LOG" ]
}

@test "keychain fallback supplies the key when the env var is unset" {
  cat > "$SHIM/security" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$FAKE_KEY'
STUB
  run bash "$SCRIPT" delete file_x
  [ "$status" -eq 0 ]
  [[ "$(_args)" == *"x-api-key: $FAKE_KEY"* ]]
}

@test "CLAUDE_SUBPROCESS=1 exits 0 without touching curl" {
  run env CLAUDE_SUBPROCESS=1 bash "$SCRIPT" upload "$HOME/doc.txt"
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_LOG" ]
}

# ---------- upload ----------

@test "upload POSTs multipart to /v1/files with the beta header and returns the response JSON" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/doc.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"file_test123"'* ]]
  [ "$(grep -c '^ARGV-BEGIN$' "$CURL_LOG")" -eq 1 ]
  local a
  a="$(_args)"
  [[ "$a" == *"-X POST https://api.anthropic.com/v1/files "* ]]
  [[ "$a" == *"anthropic-beta: files-api-2025-04-14"* ]]
  [[ "$a" == *"x-api-key: $FAKE_KEY"* ]]
  [[ "$a" == *"purpose=assistants"* ]]
  [[ "$a" == *"file=@"*"/doc.txt"* ]]
  [[ "$a" != *expires_in* ]]
}

@test "upload honours --purpose and --ttl" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/doc.txt" --purpose batch --ttl 3600
  [ "$status" -eq 0 ]
  local a
  a="$(_args)"
  [[ "$a" == *"purpose=batch"* ]]
  [[ "$a" == *"expires_in=3600"* ]]
}

@test "ANTHROPIC_API_BASE overrides the endpoint host" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" ANTHROPIC_API_BASE=http://shim.invalid bash "$SCRIPT" upload "$HOME/doc.txt"
  [ "$status" -eq 0 ]
  [[ "$(_args)" == *"-X POST http://shim.invalid/v1/files "* ]]
}

@test "upload rejects a non-numeric --ttl before calling curl" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/doc.txt" --ttl abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"--ttl must be a positive integer"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "upload rejects an unknown option" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/doc.txt" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "upload of a missing file fails without calling curl and logs to hook-errors.log" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/nope.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"file not found"* ]]
  [ ! -f "$CURL_LOG" ]
  grep -q 'upload failed: file not found' "$HOME/.claude/logs/hook-errors.log"
}

@test "upload with no path prints usage" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "upload path guard: a symlink resolving outside the allowed dirs is refused" {
  # /etc/hosts resolves to /etc or /private/etc: outside /Users, /tmp, /var/folders
  [ -e /etc/hosts ]
  ln -s /etc/hosts "$HOME/link.txt"
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/link.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"outside allowed directories"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "upload with a response missing an id fails" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" CURL_BODY='{}' bash "$SCRIPT" upload "$HOME/doc.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing file_id"* ]]
  grep -q 'status=error' "$HOME/.claude/logs/files-api.log"
}

@test "upload with a curl failure exits 1" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" CURL_RC=22 bash "$SCRIPT" upload "$HOME/doc.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"upload failed (curl exit 22)"* ]]
}

# ---------- download ----------

@test "download GETs /v1/files/<id>/content and writes the destination" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" download file_abc "$HOME/out.bin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Downloaded file_id=file_abc"* ]]
  [[ "$(_args)" == *"-X GET https://api.anthropic.com/v1/files/file_abc/content "* ]]
  [ "$(cat "$HOME/out.bin")" = "downloaded-bytes" ]
}

@test "download requires both id and destination" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" download file_abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "download to a missing destination directory fails without calling curl" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" download file_abc "$HOME/nodir/out.bin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"destination directory does not exist"* ]]
  [ ! -f "$CURL_LOG" ]
}

# ---------- delete ----------

@test "delete DELETEs /v1/files/<id>" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" delete file_abc
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted file_id=file_abc"* ]]
  [[ "$(_args)" == *"-X DELETE https://api.anthropic.com/v1/files/file_abc "* ]]
}

@test "delete requires an id argument" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" delete
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: cast-files-api.sh delete <file-id>"* ]]
  [ ! -f "$CURL_LOG" ]
}

@test "delete with a curl failure exits 1" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" CURL_RC=22 bash "$SCRIPT" delete file_abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"delete failed (curl exit 22)"* ]]
}

# ---------- subcommand dispatch ----------

@test "no subcommand prints usage; unknown subcommand fails; neither calls curl" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown subcommand"* ]]
  [ ! -f "$CURL_LOG" ]
}

# ---------- logging + secrecy ----------

@test "logs dir is created with mode 700 when absent" {
  [ ! -d "$HOME/.claude/logs" ]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" delete file_abc
  [ "$status" -eq 0 ]
  [ "$(file_mode "$HOME/.claude/logs")" = "700" ]
}

@test "an existing world-readable logs dir is tightened to 700" {
  mkdir -p "$HOME/.claude/logs"
  chmod 755 "$HOME/.claude/logs"
  [ "$(file_mode "$HOME/.claude/logs")" = "755" ]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" delete file_abc
  [ "$status" -eq 0 ]
  [ "$(file_mode "$HOME/.claude/logs")" = "700" ]
}

@test "the log file is private (mode 600) and records action, id and agent" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" CAST_AGENT_NAME=some-agent bash "$SCRIPT" delete file_abc
  [ "$status" -eq 0 ]
  local log="$HOME/.claude/logs/files-api.log"
  [ "$(file_mode "$log")" = "600" ]
  grep -q 'action=delete file_id=file_abc .* agent=some-agent status=success' "$log"
}

@test "the API key never appears in any log file or in command output (success and failure paths)" {
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/doc.txt"
  [[ "$output" != *"$FAKE_KEY"* ]]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" CURL_RC=22 bash "$SCRIPT" upload "$HOME/doc.txt"
  [[ "$output" != *"$FAKE_KEY"* ]]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" download file_abc "$HOME/out.bin"
  [[ "$output" != *"$FAKE_KEY"* ]]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" CURL_RC=22 bash "$SCRIPT" delete file_abc
  [[ "$output" != *"$FAKE_KEY"* ]]
  run env "ANTHROPIC_API_KEY=$FAKE_KEY" bash "$SCRIPT" upload "$HOME/nope.txt"
  [[ "$output" != *"$FAKE_KEY"* ]]
  # control: the logs exist and are non-empty, so an absence match means something
  [ -s "$HOME/.claude/logs/files-api.log" ]
  [ -s "$HOME/.claude/logs/hook-errors.log" ]
  run grep -rlF "$FAKE_KEY" "$HOME/.claude"
  [ "$status" -eq 1 ]
  # control: the key IS in the curl shim's argv (it is sent as a header), so the search can find it
  run grep -c -F "$FAKE_KEY" "$CURL_LOG"
  [ "$output" -ge 1 ]
}
