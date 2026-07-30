#!/bin/bash
# cast-encrypt.sh — age encryption for CAST agent memory files
#
# Provides setup/encrypt/decrypt/status subcommands for encrypting
# ~/.claude/agent-memory-local/ using the age encryption tool.
# Supports optional Secure Enclave via age-plugin-se.
#
# This is an OPT-IN tool. It NEVER auto-encrypts without explicit user action.
# The user must never get locked out of their own data.
#
# Usage:
#   cast-encrypt.sh setup     Generate age keypair
#   cast-encrypt.sh encrypt   Encrypt agent memory files
#   cast-encrypt.sh decrypt   Decrypt agent memory files
#   cast-encrypt.sh status    Report encryption state

set -euo pipefail

SUBCMD="${1:-}"
MEMORY_DIR="${HOME}/.claude/agent-memory-local"
PUB_KEY_PATH="${HOME}/.claude/cast-security.pub"
CONFIG_FILE="${HOME}/.claude/config/cast-cli.json"

usage() {
  cat <<USAGE
Usage: cast-encrypt.sh <command>

Commands:
  setup     Generate age keypair (stores public key at ~/.claude/cast-security.pub)
  encrypt   Encrypt all files in agent-memory-local/ (requires confirmation)
  decrypt   Decrypt .age files back to plaintext
  status    Report encryption state, key presence, age availability

Dependencies:
  - age (brew install age)
  - age-plugin-se (optional, for Secure Enclave support)

This is an opt-in tool — encryption only happens when you explicitly run 'encrypt'.
You will always be prompted for confirmation before any destructive operation.
USAGE
  exit "${1:-0}"
}

# Check age dependency
check_age() {
  if ! command -v age >/dev/null 2>&1; then
    echo "Error: 'age' is not installed." >&2
    echo "Install with: brew install age" >&2
    exit 1
  fi
}

# Read private key path from config
get_key_path() {
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 - "$CONFIG_FILE" <<'PYEOF' 2>/dev/null || echo ""
import sys, json, os

config_file = sys.argv[1]
try:
    with open(config_file) as f:
        cfg = json.load(f)
    print(os.path.expanduser(cfg.get('encryption', {}).get('key_path', '')))
except Exception:
    print('')
PYEOF
  else
    echo ""
  fi
}

# Save key path to config
save_key_path() {
  local key_path="$1"
  python3 - "$CONFIG_FILE" "$key_path" <<'PYEOF'
import sys, json, os

config_file = sys.argv[1]
key_path = sys.argv[2]

try:
    with open(config_file) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

if 'encryption' not in cfg:
    cfg['encryption'] = {}
cfg['encryption']['key_path'] = key_path

os.makedirs(os.path.dirname(config_file), exist_ok=True)
with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
}

# Read Secure Enclave identity file path from config
get_identity_path() {
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 - "$CONFIG_FILE" <<'PYEOF' 2>/dev/null || echo ""
import sys, json, os

config_file = sys.argv[1]
try:
    with open(config_file) as f:
        cfg = json.load(f)
    print(os.path.expanduser(cfg.get('encryption', {}).get('identity_path', '')))
except Exception:
    print('')
PYEOF
  else
    echo ""
  fi
}

# Save Secure Enclave identity file path to config
save_identity_path() {
  local identity_path="$1"
  python3 - "$CONFIG_FILE" "$identity_path" <<'PYEOF'
import sys, json, os

config_file = sys.argv[1]
identity_path = sys.argv[2]

try:
    with open(config_file) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

if 'encryption' not in cfg:
    cfg['encryption'] = {}
cfg['encryption']['identity_path'] = identity_path

os.makedirs(os.path.dirname(config_file), exist_ok=True)
with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
}

case "$SUBCMD" in
  setup)
    check_age

    # Check for Secure Enclave plugin
    if command -v age-plugin-se >/dev/null 2>&1; then
      echo "Secure Enclave plugin (age-plugin-se) detected."
      echo "Using Secure Enclave for key generation."
      echo ""
      # Generate SE-backed key. The identity file written by `keygen -o`
      # contains the AGE-PLUGIN-SE-1... handle — the ONLY reference to the
      # enclave key. It MUST live outside ~/.claude (wiped twice historically)
      # so a ~/.claude wipe never orphans the enclave key.
      SE_IDENTITY_FILE="${CAST_SE_IDENTITY_PATH:-${HOME}/Library/Application Support/cast/cast-se-identity.txt}"

      if [[ -f "$SE_IDENTITY_FILE" ]]; then
        echo "Error: Identity file already exists at $SE_IDENTITY_FILE." >&2
        echo "Encryption is already set up. To re-key, back up and remove it first, then re-run setup." >&2
        exit 1
      fi

      SE_IDENTITY_DIR="$(dirname "$SE_IDENTITY_FILE")"
      mkdir -p "$SE_IDENTITY_DIR"
      chmod 700 "$SE_IDENTITY_DIR"
      # umask 077 closes the world-readable window between file creation and
      # the explicit chmod 600 below; set -e can abort mid-window otherwise.
      (umask 077; age-plugin-se keygen -o "$SE_IDENTITY_FILE")
      chmod 600 "$SE_IDENTITY_FILE"
      RECIPIENT=$(grep "public key:" "$SE_IDENTITY_FILE" | sed 's/.*public key: //')
      if [[ -n "$RECIPIENT" ]]; then
        echo "$RECIPIENT" > "$PUB_KEY_PATH"
        echo "Public key saved to: $PUB_KEY_PATH"
        echo "Private key is stored in Secure Enclave (hardware-backed)."
        echo "Identity file: $SE_IDENTITY_FILE"
        echo ""
        echo "IMPORTANT: Back up $SE_IDENTITY_FILE. It references the Secure"
        echo "Enclave key; without it, encrypted data cannot be decrypted."
        save_key_path "secure-enclave"
        save_identity_path "$SE_IDENTITY_FILE"
      else
        echo "Error: Secure Enclave key generation failed" >&2
        exit 1
      fi
    else
      KEY_DIR="${HOME}/.claude/keys"
      KEY_FILE="${KEY_DIR}/cast-age-key.txt"

      if [[ -f "$KEY_FILE" ]]; then
        echo "Error: Identity file already exists at $KEY_FILE." >&2
        echo "Encryption is already set up. To re-key, back up and remove it first, then re-run setup." >&2
        exit 1
      fi

      echo "Generating age keypair..."
      mkdir -p "$KEY_DIR"
      chmod 700 "$KEY_DIR"

      # umask 077 closes the world-readable window between file creation and
      # the explicit chmod 600 below; set -e can abort mid-window otherwise.
      (umask 077; age-keygen -o "$KEY_FILE")
      chmod 600 "$KEY_FILE"

      # Extract public key
      RECIPIENT=$(grep "public key:" "$KEY_FILE" | sed 's/.*public key: //')
      echo "$RECIPIENT" > "$PUB_KEY_PATH"

      save_key_path "$KEY_FILE"

      echo ""
      echo "Keypair generated:"
      echo "  Public key:  $PUB_KEY_PATH"
      echo "  Private key: $KEY_FILE"
      echo ""
      echo "IMPORTANT: Back up your private key securely. If lost, encrypted data"
      echo "cannot be recovered. Consider storing a copy in a password manager."
    fi
    ;;

  encrypt)
    check_age

    if [[ ! -f "$PUB_KEY_PATH" ]]; then
      echo "Error: No public key found at $PUB_KEY_PATH" >&2
      echo "Run 'cast-encrypt.sh setup' first to generate a keypair." >&2
      exit 1
    fi

    if [[ ! -d "$MEMORY_DIR" ]]; then
      echo "Error: Agent memory directory not found: $MEMORY_DIR" >&2
      exit 1
    fi

    RECIPIENT=$(cat "$PUB_KEY_PATH")
    if [[ -z "$RECIPIENT" ]]; then
      echo "Error: Public key file is empty" >&2
      exit 1
    fi

    # Count files to encrypt (exclude .age files and directories)
    FILE_COUNT=$(find "$MEMORY_DIR" -type f ! -name "*.age" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$FILE_COUNT" -eq 0 ]]; then
      echo "No plaintext files to encrypt in $MEMORY_DIR"
      exit 0
    fi

    echo "This will encrypt $FILE_COUNT file(s) in $MEMORY_DIR"
    echo "Plaintext originals will be REMOVED after encryption."
    echo ""
    read -r -p "Proceed? [y/N] " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi

    ENCRYPTED=0
    FAILED=0
    while IFS= read -r -d '' file; do
      if age -r "$RECIPIENT" -o "${file}.age" "$file" 2>/dev/null; then
        rm -f "$file"
        ENCRYPTED=$((ENCRYPTED + 1))
      else
        echo "  Failed to encrypt: $file" >&2
        FAILED=$((FAILED + 1))
      fi
    done < <(find "$MEMORY_DIR" -type f ! -name "*.age" -print0 2>/dev/null)

    echo ""
    echo "Encryption complete: $ENCRYPTED encrypted, $FAILED failed"
    ;;

  decrypt)
    check_age

    KEY_PATH=$(get_key_path)
    if [[ -z "$KEY_PATH" || "$KEY_PATH" == "secure-enclave" ]]; then
      if [[ "$KEY_PATH" == "secure-enclave" ]]; then
        # SE-backed decryption still requires the identity file handle so age
        # can hand it to age-plugin-se; the plugin does not locate it on its own.
        SE_IDENTITY_FILE=$(get_identity_path)
        if [[ -z "$SE_IDENTITY_FILE" || ! -f "$SE_IDENTITY_FILE" ]]; then
          echo "Error: Identity file not found at ${SE_IDENTITY_FILE:-<unset>}; re-run setup." >&2
          exit 1
        fi
        KEY_FLAGS=(-i "$SE_IDENTITY_FILE")
      else
        echo "Error: No private key path configured." >&2
        echo "Run 'cast-encrypt.sh setup' first." >&2
        exit 1
      fi
    else
      if [[ ! -f "$KEY_PATH" ]]; then
        echo "Error: Private key not found at $KEY_PATH" >&2
        exit 1
      fi
      KEY_FLAGS=(-i "$KEY_PATH")
    fi

    # Count .age files
    AGE_COUNT=$(find "$MEMORY_DIR" -name "*.age" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$AGE_COUNT" -eq 0 ]]; then
      echo "No encrypted (.age) files found in $MEMORY_DIR"
      exit 0
    fi

    echo "Decrypting $AGE_COUNT file(s) in $MEMORY_DIR..."

    DECRYPTED=0
    FAILED=0
    while IFS= read -r -d '' file; do
      PLAINTEXT="${file%.age}"
      if age --decrypt "${KEY_FLAGS[@]}" -o "$PLAINTEXT" "$file" 2>/dev/null; then
        rm -f "$file"
        DECRYPTED=$((DECRYPTED + 1))
      else
        echo "  Failed to decrypt: $file" >&2
        FAILED=$((FAILED + 1))
      fi
    done < <(find "$MEMORY_DIR" -name "*.age" -type f -print0 2>/dev/null)

    echo ""
    echo "Decryption complete: $DECRYPTED decrypted, $FAILED failed"
    ;;

  status)
    echo "CAST Encryption Status:"
    echo "======================="

    # Check age installation
    if command -v age >/dev/null 2>&1; then
      AGE_VERSION=$(age --version 2>/dev/null || echo "unknown")
      echo "  age: installed ($AGE_VERSION)"
    else
      echo "  age: not installed (brew install age)"
    fi

    # Check Secure Enclave plugin
    if command -v age-plugin-se >/dev/null 2>&1; then
      echo "  age-plugin-se: installed (Secure Enclave available)"
    else
      echo "  age-plugin-se: not installed (optional)"
    fi

    # Check public key
    if [[ -f "$PUB_KEY_PATH" ]]; then
      echo "  Public key: $PUB_KEY_PATH (present)"
    else
      echo "  Public key: not configured (run 'cast-encrypt.sh setup')"
    fi

    # Check private key
    KEY_PATH=$(get_key_path)
    if [[ "$KEY_PATH" == "secure-enclave" ]]; then
      echo "  Private key: Secure Enclave (hardware-backed)"
      SE_IDENTITY_FILE=$(get_identity_path)
      if [[ -n "$SE_IDENTITY_FILE" && -f "$SE_IDENTITY_FILE" ]]; then
        echo "  Identity file: $SE_IDENTITY_FILE (present)"
      else
        echo "  Identity file: ${SE_IDENTITY_FILE:-not configured} (missing)"
      fi
    elif [[ -n "$KEY_PATH" && -f "$KEY_PATH" ]]; then
      echo "  Private key: $KEY_PATH (present)"
    else
      echo "  Private key: not configured"
    fi

    # Check memory state
    if [[ -d "$MEMORY_DIR" ]]; then
      PLAIN_COUNT=$(find "$MEMORY_DIR" -type f ! -name "*.age" 2>/dev/null | wc -l | tr -d ' ')
      AGE_COUNT=$(find "$MEMORY_DIR" -name "*.age" -type f 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$PLAIN_COUNT" -eq 0 && "$AGE_COUNT" -gt 0 ]]; then
        echo "  Memory state: encrypted ($AGE_COUNT .age files)"
      elif [[ "$PLAIN_COUNT" -gt 0 && "$AGE_COUNT" -eq 0 ]]; then
        echo "  Memory state: decrypted ($PLAIN_COUNT plaintext files)"
      elif [[ "$PLAIN_COUNT" -gt 0 && "$AGE_COUNT" -gt 0 ]]; then
        echo "  Memory state: mixed ($PLAIN_COUNT plaintext, $AGE_COUNT encrypted)"
      else
        echo "  Memory state: empty (no files)"
      fi
    else
      echo "  Memory state: directory not found ($MEMORY_DIR)"
    fi
    ;;

  --help|-h)
    usage 0
    ;;

  "")
    usage 1
    ;;

  *)
    echo "Error: Unknown command: $SUBCMD" >&2
    echo "Usage: cast-encrypt.sh <setup|encrypt|decrypt|status>" >&2
    exit 1
    ;;
esac
