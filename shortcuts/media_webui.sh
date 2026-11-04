#!/usr/bin/env bash
# Quick Settings Tile action: opens Web UI
TARGET_DIR="/storage/emulated/0/Termux"
if [[ ! -d "$TARGET_DIR" ]]; then
    TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

bash "$TARGET_DIR/webui.sh" start >/dev/null 2>&1 || true
exec bash "$TARGET_DIR/webui.sh" open
