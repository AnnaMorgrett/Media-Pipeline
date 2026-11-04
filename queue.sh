#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        queue.sh
#  @brief       Global CLI shortcut for Persistent FIFO Queue operations.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     3.0.0
# ═══════════════════════════════════════════════════════════════════════════════
set -u

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    cat << EOF
Usage: queue <command> [arguments...]

Persistent FIFO Queue Commands:
  add <URL|FILE...>    Add one or more URLs/files to the processing queue
  list [pending|all]   List queued jobs with status
  status               Show worker state and job counts
  retry <job_id>       Retry a failed job
  retry-all            Retry all failed jobs
  delete <job_id>      Delete a job from the queue
  clear [failed]       Clear completed (or failed) jobs
  start                Start background queue worker
  stop                 Stop background queue worker
  restart              Restart background queue worker
  worker               Show queue worker process status
EOF
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

cmd="$1"
shift

if command -v python3 &>/dev/null; then
    PY_BIN="python3"
elif command -v python &>/dev/null; then
    PY_BIN="python"
else
    PY_BIN="python3"
fi

case "$cmd" in
    add)
        "$PY_BIN" "$SCRIPT_DIR/queue_manager.py" add "$@"
        bash "$SCRIPT_DIR/queue_worker.sh" start >/dev/null 2>&1 || true
        ;;
    list|status|next|recover|retry|retry-all|delete|clear)
        "$PY_BIN" "$SCRIPT_DIR/queue_manager.py" "$cmd" "$@"
        ;;
    start|stop|restart|worker)
        action="$cmd"
        [[ "$action" == "worker" ]] && action="status"
        bash "$SCRIPT_DIR/queue_worker.sh" "$action" "$@"
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        show_help >&2
        exit 1
        ;;
esac
