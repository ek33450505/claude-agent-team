#!/bin/bash
# cast-rtk-install.sh — Install RTK token compression tool
set -euo pipefail

if command -v rtk >/dev/null 2>&1; then
  echo "rtk already installed: $(rtk --version 2>/dev/null || echo unknown)"
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found. Install Rust first: https://rustup.rs" >&2
  exit 1
fi

echo "Installing rtk from github.com/rtk-ai/rtk..."
cargo install --git https://github.com/rtk-ai/rtk 2>&1
echo "Done. Verify: rtk --version"
