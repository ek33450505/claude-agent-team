#!/bin/bash
# cast-keychain.sh — macOS Keychain integration for CAST secrets
#
# Provides get/set/delete/list/status subcommands for storing CAST secrets
# in the macOS Keychain instead of .env files. All entries use the service
# prefix "cast-" to namespace CAST secrets.
#
# This is an OPT-IN tool. It does NOT automatically enforce Keychain usage.
# The user chooses when to store/retrieve secrets via Keychain.
#
# Usage:
#   cast-keychain.sh set <service> <secret>   Store a secret
#   cast-keychain.sh get <service>             Retrieve a secret
#   cast-keychain.sh delete <service>          Remove a secret
#   cast-keychain.sh list                      List all cast-* entries
#   cast-keychain.sh status                    Check if ANTHROPIC_API_KEY is in Keychain

set -euo pipefail

SUBCMD="${1:-}"
SERVICE_PREFIX="cast-"

usage() {
  cat <<USAGE
Usage: cast-keychain.sh <command> [args]

Commands:
  set <service> <secret>   Store a secret in macOS Keychain
  get <service>            Retrieve a secret from Keychain
  delete <service>         Remove a secret from Keychain
  list                     List all cast-* Keychain entries
  status                   Report whether ANTHROPIC_API_KEY is in Keychain

Examples:
  cast-keychain.sh set anthropic-api-key "sk-ant-..."
  cast-keychain.sh get anthropic-api-key
  cast-keychain.sh delete anthropic-api-key
  cast-keychain.sh status

All Keychain entries use service prefix "cast-" (e.g., cast-anthropic-api-key).
This is an opt-in tool — secrets are only stored when you explicitly run 'set'.
USAGE
  exit "${1:-0}"
}

# Verify we're on macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: cast-keychain.sh requires macOS (uses 'security' CLI)" >&2
  exit 1
fi

case "$SUBCMD" in
  set)
    SERVICE="${2:-}"
    SECRET="${3:-}"
    if [[ -z "$SERVICE" || -z "$SECRET" ]]; then
      echo "Error: 'set' requires <service> and <secret> arguments" >&2
      echo "Usage: cast-keychain.sh set <service> <secret>" >&2
      exit 1
    fi
    FULL_SERVICE="${SERVICE_PREFIX}${SERVICE}"
    # -U flag updates if entry already exists
    if security add-generic-password -U -s "$FULL_SERVICE" -a cast -w "$SECRET" 2>/dev/null; then
      echo "Stored secret for service '${FULL_SERVICE}' in Keychain"
    else
      echo "Error: Failed to store secret in Keychain" >&2
      exit 1
    fi
    ;;

  get)
    SERVICE="${2:-}"
    if [[ -z "$SERVICE" ]]; then
      echo "Error: 'get' requires <service> argument" >&2
      echo "Usage: cast-keychain.sh get <service>" >&2
      exit 1
    fi
    FULL_SERVICE="${SERVICE_PREFIX}${SERVICE}"
    if VALUE=$(security find-generic-password -s "$FULL_SERVICE" -a cast -w 2>/dev/null); then
      echo "$VALUE"
    else
      echo "Error: No Keychain entry found for service '${FULL_SERVICE}'" >&2
      exit 1
    fi
    ;;

  delete)
    SERVICE="${2:-}"
    if [[ -z "$SERVICE" ]]; then
      echo "Error: 'delete' requires <service> argument" >&2
      echo "Usage: cast-keychain.sh delete <service>" >&2
      exit 1
    fi
    FULL_SERVICE="${SERVICE_PREFIX}${SERVICE}"
    if security delete-generic-password -s "$FULL_SERVICE" -a cast 2>/dev/null; then
      echo "Deleted Keychain entry for service '${FULL_SERVICE}'"
    else
      echo "Error: No Keychain entry found for service '${FULL_SERVICE}'" >&2
      exit 1
    fi
    ;;

  list)
    echo "CAST Keychain Entries:"
    echo "====================="
    # Search for all cast- prefixed generic passwords
    # security dump-keychain outputs all entries; we filter for cast- service names
    ENTRIES=$(security dump-keychain 2>/dev/null | grep -A4 '"svce"<blob>="cast-"' | grep '"svce"' | sed 's/.*="//;s/".*//' 2>/dev/null || true)
    if [[ -z "$ENTRIES" ]]; then
      # Fallback: try a broader search
      ENTRIES=$(security dump-keychain 2>/dev/null | grep '"svce"<blob>="cast-' | sed 's/.*="//;s/".*//' 2>/dev/null || true)
    fi
    if [[ -z "$ENTRIES" ]]; then
      echo "  (none found)"
    else
      while IFS= read -r entry; do
        echo "  - $entry"
      done <<< "$ENTRIES"
    fi
    ;;

  status)
    echo "CAST Keychain Status:"
    echo "===================="
    # Check if ANTHROPIC_API_KEY is in Keychain
    if security find-generic-password -s "cast-anthropic-api-key" -a cast -w >/dev/null 2>&1; then
      echo "  ANTHROPIC_API_KEY: stored in Keychain"
    else
      echo "  ANTHROPIC_API_KEY: not in Keychain"
    fi
    # Check if env var is set
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      echo "  ANTHROPIC_API_KEY env var: set"
    else
      echo "  ANTHROPIC_API_KEY env var: not set"
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
    echo "Usage: cast-keychain.sh <set|get|delete|list|status>" >&2
    exit 1
    ;;
esac
