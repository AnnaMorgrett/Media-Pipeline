#!/usr/bin/env bash
# Update yt-dlp to a selected upstream release channel.
# master = canary source; nightly = recommended development snapshots; stable = stable PyPI.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config_lib.sh" ]]; then
    # shellcheck source=config_lib.sh
    source "$SCRIPT_DIR/config_lib.sh"
    load_config "${PIPELINE_CONFIG:-$SCRIPT_DIR/data/config.conf}"
fi

CHANNEL="${YT_DLP_CHANNEL:-master}"
INTERVAL="${YT_DLP_UPDATE_INTERVAL:-21600}"
FORCE="${YT_DLP_FORCE_UPDATE:-0}"
case "$CHANNEL" in master|nightly|stable) ;; *) echo "Invalid YT_DLP_CHANNEL='$CHANNEL' (use master, nightly, or stable)." >&2; exit 2 ;; esac
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || INTERVAL=21600

# Never replace the downloader while a queue worker may be using it.
WORKER_PID_FILE="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}/.worker.lock/pid"
if [[ -r "$WORKER_PID_FILE" ]]; then
    worker_pid=$(cat "$WORKER_PID_FILE" 2>/dev/null || true)
    if [[ "$worker_pid" =~ ^[0-9]+$ ]] && kill -0 "$worker_pid" 2>/dev/null; then
        echo "A media queue worker (pid $worker_pid) is active; yt-dlp update deferred."
        exit 1
    fi
fi

# Keep update metadata outside the repository and shared media storage.
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}"
CACHE_DIR="$CACHE_ROOT/media-pipeline"
STAMP="$CACHE_DIR/yt-dlp-${CHANNEL}.last-check"
LOCK="$CACHE_DIR/yt-dlp-update.lock"
mkdir -p "$CACHE_DIR" 2>/dev/null || { CACHE_DIR="${TMPDIR:-/tmp}/media-pipeline-${UID:-0}"; mkdir -p "$CACHE_DIR" || exit 1; STAMP="$CACHE_DIR/yt-dlp-${CHANNEL}.last-check"; LOCK="$CACHE_DIR/yt-dlp-update.lock"; }

now=$(date +%s)
if [[ "$FORCE" != "1" && -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now >= last && now - last < INTERVAL )); then
        echo "yt-dlp $CHANNEL update check skipped (checked $((now-last))s ago; interval ${INTERVAL}s)."
        exit 0
    fi
fi

if ! mkdir "$LOCK" 2>/dev/null; then
    echo "yt-dlp updater is already running; skipping duplicate update."
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM HUP

PY=""
for candidate in "${PYTHON:-}" python python3; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
if [[ -z "$PY" ]]; then
    echo "No usable Python interpreter found; cannot install yt-dlp channel '$CHANNEL'." >&2
    exit 1
fi

old_version=$(yt-dlp --version 2>/dev/null || echo "not installed")
echo "Updating yt-dlp channel='$CHANNEL' (current: $old_version)"

# Official frozen binaries support their own channel updater. Python/pip installs
# are updated through the corresponding upstream PyPI/source distribution.
BIN="$(command -v yt-dlp 2>/dev/null || true)"
IS_SCRIPT=0
if [[ -n "$BIN" && -f "$BIN" ]]; then
    magic=$(head -c 2 "$BIN" 2>/dev/null || true)
    [[ "$magic" == '#!' ]] && IS_SCRIPT=1
fi

update_rc=0
if [[ -n "$BIN" && "$IS_SCRIPT" == "0" ]]; then
    yt-dlp --update-to "$CHANNEL" || update_rc=$?
    if (( update_rc != 0 )); then
        echo "Binary self-update failed; attempting the Python installation path."
    fi
fi

if [[ -z "$BIN" || "$IS_SCRIPT" == "1" || $update_rc -ne 0 ]]; then
    case "$CHANNEL" in
        master)
            # Upstream's bleeding-edge/canary source build (avoid recompiling C deps).
            "$PY" -c 'import hatchling, wheel' 2>/dev/null || "$PY" -m pip install hatchling wheel || exit $?
            "$PY" -m pip install --no-cache-dir --force-reinstall --no-deps \
                'https://github.com/yt-dlp/yt-dlp/archive/refs/heads/master.tar.gz' || exit $?
            "$PY" -m pip install --upgrade-strategy only-if-needed \
                'yt-dlp[default] @ https://github.com/yt-dlp/yt-dlp/archive/refs/heads/master.tar.gz' || exit $?
            ;;
        nightly)
            "$PY" -m pip install --upgrade --pre 'yt-dlp[default]' || exit $?
            ;;
        stable)
            "$PY" -m pip install --upgrade 'yt-dlp[default]' || exit $?
            ;;
    esac
fi

new_version=$(yt-dlp --version 2>/dev/null || true)
if [[ -z "$new_version" ]]; then
    echo "yt-dlp update command returned, but 'yt-dlp --version' failed." >&2
    exit 1
fi
printf '%s\n' "$now" > "$STAMP.tmp" && mv -f "$STAMP.tmp" "$STAMP"
echo "yt-dlp update complete: $old_version -> $new_version (channel: $CHANNEL)"
