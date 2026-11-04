#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        notification_tile.sh
#  @brief       Notification Shade Controller & Quick Action Tile for Android Termux.
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

readonly PORT="${WEB_UI_PORT:-8080}"
readonly WEB_URL="http://127.0.0.1:${PORT}"
readonly NOTIF_ID="media_pipeline_tile"

show_tile() {
    command -v termux-notification &>/dev/null || return 0

    local custom_status="" custom_job=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status) custom_status="$2"; shift 2 ;;
            --job) custom_job="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Get queue status
    local q_json pending=0 total=0 w_status="idle" py_bin="python3"
    command -v python3 &>/dev/null || py_bin="python"
    if [[ -f "$SCRIPT_DIR/queue_manager.py" ]]; then
        q_json=$("$py_bin" "$SCRIPT_DIR/queue_manager.py" status 2>/dev/null || echo "{}")
        pending=$(printf '%s' "$q_json" | grep '"pending"' | head -1 | awk -F: '{print $2}' | tr -d ' ,')
        total=$(printf '%s' "$q_json" | grep '"total"' | head -1 | awk -F: '{print $2}' | tr -d ' ,')
        w_status=$(printf '%s' "$q_json" | grep '"worker_status"' | head -1 | awk -F: '{print $2}' | tr -d ' ",')
    fi

    local title_icon="🟢"
    [[ "$w_status" == "processing" ]] && title_icon="🔵"
    [[ "$w_status" == "paused" ]] && title_icon="🟡"
    [[ "$w_status" == "stopped" ]] && title_icon="⚪"

    local display_title="${title_icon} Media Normalizer (-9 LUFS)"
    local display_content
    if [[ -n "$custom_status" ]]; then
        display_content="${custom_status} ${custom_job:+($custom_job)} | Queue: ${pending:-0}"
    else
        display_content="Worker: ${w_status} | Queue: ${pending:-0} pending (${total:-0} total)"
    fi

    # Persistent notification with 3 quick action buttons
    termux-notification \
        --id "$NOTIF_ID" \
        --title "$display_title" \
        --content "$display_content" \
        --ongoing \
        --priority low \
        --action "termux-open-url '$WEB_URL'" \
        --button1 "⚡ Normalize" \
        --button1-action "bash -l -c 'bash \"$SCRIPT_DIR/master_run.sh\"'" \
        --button2 "🌐 Web UI" \
        --button2-action "termux-open-url '$WEB_URL'" \
        --button3 "⏯️ Worker" \
        --button3-action "bash -l -c 'if [[ -f \"$SCRIPT_DIR/.worker.pid\" ]]; then bash \"$SCRIPT_DIR/queue_worker.sh\" stop; else bash \"$SCRIPT_DIR/queue_worker.sh\" start; fi; bash \"$SCRIPT_DIR/notification_tile.sh\" update'" \
        2>/dev/null || true
}

remove_tile() {
    command -v termux-notification-remove &>/dev/null || return 0
    termux-notification-remove "$NOTIF_ID" 2>/dev/null || true
}

case "${1:-update}" in
    update|show)
        shift || true
        show_tile "$@"
        ;;
    remove|clear|hide)
        remove_tile
        ;;
    *)
        show_tile "$@"
        ;;
esac
