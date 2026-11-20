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
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
    esac
done

case "$CHANNEL" in
    master|nightly|stable) ;;
    *) echo "Invalid YT_DLP_CHANNEL='$CHANNEL' (use master, nightly, or stable)." >&2; exit 2 ;;
esac
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
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    CACHE_DIR="${TMPDIR:-/tmp}/media-pipeline-${UID:-0}"
    mkdir -p "$CACHE_DIR" || exit 1
fi
STAMP="$CACHE_DIR/yt-dlp-${CHANNEL}.last-check"
LOCK="$CACHE_DIR/yt-dlp-update.lock"

update_ffmpeg_bvc2() {
    [[ "$(uname -m)" == "aarch64" && -d "/data/data/com.termux" ]] || return 0
    local bstamp="$CACHE_DIR/ffmpeg-bvc2.last-check" bdir="$HOME/.local/ffmpeg-bvc2" bnow blast api info rid url cur tmpd
    bnow=$(date +%s)
    if [[ "$FORCE" != "1" && -f "$bstamp" && -x "$bdir/bin/ffmpeg" ]]; then
        blast=$(cat "$bstamp" 2>/dev/null || echo 0)
        [[ "$blast" =~ ^[0-9]+$ ]] && (( bnow >= blast && bnow - blast < INTERVAL )) && return 0
    fi
    api="https://api.github.com/repos/AnnaMorgrett/ffmpeg-bvc2/releases/tags/latest-arm64"
    info=$(curl -fsSL --max-time 15 "$api" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); a=[x["browser_download_url"] for x in d.get("assets",[]) if x["name"].endswith(".tar.xz")]; print(d.get("published_at","")+"|"+d.get("body","").strip()); print(a[0] if a else "")' 2>/dev/null) || return 0
    rid=$(printf '%s\n' "$info" | sed -n '1p')
    url=$(printf '%s\n' "$info" | sed -n '2p')
    [[ -n "$rid" && -n "$url" ]] || return 0
    printf '%s\n' "$bnow" > "$bstamp.tmp" && mv -f "$bstamp.tmp" "$bstamp"
    cur=$(cat "$bdir/.release-id" 2>/dev/null || true)
    [[ "$cur" == "$rid" && -x "$bdir/bin/ffmpeg" ]] && return 0
    echo "Updating ffmpeg-bvc2 ($rid)..."
    tmpd="${bdir}.new.$$"
    rm -rf "$tmpd" && mkdir -p "$tmpd"
    if curl -fsSL --max-time 120 "$url" | tar -xJ -C "$tmpd" && chmod +x "$tmpd/bin/"* && "$tmpd/bin/ffmpeg" -hide_banner -decoders 2>/dev/null | grep -q bvc2; then
        printf '%s\n' "$rid" > "$tmpd/.release-id"
        rm -rf "$bdir" && mv "$tmpd" "$bdir"
        echo "ffmpeg-bvc2 updated ($rid)."
    else
        rm -rf "$tmpd"
    fi
}

now=$(date +%s)
if [[ "$FORCE" != "1" && -f "$STAMP" ]]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now >= last && now - last < INTERVAL )); then
        echo "yt-dlp $CHANNEL update check skipped (checked $((now - last))s ago; interval ${INTERVAL}s)."
        update_ffmpeg_bvc2
        exit 0
    fi
fi

acquire_update_lock() {
    local owner
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK/pid"
        return 0
    fi
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
        return 1
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null && printf '%s\n' "$$" > "$LOCK/pid"
}
release_update_lock() {
    [[ "$(cat "$LOCK/pid" 2>/dev/null || true)" == "$$" ]] && rm -rf "$LOCK"
    return 0
}

if ! acquire_update_lock; then
    echo "yt-dlp updater is already running; skipping duplicate update."
    exit 0
fi
trap release_update_lock EXIT INT TERM HUP

PY=""
for candidate in "${PYTHON:-}" python python3; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
        PY="$candidate"
        break
    fi
done
if [[ -z "$PY" ]]; then
    echo "No usable Python interpreter found; cannot install yt-dlp channel '$CHANNEL'." >&2
    exit 1
fi

get_ytdlp_version() {
    yt-dlp --version 2>/dev/null || "$PY" -m yt_dlp --version 2>/dev/null || true
}

old_version=$(get_ytdlp_version)
[[ -z "$old_version" ]] && old_version="not installed"
echo "Updating yt-dlp channel='$CHANNEL' (current: $old_version)"

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
    MASTER_URL='https://github.com/yt-dlp/yt-dlp/archive/refs/heads/master.tar.gz'
    case "$CHANNEL" in
        master)
            "$PY" -c 'import hatchling, wheel' 2>/dev/null || "$PY" -m pip install hatchling wheel || exit $?
            if [[ "$old_version" == "not installed" ]]; then
                "$PY" -m pip install --no-cache-dir --upgrade --upgrade-strategy only-if-needed \
                    "yt-dlp[default] @ $MASTER_URL" || exit $?
            else
                "$PY" -m pip install --no-cache-dir --force-reinstall --no-deps "$MASTER_URL" || exit $?
            fi
            ;;
        nightly)
            "$PY" -m pip install --upgrade --upgrade-strategy only-if-needed --pre 'yt-dlp[default]' || exit $?
            ;;
        stable)
            "$PY" -m pip install --upgrade --upgrade-strategy only-if-needed 'yt-dlp[default]' || exit $?
            ;;
    esac
fi

new_version=$(get_ytdlp_version)
if [[ -z "$new_version" ]]; then
    echo "yt-dlp update command returned, but yt-dlp version check failed." >&2
    exit 1
fi
printf '%s\n' "$now" > "$STAMP.tmp" && mv -f "$STAMP.tmp" "$STAMP"
echo "yt-dlp update complete: $old_version -> $new_version (channel: $CHANNEL)"
update_ffmpeg_bvc2
