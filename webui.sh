#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        webui.sh
#  @brief       Daemon controller for the Mobile Web UI server.
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

readonly PID_FILE="${SCRIPT_DIR}/.webui.pid"
readonly LOG_FILE="${SCRIPT_DIR}/media_processor_log.txt"
readonly PORT="${WEB_UI_PORT:-8080}"
readonly URL="http://127.0.0.1:${PORT}"

if command -v python3 &>/dev/null; then
    PY_BIN="python3"
elif command -v python &>/dev/null; then
    PY_BIN="python"
else
    PY_BIN="python3"
fi

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_RESET=''
fi

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

start_webui() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        printf "${C_YELLOW}[!] Web UI is already running (PID: %s).${C_RESET}\n" "$pid"
        printf "  Open in browser: ${C_BOLD}%s${C_RESET}\n" "$URL"
        return 0
    fi

    printf "${C_BLUE}[*] Starting Mobile Web UI server on port %s...${C_RESET}\n" "$PORT"
    "$PY_BIN" "$SCRIPT_DIR/webui.py" >> "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    sleep 0.5
    if kill -0 "$new_pid" 2>/dev/null; then
        printf "${C_GREEN}[✓] Web UI successfully started in background (PID: %s).${C_RESET}\n" "$new_pid"
        printf "  Access URL: ${C_BOLD}%s${C_RESET}\n" "$URL"
    else
        printf "${C_RED}[ERROR] Web UI failed to start. Check %s${C_RESET}\n" "$LOG_FILE" >&2
        rm -f "$PID_FILE"
        return 1
    fi
}

stop_webui() {
    if ! is_running; then
        printf "${C_YELLOW}[*] Web UI is not currently running.${C_RESET}\n"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    printf "${C_BLUE}[*] Stopping Web UI (PID: %s)...${C_RESET}\n" "$pid"
    kill -15 "$pid" 2>/dev/null || true
    sleep 0.5
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    printf "${C_GREEN}[✓] Web UI stopped.${C_RESET}\n"
}

status_webui() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        printf "${C_GREEN}[✓] Web UI is RUNNING (PID: %s).${C_RESET}\n" "$pid"
        printf "  Local URL: %s\n" "$URL"
    else
        printf "${C_YELLOW}[*] Web UI is STOPPED.${C_RESET}\n"
    fi
}

open_browser() {
    if ! is_running; then
        start_webui
        sleep 1
    fi

    printf "${C_BLUE}[*] Opening %s in default browser...${C_RESET}\n" "$URL"
    if command -v termux-open-url &>/dev/null; then
        termux-open-url "$URL"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$URL" >/dev/null 2>&1 &
    elif command -v open &>/dev/null; then
        open "$URL"
    elif command -v cmd.exe &>/dev/null; then
        cmd.exe /c start "$URL" >/dev/null 2>&1
    else
        printf "${C_YELLOW}[!] Please open this URL in your browser: %s${C_RESET}\n" "$URL"
    fi
}

case "${1:-status}" in
    start)
        start_webui
        ;;
    stop)
        stop_webui
        ;;
    restart)
        stop_webui
        sleep 0.5
        start_webui
        ;;
    status)
        status_webui
        ;;
    open)
        open_browser
        ;;
    *)
        echo "Usage: webui.sh {start|stop|restart|status|open}"
        exit 1
        ;;
esac
