#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="${SCRIPT_DIR}/profile/airootfs/root/target-configs/extensions"
mkdir -p "$EXT_DIR"

XPI_ID="keepassxc-browser@keepassxc.org"
XPI_URL="https://addons.mozilla.org/firefox/downloads/latest/keepassxc-browser/latest.xpi"

echo "==> Downloading KeePassXC-Browser extension…"
curl -L -o "${EXT_DIR}/${XPI_ID}.xpi" "$XPI_URL"
echo "==> Saved to ${EXT_DIR}/${XPI_ID}.xpi"
