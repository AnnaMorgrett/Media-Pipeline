#!/usr/bin/env bash
set -eu
CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/data/data/com.termux/files/home}/.cache}/media-pipeline"
OUT_COOKIES="$CACHE_DIR/cookies.txt"
DB_CACHE="$CACHE_DIR/db_path"
mkdir -p "$CACHE_DIR"

command -v su >/dev/null 2>&1 || { echo "[cookies] 'su' not found (root required)." >&2; exit 1; }
SU_MODE="su"
if su -mm -c true >/dev/null 2>&1; then
    SU_MODE="su_mm"
elif ! su -c true >/dev/null 2>&1; then
    echo "[cookies] Root permission denied." >&2
    exit 1
fi
run_su() {
    if [[ "$SU_MODE" == "su_mm" ]]; then
        su -mm -c "$1"
    else
        su -c "$1"
    fi
}

DB_PATH=""
if [[ -s "$DB_CACHE" ]]; then
    CACHED_DB=$(cat "$DB_CACHE")
    printf -v q_cached '%q' "$CACHED_DB"
    run_su "[ -f $q_cached ]" 2>/dev/null && DB_PATH="$CACHED_DB"
fi
if [[ -z "$DB_PATH" ]]; then
    DB_PATH=$(run_su 'for b in /data/user/0 /data/data; do for d in "$b"/*fennec* "$b"/*firefox* "$b"/*mull* "$b"/*iceraven* "$b"/*mozilla*; do [ -d "$d" ] && find "$d" -maxdepth 6 -name "cookies.sqlite" 2>/dev/null; done; done | xargs -r ls -1t 2>/dev/null | head -n 1' 2>/dev/null || true)
    [[ -n "$DB_PATH" ]] && printf '%s' "$DB_PATH" > "$DB_CACHE"
fi
[[ -n "$DB_PATH" ]] || { echo "[cookies] No Fennec/Firefox cookies.sqlite found." >&2; exit 1; }

printf -v q_db '%q' "$DB_PATH"
printf -v q_wal '%q' "${DB_PATH}-wal"
printf -v q_shm '%q' "${DB_PATH}-shm"

if [[ "${FORCE_COOKIE_SYNC:-0}" != "1" && -s "$OUT_COOKIES" ]]; then
    OUT_MTIME=$(stat -c %Y "$OUT_COOKIES" 2>/dev/null || echo 0)
    DB_MTIME=$(run_su "stat -c %Y $q_db $q_wal 2>/dev/null | sort -nr | head -n 1" 2>/dev/null || echo 0)
    [[ "$DB_MTIME" =~ ^[0-9]+$ ]] && (( DB_MTIME > 0 && OUT_MTIME >= DB_MTIME )) && exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cookie-sync.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
UID_OWNER=$(id -u)
GID_OWNER=$(id -g)
printf -v q_tmp '%q' "$TMP_DIR"
run_su "cp -f $q_db $q_tmp/cookies.sqlite; [ -f $q_wal ] && cp -f $q_wal $q_tmp/cookies.sqlite-wal; [ -f $q_shm ] && cp -f $q_shm $q_tmp/cookies.sqlite-shm; chown -R $UID_OWNER:$GID_OWNER $q_tmp; chmod 600 $q_tmp/cookies.sqlite*"

count=$(python3 - "$TMP_DIR/cookies.sqlite" "$OUT_COOKIES.tmp" <<'PY'
import sqlite3, sys

def clean(val):
    if val is None:
        return ""
    return str(val).replace("\r", "").replace("\n", "").replace("\t", " ")

src = sqlite3.connect(sys.argv[1])
mem = sqlite3.connect(":memory:")
try:
    src.backup(mem)
finally:
    src.close()

try:
    rows = mem.execute("SELECT host, path, isSecure, expiry, name, value FROM moz_cookies").fetchall()
finally:
    mem.close()

written = 0
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("# Netscape HTTP Cookie File\n")
    for h, p, s, e, n, v in rows:
        host = clean(h)
        name = clean(n)
        if not host or not name:
            continue
        path = clean(p) or "/"
        val = clean(v)
        exp = int(e or 0)
        f.write(f"{host}\t{'TRUE' if host.startswith('.') else 'FALSE'}\t{path}\t{'TRUE' if s else 'FALSE'}\t{exp}\t{name}\t{val}\n")
        written += 1
print(written)
PY
)
chmod 600 "$OUT_COOKIES.tmp" && mv -f "$OUT_COOKIES.tmp" "$OUT_COOKIES"
echo "[cookies] Synced $count entries from $DB_PATH"
