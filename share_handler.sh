#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        share_handler.sh
#  @brief       Android "Share to Termux" -> queue. Called by the two small scripts
#               that shortcuts.sh puts in ~/bin:
#                 termux-url-opener  <link>      (shared link)
#                 termux-file-editor <file>...   (shared video, or shared text saved as .txt)
#  @version     1.1.0
#  Usage: share_handler.sh url "<text containing a link>"
#         share_handler.sh files <path>...
# ═══════════════════════════════════════════════════════════════════════════════
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DL_RAW="${HOME:-/data/data/com.termux/files/home}/downloads"
HOME_DL="$(cd -P "$HOME_DL_RAW" 2>/dev/null && pwd || printf '%s' "$HOME_DL_RAW")"
Q="$SCRIPT_DIR/q.sh"

say() {
    echo "$*"
    if command -v termux-toast &>/dev/null; then
        if command -v timeout &>/dev/null; then
            timeout 3 termux-toast -s "$*" >/dev/null 2>&1 || true
        else
            termux-toast -s "$*" >/dev/null 2>&1 &
            disown 2>/dev/null || true
        fi
    fi
}
last_line() { printf '%s\n' "$1" | tail -n 1; }
is_video() {
    case "${1,,}" in
        *.mp4|*.mkv|*.webm|*.mov|*.avi|*.3gp|*.3g2|*.ts|*.mts|*.m2ts|*.flv|*.m4v|*.mpeg|*.mpg|*.wmv|*.ogv) return 0 ;;
        *) return 1 ;;
    esac
}
extract_links() {
    printf '%s' "$1" | grep -oE 'https?://[^[:space:]<>\"'"'"']+' | sed -E 's/[.,;:!?)\]"'"'"']+$//' | head -10
}

queued=0; problems=0
queued_ok() { [[ "$1" == *"queued job"* || "$1" == *"requeued"* ]]; }
add_link() {
    local out
    out=$(Q_NO_BG=1 bash "$Q" add "$1" 2>&1)
    if queued_ok "$out"; then
        queued=$((queued + 1))
        say "Queued: $(last_line "$out")"
    else
        problems=$((problems + 1))
        say "$(last_line "$out")"
    fi
}

mode="${1:-}"; [[ $# -gt 0 ]] && shift
case "$mode" in
    url)
        text="${1:-}"
        links=$(extract_links "$text")
        if [[ -z "$links" ]]; then
            say "No link found in the shared text"
            exit 1
        fi
        while IFS= read -r u; do [[ -n "$u" ]] && add_link "$u"; done <<< "$links"
        ;;
    files)
        [[ $# -ge 1 ]] || { say "No file received"; exit 1; }
        for f in "$@"; do
            if [[ ! -f "$f" ]]; then
                problems=$((problems + 1))
                say "File not found: $(basename "$f")"
                continue
            fi
            name="$(basename "$f")"
            fdir="$(cd -P "$(dirname "$f")" && pwd)"
            if is_video "$name"; then
                if [[ "$fdir" == "$HOME_DL" ]]; then
                    out=$(Q_NO_BG=1 bash "$Q" add --consume "$f" 2>&1); rc=$?
                else
                    out=$(Q_NO_BG=1 bash "$Q" add "$f" 2>&1); rc=$?
                fi
                if [[ $rc == 0 ]] && queued_ok "$out"; then
                    queued=$((queued + 1))
                    say "Queued: $name"
                else
                    problems=$((problems + 1))
                    say "$name: $(last_line "$out")"
                fi
            elif [[ "${name,,}" == *.txt ]] && (( $(stat -c %s "$f" 2>/dev/null || echo 0) <= 65536 )); then
                links=$(extract_links "$(cat "$f")")
                if [[ -z "$links" ]]; then
                    problems=$((problems + 1))
                    say "No link found in $name"
                    continue
                fi
                while IFS= read -r u; do [[ -n "$u" ]] && add_link "$u"; done <<< "$links"
                [[ "$fdir" == "$HOME_DL" ]] && rm -f "$f"
            else
                problems=$((problems + 1))
                say "Not a video or a link: $name"
            fi
        done
        ;;
    *) echo "Usage: share_handler.sh url \"<text>\" | files <path>..." >&2; exit 2 ;;
esac

(( queued > 0 )) && bash "$Q" bg >/dev/null 2>&1
exit $(( queued == 0 && problems > 0 ? 1 : 0 ))
