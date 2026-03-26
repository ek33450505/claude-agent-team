#!/bin/bash
# cast-install-7g.sh — Phase 7g install steps
# These steps need to be merged into install.sh when Phase 7e completes.
# Run manually with: bash scripts/cast-install-7g.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# 1. Install rumps
pip3 install rumps 2>/dev/null || echo "WARN: rumps install failed — status bar unavailable"
# 2. Copy status bar app
mkdir -p "${HOME}/.local/share/cast"
cp "${REPO_ROOT}/macos/cast-statusbar.py" "${HOME}/.local/share/cast/"
# 3. Install launchd plist (macOS only)
if [[ "$(uname)" == "Darwin" ]]; then
  PLIST_DST="${HOME}/Library/LaunchAgents/com.cast.statusbar.plist"
  sed "s|\${HOME}|${HOME}|g" "${REPO_ROOT}/macos/cast-statusbar.plist" > "$PLIST_DST"
  launchctl load "$PLIST_DST" 2>/dev/null || true
  echo "Installed: $PLIST_DST"
fi
# 4. Copy config templates if not present
for tmpl in notifications fs-watchers sync; do
  dst="${HOME}/.claude/config/${tmpl}.json"
  src="${REPO_ROOT}/config/${tmpl}.json.template"
  if [ ! -f "$dst" ] && [ -f "$src" ]; then
    cp "$src" "$dst"
    echo "Installed config: $dst"
  fi
done
# 5. Install scripts to PATH
SCRIPTS_DST="${HOME}/.local/bin"
mkdir -p "$SCRIPTS_DST"
for script in cast-notify cast-fswatcher cast-sync; do
  cp "${REPO_ROOT}/scripts/${script}.sh" "${SCRIPTS_DST}/${script}"
  chmod +x "${SCRIPTS_DST}/${script}"
  echo "Installed: ${SCRIPTS_DST}/${script}"
done
echo "Phase 7g install complete."
