#!/bin/bash
# cast-airgap.sh — CAST air-gap mode toggle
#
# Controls the airgap flag in ~/.claude/config/cast-cli.json.
# When active, route.sh rewrites cloud: model routes to local: equivalents
# and injects [CAST-AIRGAP] into the session briefing context.
#
# Usage:
#   cast-airgap.sh on      Enable air-gap mode
#   cast-airgap.sh off     Disable air-gap mode
#   cast-airgap.sh status  Print current state

set -uo pipefail

CONFIG_FILE="${HOME}/.claude/config/cast-cli.json"
SUBCMD="${1:-status}"

# Ensure config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  mkdir -p "$(dirname "$CONFIG_FILE")"
  echo '{}' > "$CONFIG_FILE"
fi

case "$SUBCMD" in
  on)
    python3 - "$CONFIG_FILE" "true" <<'PYEOF'
import sys, json

config_file = sys.argv[1]
airgap_val = sys.argv[2] == "true"

try:
    with open(config_file) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

cfg['airgap'] = airgap_val

with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
    echo "[CAST-AIRGAP ON] Air-gap mode enabled. Cloud routes will be rewritten to local:qwen3:8b."
    ;;

  off)
    python3 - "$CONFIG_FILE" "false" <<'PYEOF'
import sys, json

config_file = sys.argv[1]
airgap_val = sys.argv[2] == "true"

try:
    with open(config_file) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

cfg['airgap'] = airgap_val

with open(config_file, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
PYEOF
    echo "[CAST-AIRGAP OFF] Air-gap mode disabled. Cloud routes restored."
    ;;

  status)
    python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, json, os

config_file = sys.argv[1]
try:
    with open(config_file) as f:
        cfg = json.load(f)
    airgap = cfg.get('airgap', False)
except Exception:
    airgap = False

# Also check CAST_AIRGAP env var
if os.environ.get('CAST_AIRGAP', '0') == '1':
    airgap = True

if airgap:
    print("[AIRGAP: ON]  Cloud routes rewrite to local:qwen3:8b")
else:
    print("[AIRGAP: OFF] Normal routing (cloud + local)")
PYEOF
    ;;

  --help|-h)
    cat <<USAGE
Usage: cast-airgap.sh <on|off|status>

  on      Enable air-gap mode (write airgap=true to cast-cli.json)
  off     Disable air-gap mode (write airgap=false to cast-cli.json)
  status  Print current air-gap state

When air-gap is ON:
  - route.sh rewrites cloud: model routes to local:qwen3:8b
  - [CAST-AIRGAP] is injected into the session briefing context
  - cast status shows [AIRGAP: ON]

Config: ${HOME}/.claude/config/cast-cli.json
USAGE
    ;;

  *)
    echo "Error: Unknown argument: $SUBCMD" >&2
    echo "Usage: cast-airgap.sh on|off|status" >&2
    exit 1
    ;;
esac
