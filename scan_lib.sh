#!/usr/bin/env bash
# scan_lib.sh - shared Android media-scan helper (source it; do not run).
# scan_queue FILE: scans every existing path listed in FILE in ONE batch, oldest first.
# Needs C_GREEN/C_YELLOW/C_RESET (optional; empty is fine).
_scan_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
_file_uri() {
    local p="$1" i c hex out="file://"
    LC_ALL=C
    for (( i=0; i<${#p}; i++ )); do
        c="${p:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_/-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}
scan_queue() {
    local qf="$1" f out err_out="" uri rc=1 i
    local -a files=() chunk=()
    [[ -s "$qf" ]] || return 0
    while IFS= read -r f; do
        [[ -f "$f" ]] && files+=("$f")
    done < <(sort -u "$qf" | while IFS= read -r q; do
                [[ -f "$q" ]] && printf '%s\t%s\n' "$(_scan_mtime "$q")" "$q"
             done | sort -t "$(printf '\t')" -k1,1n -s | cut -f2-)
    (( ${#files[@]} > 0 )) || return 0

    if command -v termux-media-scan &>/dev/null; then
        rc=0
        for (( i=0; i<${#files[@]}; i+=50 )); do
            chunk=("${files[@]:i:50}")
            if ! out=$(termux-media-scan "${chunk[@]}" </dev/null 2>&1); then
                rc=$?
                err_out="$out"
            fi
        done
    elif command -v am &>/dev/null && [[ -e /system/build.prop || -n "${TERMUX_VERSION:-}" ]]; then
        rc=0
        for f in "${files[@]}"; do
            uri=$(_file_uri "$f")
            if ! out=$(am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "$uri" </dev/null 2>&1); then
                rc=$?
                err_out="$out"
            fi
        done
    elif [[ ! -e /system/build.prop && -z "${TERMUX_VERSION:-}" ]]; then
        # Non-Android host (Linux/macOS/PC): Android media scanner is not applicable.
        return 0
    else
        err_out="no termux-media-scan or am found"
    fi

    if (( rc == 0 )); then
        printf "${C_GREEN}[✓] Media scan:${C_RESET} %d file(s) added to gallery\n" "${#files[@]}"
    else
        printf "${C_YELLOW}[!] Media scan failed (install Termux:API app + 'pkg install termux-api'): %s${C_RESET}\n" "${err_out:-}" >&2
    fi
}
