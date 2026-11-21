#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        worker.sh
#  @brief       Background queue worker: runs queued jobs in FIFO order, WORKERS at a time (default 2).
#  @version     1.2.0
#
#  Job types:  url  -> download.sh (yt-dlp) then normalize.sh --file for each result
#              file -> normalize.sh --file (original kept for shared local files)
#  Safe to start any number of times: only one worker runs; the others exit.
#  If killed or the phone restarts, unfinished jobs resume on the next start.
#
#  Usage: worker.sh [-h]     (drains the queue, then exits)
#  Stop:  touch "$QUEUE_DIR/.stop"   (finishes the current job, then stops)
# ═══════════════════════════════════════════════════════════════════════════════
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_DIR="${QUEUE_DIR:-$SCRIPT_DIR/data/queue}"; export QUEUE_DIR
PY="${PYTHON:-python3}"
LOG="$SCRIPT_DIR/media_processor_log.txt"
LOG_MAX="${LOG_MAX_BYTES:-$(( 2 * 1024 * 1024 ))}"
LOCK="$QUEUE_DIR/.worker.lock"
SCAN_OWN=1; [[ -n "${MEDIA_SCAN_QUEUE:-}" ]] && SCAN_OWN=0
SCANQ="${MEDIA_SCAN_QUEUE:-$QUEUE_DIR/.scan.pending}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi

if [[ -t 1 ]]; then C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
else C_GREEN='' C_YELLOW='' C_RED='' C_BLUE='' C_RESET=''; fi

log() { printf '[%s] [WORKER] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
qctl() { "$PY" "$SCRIPT_DIR/qctl.py" "$@"; }
qctl_retry() {
    local attempt=1
    while (( attempt <= 5 )); do
        qctl "$@" >/dev/null 2>&1 && return 0
        sleep 0.2
        (( ++attempt ))
    done
    log "ERROR: qctl $* failed after retries"
    return 1
}
trim_log() {
    local sz; sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    (( sz > LOG_MAX )) && tail -c $(( LOG_MAX / 2 )) "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
    return 0
}
# shellcheck source=scan_lib.sh
source "$SCRIPT_DIR/scan_lib.sh"
# shellcheck source=config_lib.sh
if [[ -f "$SCRIPT_DIR/config_lib.sh" ]]; then source "$SCRIPT_DIR/config_lib.sh"; load_config "${PIPELINE_CONFIG:-$SCRIPT_DIR/data/config.conf}"; fi
WORKERS="${WORKERS:-2}"; [[ "$WORKERS" =~ ^[1-4]$ ]] || WORKERS=2
JOB_TIMEOUT="${JOB_TIMEOUT:-600}"; [[ "$JOB_TIMEOUT" =~ ^[0-9]+$ ]] && (( JOB_TIMEOUT >= 30 )) || JOB_TIMEOUT=600

for bin in "$PY" ffmpeg ffprobe awk; do
    command -v "$bin" &>/dev/null || { printf "${C_RED}[FATAL] '%s' not found in PATH${C_RESET}\n" "$bin" >&2; exit 1; }
done
mkdir -p "$QUEUE_DIR" 2>/dev/null
if [[ ! -d "$QUEUE_DIR" || ! -w "$QUEUE_DIR" ]]; then
    printf "${C_RED}[ERROR] Queue folder is not usable: %s (check with: q selftest)${C_RESET}\n" "$QUEUE_DIR" >&2
    exit 1
fi
: >> "$LOG"

# ── Single worker: atomic mkdir lock with PID; a dead owner's lock is taken over ──
acquire_lock() {
    local owner state cmd
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        state=$(awk '/^State:/{print $2}' "/proc/$owner/status" 2>/dev/null || true)
        cmd=$(tr '\0' ' ' < "/proc/$owner/cmdline" 2>/dev/null || true)
        if [[ "$state" != "Z" ]] && { [[ -z "$cmd" ]] || [[ "$cmd" == *worker.sh* ]]; }; then
            return 1
        fi
    fi
    log "Stale worker lock (pid ${owner:-?}) removed"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null && echo $$ > "$LOCK/pid"
}
release_lock() { [[ "$(cat "$LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$LOCK"; return 0; }

if ! acquire_lock; then
    printf "${C_YELLOW}[!] A worker is already running. Jobs will be processed by it.${C_RESET}\n"
    exit 0
fi

CHILD=""; WAKE=0; declare -A SLOT=()
wake_on()  { command -v termux-wake-lock &>/dev/null && termux-wake-lock 2>/dev/null && WAKE=1; return 0; }
wake_off() { (( WAKE )) && termux-wake-unlock 2>/dev/null; WAKE=0; return 0; }
kill_tree() {
    local pid="$1" sig="${2:-TERM}" c
    for c in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$c" "$sig"; done
    kill "-$sig" "$pid" 2>/dev/null || true
}
kill_tree_force() {
    local pid="$1"
    kill_tree "$pid" TERM
    sleep 0.3
    kill_tree "$pid" KILL
}
on_signal() {
    local p
    for p in "${!SLOT[@]}"; do
        kill_tree_force "$p"
        wait "$p" 2>/dev/null || true
        qctl_retry requeue "${SLOT[$p]}"
        log "Interrupted; job ${SLOT[$p]} put back in the queue"
    done
    (( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
    rm -f "$QUEUE_DIR"/.out.* "$QUEUE_DIR"/.dl.* "$QUEUE_DIR/.cnt.$$" "$QUEUE_DIR/.cnt.$$.qctl.err" 2>/dev/null
    wake_off; release_lock; exit 143
}
trap on_signal INT TERM HUP
trap "wake_off; release_lock" EXIT

run_child() { "$@" & CHILD=$!; wait "$CHILD"; local rc=$?; CHILD=""; return "$rc"; }

normalize_one() {   # normalize_one PATH KEEP(0/1)
    local f="$1" keep="$2" rf rc; local -a extra=()
    rf=$(mktemp "$QUEUE_DIR/.res.XXXXXX")
    [[ "$keep" == "1" ]] && extra=(--keep-original)
    NORMALIZE_RESULT_FILE="$rf" MEDIA_SCAN_QUEUE="$SCANQ" run_child bash "$SCRIPT_DIR/normalize.sh" --file "$f" "${extra[@]}"
    rc=$?
    JOB_OUT=$(sed -n 's/^OUTPUT=//p' "$rf" | head -1)
    rm -f "$rf"
    return "$rc"
}
explain() {
    case "$1" in
        64) echo "invalid setting (check Settings / config.conf)" ;;
        1)  echo "processing failed (source kept)" ;;
        2)  echo "no video stream" ;;
        3)  echo "unsupported video (ByteVC2, no H.264 copy)" ;;
        *)  echo "exit code $1" ;;
    esac
}

process_job() {   # process_job ID TYPE KEEP VALUE ARGS -> 0 = done, 1 = failed (message in JOB_ERR)
    local id="$1" type="$2" keep="$3" value="$4" rawargs="${5:-}" rc p outs="" errs="" n=0
    local -a paths=() dlargs=()
    [[ -n "$rawargs" ]] && IFS=$'\x1f' read -r -a dlargs <<< "$rawargs"
    JOB_OUT=""; JOB_ERR=""
    if [[ "$type" == "file" ]]; then
        [[ -f "$value" ]] || { JOB_ERR="file not found: $value"; return 1; }
        normalize_one "$value" "$keep"; rc=$?
        (( rc == 0 )) && return 0
        JOB_ERR="$(explain "$rc")"; return 1
    fi
    # url (with up to 2 automatic retries on transient errors)
    local resf dl_log dl_err attempt=1
    while :; do
        resf=$(mktemp "$QUEUE_DIR/.res.XXXXXX")
        dl_log=$(mktemp "$QUEUE_DIR/.dl.XXXXXX")
        DL_RESULT_FILE="$resf" run_child bash "$SCRIPT_DIR/download.sh" "$value" "${dlargs[@]}" >"$dl_log" 2>&1; rc=$?
        if [[ -s "$dl_log" ]]; then
            cat "$dl_log"
            sed "s/^/[$(date '+%F %T')] [DOWNLOAD] /" "$dl_log" >> "$LOG"
        fi
        if (( rc == 0 )); then
            rm -f "$dl_log"
            break
        fi
        dl_err=$(grep -E '^ERROR:' "$dl_log" | tail -n 1 | sed 's/^ERROR:[[:space:]]*//')
        [[ -z "$dl_err" ]] && dl_err=$(grep -E '^\[.*\] error:' "$dl_log" | tail -n 1)
        rm -f "$resf" "$dl_log"
        JOB_ERR="${dl_err:-download failed (exit $rc)}"
        if (( attempt < 3 )) && [[ ! -f "$QUEUE_DIR/.stop" ]] && [[ "$JOB_ERR" =~ (HTTP\ Error\ (429|502|503|504)|Too\ Many\ Requests|Connection\ (reset|aborted)|timed\ out|Temporary\ failure|Name\ or\ service\ not\ known|RemoteDisconnected|TLS|SSL|Solving\ JS\ challenge) ]]; then
            log "Job $id transient failure (attempt $attempt/3): $JOB_ERR — retrying in $((attempt * 5))s"
            sleep $((attempt * 5))
            (( ++attempt ))
            continue
        fi
        return 1
    done
    while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < "$resf"
    rm -f "$resf"
    (( ${#paths[@]} > 0 )) || { JOB_ERR="download reported no file"; return 1; }
    for p in "${paths[@]}"; do
        [[ -f "$p" ]] || { errs+="missing: $(basename "$p"); "; continue; }
        if [[ "${p,,}" =~ \.(jpg|jpeg|png|webp|gif|bmp|avif|heic)$ ]]; then
            printf '%s\n' "$p" >> "$SCANQ"
            outs+="${p};"
            (( ++n ))
        else
            normalize_one "$p" 0; rc=$?
            if (( rc == 0 )); then outs+="${JOB_OUT};"; (( ++n )); else errs+="$(basename "$p"): $(explain "$rc"); "; fi
        fi
    done
    JOB_OUT="$outs"
    [[ -z "$errs" ]] && return 0
    JOB_ERR="${errs%; }"; return 1
}

# ── Main loop ─────────────────────────────────────────────────────────────────
trim_log
log "════════ Worker start (pid $$) ════════"
wake_on
rec=$(qctl recover 2>&1); rrc=$?
log "Recovery: $rec"
if (( rrc != 0 )); then
    printf "${C_RED}[ERROR] Queue unavailable: %s${C_RESET}\n" "$rec" >&2
    log "ERROR: queue unavailable at start: $rec"
    wake_off; exit 1
fi
(( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
rm -f "$QUEUE_DIR/.stop" "$QUEUE_DIR"/.res.* 2>/dev/null

QUEUE_ERR=0; CNT="$QUEUE_DIR/.cnt.$$"; : > "$CNT"

slot_body() {   # slot_body ID TYPE KEEP VALUE ARGS
    local id="$1"
    printf "${C_BLUE}[job %s]${C_RESET} %s %s\n" "$id" "$2" "$4"
    log "Job $id start: $2 $4"
    if process_job "$1" "$2" "$3" "$4" "${5:-}"; then
        kill -0 "$$" 2>/dev/null || exit 143
        qctl_retry done "$id" --output "$JOB_OUT"
        echo ok >> "$CNT"; log "Job $id DONE"
        printf "${C_GREEN}[job %s] done${C_RESET}\n" "$id"
    else
        kill -0 "$$" 2>/dev/null || exit 143
        qctl_retry fail "$id" "$JOB_ERR"
        echo fail >> "$CNT"; log "Job $id FAILED: $JOB_ERR"
        printf "${C_RED}[job %s] failed: $JOB_ERR${C_RESET}\n" "$id"
    fi
}
start_slot() {  # start_slot ID TYPE KEEP VALUE ARGS
    local jid="$1" outf="$QUEUE_DIR/.out.$1" tmo_f="$QUEUE_DIR/.timeout.$1"
    rm -f "$tmo_f"
    (
        local_me=$BASHPID; WATCH=""; TIMER=""
        on_slot_term() {
            [[ -n "$TIMER" ]] && kill "$TIMER" 2>/dev/null || true
            [[ -n "$WATCH" ]] && kill "$WATCH" 2>/dev/null || true
            [[ -n "$CHILD" ]] && kill_tree_force "$CHILD"
            wait 2>/dev/null || true
            if [[ -f "$tmo_f" ]]; then
                rm -f "$tmo_f" "$outf"
                qctl_retry fail "$jid" "job timed out after ${JOB_TIMEOUT}s"
                echo fail >> "$CNT"
                log "Job $jid FAILED: timed out after ${JOB_TIMEOUT}s"
                printf "${C_RED}[job %s] failed: timed out after %ss${C_RESET}\n" "$jid" "$JOB_TIMEOUT"
                exit 124
            fi
            exit 143
        }
        trap on_slot_term INT TERM HUP
        trap - EXIT
        ( while kill -0 "$$" 2>/dev/null; do sleep 2; done; kill -TERM "$local_me" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        WATCH=$!
        (
            sleep "$JOB_TIMEOUT"
            : > "$tmo_f" 2>/dev/null || true
            kill -TERM "$local_me" 2>/dev/null || true
            sleep 3
            kill -KILL "$local_me" 2>/dev/null || true
        ) </dev/null >/dev/null 2>&1 &
        TIMER=$!
        if (( WORKERS > 1 )); then
            slot_body "$@" > "$outf" 2>&1; cat "$outf"; rm -f "$outf"
        else
            slot_body "$@"
        fi
        kill "$TIMER" "$WATCH" 2>/dev/null || true
        rm -f "$tmo_f"
    ) &
    SLOT[$!]="$1"
}
refresh_slots() {
    local alive p
    alive=" $(jobs -rp | tr '\n' ' ') "
    for p in "${!SLOT[@]}"; do
        [[ "$alive" == *" $p "* ]] || unset "SLOT[$p]"
    done
}

ok=0; failed=0; stopped=0
while :; do
    drained=0
    while :; do
        if (( ! stopped )) && [[ -f "$QUEUE_DIR/.stop" ]]; then
            rm -f "$QUEUE_DIR/.stop"; log "Stop requested"; printf "${C_YELLOW}[!] Stopping: finishing the running job(s).${C_RESET}\n"; stopped=1
        fi
        if (( ! stopped && ! drained && ${#SLOT[@]} < WORKERS )); then
            qerr_f="${CNT}.qctl.err"
            line=$(qctl next --max "$WORKERS" 2>"$qerr_f"); nrc=$?
            if (( nrc == 1 )); then
                drained=1
            elif (( nrc != 0 )); then
                qerr=$(cat "$qerr_f" 2>/dev/null || true)
                printf "${C_RED}[ERROR] Queue problem: %s %s${C_RESET}\n" "$line" "$qerr" >&2
                log "ERROR: queue problem: $line $qerr"
                QUEUE_ERR=1; drained=1
            else
                id="${line%%$'\t'*}"; rest="${line#*$'\t'}"
                type="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
                keep="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
                value="${rest%%$'\t'*}"
                if [[ "$rest" == *$'\t'* ]]; then jargs="${rest#*$'\t'}"; else jargs=""; fi
                start_slot "$id" "$type" "$keep" "$value" "$jargs"
                continue
            fi
        fi
        (( ${#SLOT[@]} == 0 )) && break
        refresh_slots
        if (( ${#SLOT[@]} >= WORKERS || drained || stopped )); then
            wait -n 2>/dev/null || true
            refresh_slots
            drained=0
        fi
    done

    (( SCAN_OWN )) && { scan_queue "$SCANQ"; rm -f "$SCANQ"; }
    o=$(grep -c '^ok' "$CNT" 2>/dev/null || true); f=$(grep -c '^fail' "$CNT" 2>/dev/null || true); : > "$CNT"
    ok=$(( ok + ${o:-0} )); failed=$(( failed + ${f:-0} ))
    (( stopped )) && break
    release_lock
    st=$(qctl stats 2>/dev/null || true); pend=${st#pending=}; pend=${pend%% *}
    if [[ "$pend" =~ ^[0-9]+$ ]] && (( pend > 0 )) && acquire_lock; then continue; fi
    break
done
rm -f "$CNT" "${CNT}.qctl.err"

trim_log
log "════════ Worker finished: done=$ok failed=$failed ════════"
printf "${C_GREEN}[✓] Queue finished: done=%d failed=%d${C_RESET}\n" "$ok" "$failed"
exit "$QUEUE_ERR"
