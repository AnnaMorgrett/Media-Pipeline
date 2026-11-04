#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        share_handler.sh
#  @brief       Handles incoming Android Share intents (URLs and local video files).
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     3.0.0
# ═══════════════════════════════════════════════════════════════════════════════
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: share_handler.sh <URL|FILE_PATH>" >&2
    exit 1
fi

raw_input="$*"

if command -v python3 &>/dev/null; then
    PY_BIN="python3"
elif command -v python &>/dev/null; then
    PY_BIN="python"
else
    PY_BIN="python3"
fi

# 1. Enqueue item into persistent FIFO queue
out=$("$PY_BIN" "$SCRIPT_DIR/queue_manager.py" add "$raw_input" 2>&1)
rc=$?

echo "$out"

# 2. Extract clean short label for user toast/notification
short_label=$(printf '%s' "$raw_input" | tr '\n' ' ' | cut -c 1-50)

# 3. Android notification/toast feedback via Termux:API
if command -v termux-toast &>/dev/null; then
    if (( rc == 0 )); then
        if [[ "$out" == *"[DUPLICATE]"* ]]; then
            termux-toast -s "Already in queue: $short_label"
        else
            termux-toast -s "Queued (-9 LUFS): $short_label"
        fi
    else
        termux-toast -s "Queue error: $short_label"
    fi
elif command -v termux-notification &>/dev/null; then
    termux-notification \
        --id "media_share_toast" \
        --title "Media Normalizer (-9 LUFS)" \
        --content "Queued: $short_label" \
        --priority low 2>/dev/null || true
fi

# 4. Ensure background worker is awake and processing
bash "$SCRIPT_DIR/queue_worker.sh" start >/dev/null 2>&1 || true

exit $rc
