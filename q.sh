#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        q.sh   (installed as the `q` command)
#  @brief       Front end for the persistent job queue.
#  @version     1.0.0
# ═══════════════════════════════════════════════════════════════════════════════
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}"; export QUEUE_DIR
PY="${PYTHON:-python3}"
LOG="$SCRIPT_DIR/media_processor_log.txt"
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then SD="${MEDIA_DIR:-/storage/emulated/0}"; else SD="${MEDIA_DIR:-$HOME/TermuxMedia}"; fi
qctl() { "$PY" "$SCRIPT_DIR/qctl.py" "$@"; }

usage() { cat <<'U'
q add [--consume] <url|file>...  queue links or local video files, process in background
q dl [--wait] <url> [yt-dlp opts] queue a link; background by default (--wait blocks)
q scan                  queue videos found in the TikTok / yt-dlp folders
q fennec [N]            list recent media links from Fennec history (default 15)
q fennec add [IDX|all]  queue listed Fennec links (e.g. 1, 1 3, all; default 1)
q run                   run the worker now (foreground)
q bg                    start the worker in the background
q update [--force]      update yt-dlp to the configured channel
q stop                  stop after the current job
q list [status]         pending | running | done | failed
q stats                 counts + worker state
q retry [ID|all]        retry failed jobs
q remove ID             delete a job (not a running one)
q clear [done|failed|all]
q logs [N]              last N log lines (default 30)
q ui [start|stop|status|open]  web page for queue, status, logs and settings
q selftest              check that the queue works on this storage (safe, cleans up)
q percent [0-100]       show / set the audio peak target (0 = -9.0 dB ... 100 = -0.1 dB)
U
}

worker_running() { local p; p=$(cat "$QUEUE_DIR/.worker.lock/pid" 2>/dev/null); [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }
start_bg() {
    worker_running && return 0
    mkdir -p "$QUEUE_DIR"
    if [[ -f "$QUEUE_DIR/worker.out" ]] && (( $(stat -c %s "$QUEUE_DIR/worker.out" 2>/dev/null || echo 0) > 262144 )); then : > "$QUEUE_DIR/worker.out"; fi
    nohup bash "$SCRIPT_DIR/worker.sh" >> "$QUEUE_DIR/worker.out" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo "worker started in background"
}

FILE_EXTRA=()   # extra qctl options for FILE items (set by: q add --consume ...)
# add_one ITEM -> prints a line, sets ADD_RC (0 queued, 3 duplicate, 2 bad)
add_one() {
    local it="$1" u f
    ADD_RC=0
    if [[ "$it" =~ ^https?://[^[:space:]]+$ ]]; then
        qctl add --url "$it" "${@:2}"; ADD_RC=$?; return
    fi
    if [[ -e "$it" || "$it" == /* ]]; then
        f="$it"
        [[ "$f" == /* ]] || f="$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")"
        qctl add --file "$f" "${FILE_EXTRA[@]}"; ADD_RC=$?; return
    fi
    u=$(printf '%s' "$it" | grep -oE 'https?://[^[:space:]]+' | head -1)   # link inside shared text
    if [[ -n "$u" ]]; then qctl add --url "$u" "${@:2}"; ADD_RC=$?; return; fi
    echo "not a link or file: $it" >&2; ADD_RC=2
}

scan_folders() {
    local dir f age queued=0 dup=0 out
    for dir in "$SD/DCIM/TikTok" "$SD/Pictures/TikTok" "$SD/Download/yt-dlp"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f <&3; do
            age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
            (( age >= 0 && age < 5 )) && sleep $(( 5 - age ))      # still being written
            out=$(qctl add --file "$f" --consume 2>&1); case $? in
                0) (( ++queued )) ;;
                3) (( ++dup )) ;;
                *) echo "[!] Could not queue files: $out" >&2; echo "    Nothing was changed or deleted. Run: q selftest" >&2; return 1 ;;   # stop: same error for every file
            esac
        done 3< <(find "$dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' \
                   -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.3gp' -o -iname '*.ts' -o -iname '*.flv' -o -iname '*.m4v' \) \
                   ! -regex '.*\.f[0-9]+\.[A-Za-z0-9]+$' -print0 2>/dev/null)
    done
    echo "folder scan: queued=$queued already_queued=$dup"
}

ui_pidfile() { echo "$(dirname "$QUEUE_DIR")/webui.pid"; }
ui_running() {
    local p; p=$(cat "$(ui_pidfile)" 2>/dev/null)
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && { [[ ! -r "/proc/$p/cmdline" ]] || tr '\0' ' ' < "/proc/$p/cmdline" | grep -q webui.py; }
}
ui_url() { echo "http://${WEBUI_URL_HOST:-127.0.0.1}:${WEBUI_PORT:-8787}"; }
ui_cmd() {
    local sub="${1:-start}" pidf out p i
    pidf="$(ui_pidfile)"; out="$(dirname "$QUEUE_DIR")/webui.out"
    case "$sub" in
        start|open)
            if ui_running; then echo "Web UI already running: $(ui_url)"
            else
                mkdir -p "$(dirname "$QUEUE_DIR")"
                [[ -f "$out" ]] && (( $(stat -c %s "$out" 2>/dev/null || echo 0) > 65536 )) && : > "$out"
                nohup "$PY" "$SCRIPT_DIR/webui.py" >> "$out" 2>&1 < /dev/null &
                echo $! > "$pidf"; disown 2>/dev/null || true
                for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.3; ui_running && (echo > "/dev/tcp/127.0.0.1/${WEBUI_PORT:-8787}") 2>/dev/null && break; done
                if ui_running; then echo "Web UI started: $(ui_url)"; else echo "Web UI failed to start. Last lines:" >&2; tail -n 5 "$out" >&2; return 1; fi
            fi
            [[ "$sub" == "open" ]] && command -v termux-open-url &>/dev/null && termux-open-url "$(ui_url)" ;;
        stop)   if ui_running; then kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"; echo "Web UI stopped"; else echo "Web UI is not running"; fi ;;
        status) ui_running && echo "Web UI running: $(ui_url)" || echo "Web UI not running" ;;
        *) usage >&2; return 2 ;;
    esac
}

fennec_fetch() {
    local limit="${1:-15}" py_bin
    py_bin="$(command -v "$PY" 2>/dev/null || echo "/data/data/com.termux/files/usr/bin/python3")"
    su -mm -c "'$py_bin' - '$limit'" <<'PYEOF'
import glob, os, re, sqlite3, sys
from urllib.parse import urlparse

limit = int(sys.argv[1])
bases = glob.glob("/data/data/*fennec*")
if not bases:
    sys.exit("Fennec data directory not found")

places = []
for root, _, files in os.walk(bases[0]):
    if "places.sqlite" in files:
        places.append(os.path.join(root, "places.sqlite"))
if not places:
    sys.exit("Fennec places.sqlite not found")

src = sqlite3.connect(f"file:{places[0]}?mode=ro", uri=True)
mem = sqlite3.connect(":memory:")
src.backup(mem)
src.close()

tables = {r[0] for r in mem.execute("SELECT name FROM sqlite_master WHERE type='table'")}
if "moz_historyvisits" in tables:
    rows = mem.execute("""
        SELECT p.url, p.title
        FROM moz_places p
        JOIN moz_historyvisits v ON v.place_id = p.id
        ORDER BY v.visit_date DESC
        LIMIT 500
    """).fetchall()
else:
    rows = mem.execute("SELECT url, title FROM moz_places ORDER BY id DESC LIMIT 500").fetchall()

dom_re = re.compile(r"^(www\.|m\.|vm\.|vt\.|mobile\.)?(tiktok\.com|facebook\.com|fb\.watch|instagram\.com|x\.com|twitter\.com|youtu\.be|youtube\.com)$", re.I)
noise_re = re.compile(r"^/(login|logout|signup|reg|recover|checkpoint|onboarding|accounts/login|i/flow|i/jf|save-device|privacy|policies|help|settings|notifications|messages|explore|search|home|profile|photo\.php)(/|$)", re.I)

seen = set()
for u, title in rows:
    try:
        pu = urlparse(u)
    except Exception:
        continue
    if pu.scheme not in ("http", "https") or not dom_re.match(pu.netloc):
        continue
    path = pu.path or "/"
    if path == "/" and not pu.query:
        continue
    if noise_re.match(path):
        continue
    if path.rstrip("/") in ("/watch", "/reel", "/reels", "/shorts") and not pu.query:
        continue
    if u in seen:
        continue
    seen.add(u)
    t = (title or "").replace("\t", " ").replace("\n", " ").strip()[:55]
    print(f"{u}\t{t}")
    if len(seen) >= limit:
        break
PYEOF
}

fennec_cmd() {
    local sub="${1:-list}"
    if [[ "$sub" =~ ^[0-9]+$ ]]; then
        sub="list"
    else
        [[ $# -gt 0 ]] && shift
    fi

    case "$sub" in
        list)
            local limit="${1:-15}" i=0 u t
            while IFS=$'\t' read -r u t; do
                [[ -z "$u" ]] && continue
                (( ++i ))
                if [[ -n "$t" ]]; then
                    printf "%2d. %s  # %s\n" "$i" "$u" "$t"
                else
                    printf "%2d. %s\n" "$i" "$u"
                fi
            done < <(fennec_fetch "$limit")
            (( i == 0 )) && echo "No recent media URLs found in Fennec history."
            ;;
        add)
            local -a urls=() titles=() picks=()
            local u t tok
            while IFS=$'\t' read -r u t; do
                [[ -z "$u" ]] && continue
                urls+=("$u")
                titles+=("$t")
            done < <(fennec_fetch 30)

            if (( ${#urls[@]} == 0 )); then
                echo "No recent media URLs found in Fennec history." >&2
                return 1
            fi

            if (( $# == 0 )); then
                picks=(1)
            else
                for tok in "$@"; do
                    if [[ "$tok" == "all" ]]; then
                        local idx
                        for (( idx=1; idx<=${#urls[@]}; idx++ )); do picks+=("$idx"); done
                    else
                        local part
                        for part in ${tok//,/ }; do
                            [[ "$part" =~ ^[0-9]+$ ]] && picks+=("$part")
                        done
                    fi
                done
            fi

            [[ -x "$SCRIPT_DIR/sync_cookies.sh" ]] && bash "$SCRIPT_DIR/sync_cookies.sh" >/dev/null 2>&1 || true

            local p_idx queued=0
            for p_idx in "${picks[@]}"; do
                if (( p_idx < 1 || p_idx > ${#urls[@]} )); then
                    echo "index out of range (1..${#urls[@]}): $p_idx" >&2
                    continue
                fi
                add_one "${urls[$((p_idx-1))]}"
                [[ $ADD_RC -eq 0 ]] && (( ++queued ))
            done
            (( queued > 0 )) && [[ "${Q_NO_BG:-}" != "1" ]] && start_bg
            ;;
        *)
            echo "Usage: q fennec [N] | q fennec add [1 3|1,3|all]" >&2
            return 2
            ;;
    esac
}

cmd="${1:-help}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
    add)
        [[ "${1:-}" == "--consume" ]] && { FILE_EXTRA=(--consume); shift; }   # delete files after a verified result
        [[ $# -ge 1 ]] || { usage >&2; exit 2; }
        bad=0; for it in "$@"; do add_one "$it"; [[ $ADD_RC == 2 ]] && bad=1; done
        [[ "${Q_NO_BG:-}" == "1" ]] || start_bg
        exit $bad ;;
    dl)
        wait_mode=0
        if [[ "${1:-}" == "--wait" ]]; then wait_mode=1; shift; fi
        [[ $# -ge 1 ]] || { echo "Usage: dl [--wait] <URL> [extra yt-dlp options...]" >&2; exit 1; }
        url="$1"; shift; extra=(); for o in "$@"; do extra+=("--arg=$o"); done
        add_one "$url" "${extra[@]}"; [[ $ADD_RC == 2 ]] && exit 2
        if (( wait_mode )); then
            exec bash "$SCRIPT_DIR/worker.sh"
        fi
        start_bg
        if (( ADD_RC == 3 )); then
            echo "Duplicate detected; no new download was queued. Check 'q list' for the existing job."
        else
            echo "Download queued. Processing continues in the background; use 'q list' or 'q ui open' to monitor."
        fi
        ;;
    update)
        case "${1:-}" in
            "") ;;
            --force) export YT_DLP_FORCE_UPDATE=1 ;;
            *) echo "Usage: q update [--force]" >&2; exit 2 ;;
        esac
        bash "$SCRIPT_DIR/update_yt_dlp.sh" ;;
    scan)  scan_folders ;;
    fennec) fennec_cmd "$@" ;;
    run)   exec bash "$SCRIPT_DIR/worker.sh" ;;
    bg)    start_bg ;;
    stop)  if worker_running; then mkdir -p "$QUEUE_DIR"; : > "$QUEUE_DIR/.stop"; echo "stop requested (after the current job)"; else echo "no worker running"; fi ;;
    list)  qctl list ${1:+--status "$1"} ;;
    stats|status) echo "$(qctl stats)  worker=$(worker_running && echo running || echo idle)" ;;
    retry) if [[ "${1:-all}" == "all" ]]; then qctl retry --all; else qctl retry "$1"; fi; [[ $? == 0 ]] && { [[ "${Q_NO_BG:-}" == "1" ]] || start_bg; } ;;
    remove) [[ $# -ge 1 ]] || { usage >&2; exit 2; }; qctl remove "$1" ;;
    clear) case "${1:-done}" in all) qctl clear done failed ;; done|failed) qctl clear "$1" ;; *) usage >&2; exit 2 ;; esac ;;
    logs)  tail -n "${1:-30}" "$LOG" 2>/dev/null ;;
    ui)    ui_cmd "$@" ;;
    selftest) qctl selftest ;;
    percent)
        "$PY" - "$SCRIPT_DIR" "${1:-}" <<'PYEOF'
import os, sys
sys.path.insert(0, sys.argv[1]); os.environ.setdefault("QUEUE_DIR", os.path.join(sys.argv[1], "data", "queue"))
import webui
cur = webui.read_config().get("PEAK_PERCENT", webui.SCHEMA["PEAK_PERCENT"][0])
def show(v): print("PEAK_PERCENT = %s%%  ->  target peak %.3f dB   (0%% = -9.0 dB, 50%% = -4.55 dB, 100%% = -0.1 dB)" % (v, -9 + 8.9 * float(v) / 100))
if not sys.argv[2]:
    show(cur)
else:
    try: v = webui.validate("PEAK_PERCENT", sys.argv[2])
    except ValueError as e: print("Not changed: %s" % e, file=sys.stderr); sys.exit(2)
    c = webui.read_config()
    if v == webui.SCHEMA["PEAK_PERCENT"][0]: c.pop("PEAK_PERCENT", None)
    else: c["PEAK_PERCENT"] = v
    webui.write_config(c); print("Saved. Applies from the next file."); show(v)
PYEOF
        ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
