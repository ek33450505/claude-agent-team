#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAST_ENCRYPT_SH="$REPO_DIR/scripts/cast-encrypt.sh"
export CAST_ENCRYPT_SH

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
  load 'helpers/setup'
  setup_temp_home  # sets HOME to a temp dir; exports ORIG_HOME
}

teardown() {
  teardown_temp_home
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "cast-encrypt.sh: no args prints usage and exits 1" {
  run bash "$CAST_ENCRYPT_SH"
  assert_failure
  assert_output --partial "Usage:"
}

@test "cast-encrypt.sh: --help prints usage and exits 0" {
  run bash "$CAST_ENCRYPT_SH" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Commands:"
}

@test "cast-encrypt.sh: unknown command exits 1" {
  run bash "$CAST_ENCRYPT_SH" bogus
  assert_failure
  assert_output --partial "Unknown command"
}

@test "cast-encrypt.sh: status reports age availability" {
  run bash "$CAST_ENCRYPT_SH" status
  # Should succeed regardless of age being installed
  assert_output --partial "CAST Encryption Status"
  assert_output --partial "age:"
}

@test "cast-encrypt.sh: status reports memory state" {
  run bash "$CAST_ENCRYPT_SH" status
  assert_output --partial "Memory state:"
}

@test "cast-encrypt.sh: encrypt without setup fails" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  # HOME is already a fresh temp via setup_temp_home; no real keys exist
  mkdir -p "$HOME/.claude/agent-memory-local"

  run bash "$CAST_ENCRYPT_SH" encrypt
  assert_failure
  assert_output --partial "No public key found"
}

@test "cast-encrypt.sh: setup generates keypair when age is installed" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  # HOME is already a fresh temp via setup_temp_home
  mkdir -p "$HOME/.claude/config"

  run bash "$CAST_ENCRYPT_SH" setup
  assert_success

  # Branch-aware: whichever branch setup takes depends on whether the host
  # actually has age-plugin-se on PATH (Secure Enclave hardware) — assert
  # the output matching whatever this host really has, rather than assuming
  # the software branch.
  if command -v age-plugin-se >/dev/null 2>&1; then
    assert_output --partial "Secure Enclave"
    assert_output --partial "Public key saved"
  else
    assert_output --partial "Keypair generated"
  fi

  # Verify public key was created
  [ -f "$HOME/.claude/cast-security.pub" ]
}

@test "cast-encrypt.sh: software-key setup refuses to overwrite an existing key" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  mkdir -p "$HOME/.claude/config"

  # Force the software-key branch deterministically (see round-trip test below
  # for why: this dev box may have real age-plugin-se on PATH).
  REAL_AGE="$(command -v age)"
  REAL_AGE_KEYGEN="$(command -v age-keygen)"
  STUB_DIR="$BATS_TEST_TMPDIR/software-only-bin-overwrite"
  mkdir -p "$STUB_DIR"
  ln -sf "$REAL_AGE" "$STUB_DIR/age"
  ln -sf "$REAL_AGE_KEYGEN" "$STUB_DIR/age-keygen"
  FILTERED_PATH="$(dirname "$REAL_AGE")"
  SAFE_PATH="$STUB_DIR:$(echo "$PATH" | tr ':' '\n' | grep -v -F "$FILTERED_PATH" | paste -sd ':' -)"

  PATH="$SAFE_PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_success

  # Second setup run must refuse, not silently re-key (the exact lockout
  # this whole fix exists to prevent).
  PATH="$SAFE_PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_failure
  assert_output --partial "already exists"
  assert_output --partial "Encryption is already set up"
}

@test "cast-encrypt.sh: software-key file is mode 600 and its dir is mode 700" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  mkdir -p "$HOME/.claude/config"

  REAL_AGE="$(command -v age)"
  REAL_AGE_KEYGEN="$(command -v age-keygen)"
  STUB_DIR="$BATS_TEST_TMPDIR/software-only-bin-perms"
  mkdir -p "$STUB_DIR"
  ln -sf "$REAL_AGE" "$STUB_DIR/age"
  ln -sf "$REAL_AGE_KEYGEN" "$STUB_DIR/age-keygen"
  FILTERED_PATH="$(dirname "$REAL_AGE")"
  SAFE_PATH="$STUB_DIR:$(echo "$PATH" | tr ':' '\n' | grep -v -F "$FILTERED_PATH" | paste -sd ':' -)"

  PATH="$SAFE_PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_success

  KEY_FILE="$HOME/.claude/keys/cast-age-key.txt"
  KEY_DIR="$HOME/.claude/keys"
  [ -f "$KEY_FILE" ]

  FILE_PERMS="$(stat -c '%a' "$KEY_FILE" 2>/dev/null || stat -f '%OLp' "$KEY_FILE" 2>/dev/null)"
  DIR_PERMS="$(stat -c '%a' "$KEY_DIR" 2>/dev/null || stat -f '%OLp' "$KEY_DIR" 2>/dev/null)"
  [ "$FILE_PERMS" = "600" ]
  [ "$DIR_PERMS" = "700" ]
}

@test "cast-encrypt.sh: SE setup refuses to overwrite an existing identity file" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  mkdir -p "$HOME/.claude/config"

  STUB_DIR="$BATS_TEST_TMPDIR/se-stubs-overwrite"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/age-plugin-se" <<'STUB'
#!/bin/bash
if [[ "$1" == "keygen" && "$2" == "-o" ]]; then
  {
    echo "# created: fake"
    echo "# public key: age1se1testfakepublickeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo "AGE-PLUGIN-SE-1TESTFAKEIDENTITYHANDLExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  } > "$3"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_DIR/age-plugin-se"

  PATH="$STUB_DIR:$PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_success

  IDENTITY_FILE="$HOME/Library/Application Support/cast/cast-se-identity.txt"
  [ -f "$IDENTITY_FILE" ]

  # Second setup run must refuse, not silently re-key the enclave.
  PATH="$STUB_DIR:$PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_failure
  assert_output --partial "already exists"
  assert_output --partial "Encryption is already set up"
}

@test "cast-encrypt.sh: SE identity file is mode 600 and its dir is mode 700" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  mkdir -p "$HOME/.claude/config"

  STUB_DIR="$BATS_TEST_TMPDIR/se-stubs-perms"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/age-plugin-se" <<'STUB'
#!/bin/bash
if [[ "$1" == "keygen" && "$2" == "-o" ]]; then
  {
    echo "# created: fake"
    echo "# public key: age1se1testfakepublickeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo "AGE-PLUGIN-SE-1TESTFAKEIDENTITYHANDLExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  } > "$3"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_DIR/age-plugin-se"

  PATH="$STUB_DIR:$PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_success

  IDENTITY_FILE="$HOME/Library/Application Support/cast/cast-se-identity.txt"
  IDENTITY_DIR="$HOME/Library/Application Support/cast"
  [ -f "$IDENTITY_FILE" ]

  FILE_PERMS="$(stat -c '%a' "$IDENTITY_FILE" 2>/dev/null || stat -f '%OLp' "$IDENTITY_FILE" 2>/dev/null)"
  DIR_PERMS="$(stat -c '%a' "$IDENTITY_DIR" 2>/dev/null || stat -f '%OLp' "$IDENTITY_DIR" 2>/dev/null)"
  [ "$FILE_PERMS" = "600" ]
  [ "$DIR_PERMS" = "700" ]
}

@test "cast-encrypt.sh: software-key encrypt/decrypt round-trip preserves content" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  mkdir -p "$HOME/.claude/config"
  mkdir -p "$HOME/.claude/agent-memory-local"

  # Force the software-key branch even on machines with a real age-plugin-se
  # on PATH (e.g. this dev box): build a PATH with only a symlink to the real
  # `age` binary, excluding whatever directory holds age-plugin-se.
  REAL_AGE="$(command -v age)"
  REAL_AGE_KEYGEN="$(command -v age-keygen)"
  STUB_DIR="$BATS_TEST_TMPDIR/software-only-bin"
  mkdir -p "$STUB_DIR"
  ln -sf "$REAL_AGE" "$STUB_DIR/age"
  ln -sf "$REAL_AGE_KEYGEN" "$STUB_DIR/age-keygen"
  FILTERED_PATH="$(dirname "$REAL_AGE")"
  SAFE_PATH="$STUB_DIR:$(echo "$PATH" | tr ':' '\n' | grep -v -F "$FILTERED_PATH" | paste -sd ':' -)"

  PATH="$SAFE_PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_success

  PLAINTEXT_FILE="$HOME/.claude/agent-memory-local/test-memory.md"
  echo "sensitive round-trip content" > "$PLAINTEXT_FILE"

  run bash -c 'printf "y\n" | bash "$CAST_ENCRYPT_SH" encrypt'
  assert_success
  [ -f "${PLAINTEXT_FILE}.age" ]
  [ ! -f "$PLAINTEXT_FILE" ]

  run bash "$CAST_ENCRYPT_SH" decrypt
  assert_success
  [ -f "$PLAINTEXT_FILE" ]
  [ ! -f "${PLAINTEXT_FILE}.age" ]
  run cat "$PLAINTEXT_FILE"
  assert_output "sensitive round-trip content"
}

@test "cast-encrypt.sh: SE setup persists identity file outside ~/.claude and decrypt passes -i" {
  if ! command -v age >/dev/null 2>&1; then
    skip "age not installed"
  fi
  mkdir -p "$HOME/.claude/config"

  # Stub age-plugin-se: keygen -o FILE writes a fake public-key line + a fake
  # AGE-PLUGIN-SE identity line to FILE, mimicking real plugin output.
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/age-plugin-se" <<'STUB'
#!/bin/bash
if [[ "$1" == "keygen" && "$2" == "-o" ]]; then
  {
    echo "# created: fake"
    echo "# public key: age1se1testfakepublickeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo "AGE-PLUGIN-SE-1TESTFAKEIDENTITYHANDLExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  } > "$3"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_DIR/age-plugin-se"

  # Stub age: records every invocation's argv so we can assert -i was passed.
  ARGV_LOG="$BATS_TEST_TMPDIR/age-argv.log"
  cat > "$STUB_DIR/age" <<STUB
#!/bin/bash
echo "\$@" >> "$ARGV_LOG"
exit 0
STUB
  chmod +x "$STUB_DIR/age"

  PATH="$STUB_DIR:$PATH" run bash "$CAST_ENCRYPT_SH" setup
  assert_success
  assert_output --partial "Secure Enclave"

  # Identity file must NOT live under ~/.claude (wipe-safety).
  IDENTITY_FILE="$HOME/Library/Application Support/cast/cast-se-identity.txt"
  [ -f "$IDENTITY_FILE" ]
  run grep -q "AGE-PLUGIN-SE-1TEST" "$IDENTITY_FILE"
  assert_success

  # Recipient landed in the public key path.
  run cat "$HOME/.claude/cast-security.pub"
  assert_output --partial "age1se1test"

  # Decrypt must pass -i <identity file>, never an empty KEY_FLAG.
  mkdir -p "$HOME/.claude/agent-memory-local"
  touch "$HOME/.claude/agent-memory-local/fake.md.age"

  PATH="$STUB_DIR:$PATH" run bash "$CAST_ENCRYPT_SH" decrypt
  assert_success
  run grep -- "-i $IDENTITY_FILE" "$ARGV_LOG"
  assert_success
}
