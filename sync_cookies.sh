#!/usr/bin/env bash
set -eu
CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/data/data/com.termux/files/home}/.cache}/media-pipeline"
OUT_COOKIES="$CACHE_DIR/cookies.txt"
DB_CACHE="$CACHE_DIR/db_path"
mkdir -p "$CACHE_DIR"
run_su() { su -mm -c "$1" 2>/dev/null || su -c "$1"; }

DB_PATH=""
if [[ -s "$DB_CACHE" ]]; then
    CACHED_DB=$(cat "$DB_CACHE")
    run_su "[ -f '$CACHED_DB' ]" && DB_PATH="$CACHED_DB"
fi
if [[ -z "$DB_PATH" ]]; then
    DB_PATH=$(run_su 'for b in /data/user/0 /data/data; do for d in "$b"/*fennec* "$b"/*firefox* "$b"/*mull* "$b"/*iceraven* "$b"/*mozilla*; do [ -d "$d" ] && find "$d" -maxdepth 6 -name "cookies.sqlite" 2>/dev/null; done; done | xargs -r ls -1t 2>/dev/null | head -n 1')
    [[ -n "$DB_PATH" ]] && printf '%s' "$DB_PATH" > "$DB_CACHE"
fi
[[ -n "$DB_PATH" ]] || { echo "[cookies] No Fennec/Firefox cookies.sqlite found." >&2; exit 1; }

if [[ "${FORCE_COOKIE_SYNC:-0}" != "1" && -s "$OUT_COOKIES" ]]; then
    OUT_MTIME=$(stat -c %Y "$OUT_COOKIES" 2>/dev/null || echo 0)
    DB_MTIME=$(run_su "stat -c %Y '$DB_PATH' '${DB_PATH}-wal' 2>/dev/null | sort -nr | head -n 1" || echo 0)
    [[ "$DB_MTIME" =~ ^[0-9]+$ ]] && (( DB_MTIME > 0 && OUT_MTIME >= DB_MTIME )) && exit 0
fi
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cookie-sync.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
UID_OWNER=$(id -u)
run_su "cp -f '$DB_PATH' '$TMP_DIR/cookies.sqlite'; [ -f '${DB_PATH}-wal' ] && cp -f '${DB_PATH}-wal' '$TMP_DIR/cookies.sqlite-wal'; [ -f '${DB_PATH}-shm' ] && cp -f '${DB_PATH}-shm' '$TMP_DIR/cookies.sqlite-shm'; chown -R $UID_OWNER:$UID_OWNER '$TMP_DIR'; chmod 600 '$TMP_DIR'/cookies.sqlite*"

python3 - "$TMP_DIR/cookies.sqlite" "$OUT_COOKIES.tmp" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
mem = sqlite3.connect(":memory:")
src.backup(mem)
src.close()
rows = mem.execute("SELECT host, path, isSecure, expiry, name, value FROM moz_cookies").fetchall()
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("# Netscape HTTP Cookie File\n")
    for h, p, s, e, n, v in rows:
        f.write(f"{h}\t{'TRUE' if h.startswith('.') else 'FALSE'}\t{p}\t{'TRUE' if s else 'FALSE'}\t{int(e)}\t{n}\t{v}\n")
mem.close()
PY
chmod 600 "$OUT_COOKIES.tmp" && mv -f "$OUT_COOKIES.tmp" "$OUT_COOKIES"
echo "[cookies] Synced $(wc -l < "$OUT_COOKIES") entries from $DB_PATH"
