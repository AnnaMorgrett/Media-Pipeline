#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        queue_worker.sh
#  @brief       Daemon controller for the persistent FIFO queue worker.
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

readonly PID_FILE="${SCRIPT_DIR}/.worker.pid"
readonly LOG_FILE="${SCRIPT_DIR}/media_processor_log.txt"

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

start_worker() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        printf "${C_YELLOW}[!] Queue worker is already running (PID: %s).${C_RESET}\n" "$pid"
        return 0
    fi

    printf "${C_BLUE}[*] Starting background queue worker...${C_RESET}\n"
    "$PY_BIN" "$SCRIPT_DIR/queue_worker.py" >> "$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$PID_FILE"

    sleep 0.5
    if kill -0 "$new_pid" 2>/dev/null; then
        printf "${C_GREEN}[✓] Queue worker started successfully in background (PID: %s).${C_RESET}\n" "$new_pid"
    else
        printf "${C_RED}[ERROR] Failed to start queue worker. Check logs in %s${C_RESET}\n" "$LOG_FILE" >&2
        rm -f "$PID_FILE"
        return 1
    fi
}

stop_worker() {
    if ! is_running; then
        printf "${C_YELLOW}[*] Queue worker is not currently running.${C_RESET}\n"
        rm -f "$PID_FILE"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")
    printf "${C_BLUE}[*] Stopping queue worker (PID: %s)...${C_RESET}\n" "$pid"
    kill -15 "$pid" 2>/dev/null || true

    # Wait up to 5 seconds
    local count=0
    while kill -0 "$pid" 2>/dev/null && (( count < 10 )); do
        sleep 0.5
        (( count++ ))
    done

    if kill -0 "$pid" 2>/dev/null; then
        printf "${C_YELLOW}[!] Worker still active; sending SIGKILL...${C_RESET}\n"
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    printf "${C_GREEN}[✓] Queue worker stopped.${C_RESET}\n"
}

status_worker() {
    if is_running; then
        local pid
        pid=$(cat "$PID_FILE")
        printf "${C_GREEN}[✓] Queue worker is RUNNING (PID: %s).${C_RESET}\n" "$pid"
    else
        printf "${C_YELLOW}[*] Queue worker is STOPPED.${C_RESET}\n"
    fi
    "$PY_BIN" "$SCRIPT_DIR/queue_manager.py" status
}

run_once() {
    printf "${C_BLUE}[*] Running single queue pass...${C_RESET}\n"
    "$PY_BIN" "$SCRIPT_DIR/queue_worker.py" --once
}

case "${1:-status}" in
    start)
        start_worker
        ;;
    stop)
        stop_worker
        ;;
    restart)
        stop_worker
        sleep 1
        start_worker
        ;;
    status)
        status_worker
        ;;
    run-once|once)
        run_once
        ;;
    *)
        echo "Usage: queue_worker.sh {start|stop|restart|status|run-once}"
        exit 1
        ;;
esac
