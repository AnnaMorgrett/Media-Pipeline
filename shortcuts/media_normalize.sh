#!/usr/bin/env bash
# Quick Settings Tile action: triggers media normalization
TARGET_DIR="/storage/emulated/0/Termux"
if [[ ! -d "$TARGET_DIR" ]]; then
    TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if command -v termux-toast &>/dev/null; then
    termux-toast "Media Pipeline: Starting Normalization (-9 LUFS)..."
fi

exec bash "$TARGET_DIR/master_run.sh"
