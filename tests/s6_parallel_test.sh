#!/usr/bin/env bash
# S6 tests: parallel worker (WORKERS>1). Temp dir only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
S="$T/scripts"; mkdir -p "$S" "$T/media/in"
for f in normalize.sh worker.sh qctl.py download.sh scan_lib.sh config_lib.sh; do cp "$HERE/$f" "$S/"; done
export MEDIA_DIR="$T/media" QUEUE_DIR="$S/data/queue" FAST=1
Q="python3 $S/qctl.py"; OUT="$MEDIA_DIR/Movies/NormalizedVideo"; LOGF="$S/media_processor_log.txt"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
for i in 1 2 3 4 5; do
  ffmpeg -v error -y -f lavfi -i testsrc=size=320x240:rate=25:duration=4 -f lavfi -i "anoisesrc=d=4:c=pink:a=0.05:seed=$i" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/media/in/c$i.mp4"
done
reset() { pkill -f "$S/worker.sh" 2>/dev/null; sleep 0.3; rm -rf "$S/data" "$MEDIA_DIR/Movies"; : > "$LOGF"; for i in 1 2 3 4 5; do [[ -f "$T/media/in/c$i.mp4" ]] || cp "$T/media/in/.c$i.bak" "$T/media/in/c$i.mp4"; done; }
for i in 1 2 3 4 5; do cp "$T/media/in/c$i.mp4" "$T/media/in/.c$i.bak"; done
addall() { for i in 1 2 3 4 5; do $Q add --file "$T/media/in/c$i.mp4" >/dev/null; done; }

echo "== P1 qctl next --max"
reset; addall
a=$($Q next --max 2 | cut -f1); b=$($Q next --max 2 | cut -f1); $Q next --max 2 >/dev/null; rc=$?
chk "--max 2 hands out two jobs in FIFO order, then stops (exit 1)" "[[ '$a' == 1 && '$b' == 2 && $rc == 1 ]]"
reset; addall; $Q next >/dev/null; $Q next >/dev/null; chk "default stays one at a time" "[[ $? == 1 ]]"

echo "== P2 WORKERS=3 processes everything, truly in parallel"
reset; addall
( cd "$S" && WORKERS=3 bash worker.sh > "$T/w.out" 2>&1 ) & WP=$!
maxrun=0; for _ in $(seq 1 200); do r=$($Q stats | grep -o 'running=[0-9]*' | cut -d= -f2); (( ${r:-0} > maxrun )) && maxrun=$r; kill -0 $WP 2>/dev/null || break; sleep 0.2; done
wait $WP; rc=$?
chk "exit 0, all 5 done, none failed" "[[ $rc == 0 && \$($Q stats) == 'pending=0 running=0 done=5 failed=0' ]]"
chk "5 outputs saved" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 5 ]]"
chk "at least 2 jobs were running at the same time (max seen $maxrun)" "[[ $maxrun -ge 2 ]]"
chk "summary says done=5 failed=0" "grep -q 'done=5 failed=0' '$T/w.out'"
chk "no leftover temp files in the queue folder" "[[ -z \$(ls -A '$QUEUE_DIR' | grep -E '^\\.(out|cnt|res)\\.') ]]"
chk "originals of local files kept" "[[ \$(ls '$T'/media/in/c*.mp4 | wc -l) == 5 ]]"

echo "== P3 WORKERS=2 + kill -9 of the worker: nothing recorded, next worker finishes all"
reset; addall
( cd "$S" && exec env WORKERS=2 bash worker.sh >/dev/null 2>&1 ) & WP=$!
for _ in $(seq 1 50); do [[ $($Q stats | grep -o 'running=[0-9]*') == 'running=2' ]] && break; sleep 0.1; done
kill -9 $WP; sleep 1.5; pkill -9 -f "$S/normalize.sh"; sleep 0.5
chk "after kill -9 no job was falsely marked done/failed by an orphan" "[[ \$($Q stats | grep -o 'failed=[0-9]*') == 'failed=0' ]]"
( cd "$S" && WORKERS=2 bash worker.sh > "$T/w3.out" 2>&1 ); rc=$?
chk "new worker recovers and finishes all 5" "[[ $rc == 0 && \$($Q stats) == 'pending=0 running=0 done=5 failed=0' ]]"

echo "== P4 stop flag: running jobs finish, no new ones start"
reset; addall
( cd "$S" && WORKERS=2 bash worker.sh > "$T/w4.out" 2>&1 ) & WP=$!
for _ in $(seq 1 50); do [[ $($Q stats | grep -o 'running=[0-9]*') == 'running=2' ]] && break; sleep 0.1; done
touch "$QUEUE_DIR/.stop"; wait $WP
st=$($Q stats)
chk "stopped cleanly: nothing left running, some jobs still pending" "[[ '$st' == *running=0* && '$st' != *pending=0* && '$st' == *failed=0 ]]"
chk "the jobs that ran are done" "[[ '$st' != *done=0* ]]"

echo "== P5 TERM: every running job goes back to pending"
reset; addall
( cd "$S" && exec env WORKERS=2 bash worker.sh >/dev/null 2>&1 ) & WP=$!
for _ in $(seq 1 50); do [[ $($Q stats | grep -o 'running=[0-9]*') == 'running=2' ]] && break; sleep 0.1; done
kill -TERM $WP; wait $WP 2>/dev/null; sleep 0.5
chk "no job left running, lock released, no failures" "[[ \$($Q stats | grep -o 'running=[0-9]*') == 'running=0' && ! -d '$QUEUE_DIR/.worker.lock' && \$($Q stats | grep -o 'failed=[0-9]*') == 'failed=0' ]]"
chk "no orphan normalize/ffmpeg processes" "[[ -z \$(pgrep -f '$S/normalize.sh') ]]"

echo; echo "RESULT: $pass passed, $failn failed"; [[ $failn -eq 0 ]]
