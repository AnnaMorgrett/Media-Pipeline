#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    SD="${MEDIA_DIR:-/storage/emulated/0}"
else
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
fi

readonly DL_DIR="$SD/Download/yt-dlp"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/data/data/com.termux/files/home}/.cache}/media-pipeline"
readonly COOKIE_FILE="${YT_DLP_COOKIES:-$CACHE_DIR/cookies.txt}"
readonly FENNEC_UA="Mozilla/5.0 (Android 15; Mobile; rv:132.0) Gecko/132.0 Firefox/132.0"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { echo "Usage: dl <URL> [OPTIONS...] -> $DL_DIR"; exit 0; }
[[ $# -ge 1 ]] || { printf "${C_RED}[ERROR] Missing URL argument.${C_RESET}\n" >&2; exit 2; }

mkdir -p "$DL_DIR"
url="$1"; shift
EXTRA_ARGS=("$@")
YT_PID=""
TMP_LOG="$(mktemp "${TMPDIR:-/tmp}/dl-tier.XXXXXX")"
trap '[[ -n "$YT_PID" ]] && kill "$YT_PID" 2>/dev/null; rm -f "$TMP_LOG"; exit 143' INT TERM HUP

sync_cookies() {
    [[ -x "$SCRIPT_DIR/sync_cookies.sh" ]] && bash "$SCRIPT_DIR/sync_cookies.sh" >/dev/null 2>&1 || true
}
run_ytdlp() {
    local -a auth_args=("$@") result_args=()
    [[ -n "${DL_RESULT_FILE:-}" ]] && result_args=(--print-to-file "after_move:filepath" "$DL_RESULT_FILE")
    : > "$TMP_LOG"
    set +e
    yt-dlp -S "vcodec:h264,res,acodec:m4a" -P "$DL_DIR" -o "%(title).100B [%(id)s].%(ext)s" \
        "${auth_args[@]}" "${result_args[@]}" "${EXTRA_ARGS[@]}" \
        "$url" > >(tee -a "$TMP_LOG") 2> >(tee -a "$TMP_LOG" >&2) &
    YT_PID=$!; wait "$YT_PID"; local rc=$?; YT_PID=""
    set -e
    return "$rc"
}

run_gallerydl() {
    command -v gallery-dl &>/dev/null || return 1
    sync_cookies
    local -a g_args=(-D "$DL_DIR" --user-agent "$FENNEC_UA")
    [[ -s "$COOKIE_FILE" ]] && g_args+=(--cookies "$COOKIE_FILE")
    [[ -n "${DL_RESULT_FILE:-}" ]] && g_args+=(--exec 'python3 -c "import os,sys; open(os.environ[\"DL_RESULT_FILE\"],\"a\").write(sys.argv[1]+chr(10))" {}')
    printf "${C_BLUE}[*] Falling back to gallery-dl:${C_RESET} %s\n" "$url"
    : > "$TMP_LOG"
    set +e
    gallery-dl "${g_args[@]}" "$url" > >(tee -a "$TMP_LOG") 2> >(tee -a "$TMP_LOG" >&2) &
    YT_PID=$!; wait "$YT_PID"; local rc=$?; YT_PID=""
    set -e
    return "$rc"
}
printf "${C_BLUE}[*] Ingesting media:${C_RESET} %s\n" "$url"
printf "${C_BLUE}[*] Destination folder:${C_RESET} %s\n" "$DL_DIR"

if [[ "$url" =~ facebook\.com/(share/p/|stories/|photo) ]]; then
    if run_gallerydl; then rm -f "$TMP_LOG"; printf "${C_GREEN}[✓] Download finished via gallery-dl.${C_RESET}\n"; exit 0; fi
fi

if run_ytdlp; then rm -f "$TMP_LOG"; printf "${C_GREEN}[✓] Download finished successfully.${C_RESET}\n"; exit 0; fi
err_text="$(cat "$TMP_LOG" 2>/dev/null || true)"

if [[ ! "$err_text" =~ Unsupported\ URL || "$url" =~ (facebook\.com|fb\.watch|instagram\.com|x\.com|twitter\.com|tiktok\.com) ]]; then
    sync_cookies
    if [[ -s "$COOKIE_FILE" ]]; then
        printf "${C_YELLOW}[~] Retrying with Fennec cookies...${C_RESET}\n"
        if run_ytdlp --cookies "$COOKIE_FILE"; then rm -f "$TMP_LOG"; printf "${C_GREEN}[✓] Download finished (authenticated).${C_RESET}\n"; exit 0; fi
        err_text="$(cat "$TMP_LOG" 2>/dev/null || true)"
    fi
fi

if [[ "$err_text" =~ (Unsupported\ URL|No\ video\ formats|Cannot\ parse\ data) ]]; then
    if run_gallerydl; then rm -f "$TMP_LOG"; printf "${C_GREEN}[✓] Download finished via gallery-dl.${C_RESET}\n"; exit 0; fi
fi

rm -f "$TMP_LOG"
exit 1
