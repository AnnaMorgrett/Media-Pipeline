#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        install.sh
#  @brief       Automated installer for Android (Termux) & Desktop (Linux/macOS/Git Bash).
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     3.0.0
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Color Output (ANSI) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE='\033[0;34m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD='' C_RESET=''
fi

readonly REPO_URL="https://github.com/AnnaMorgrett/Termux.git"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

printf "${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Media Pipeline Installer (Termux & PC) v3.0.0   ${C_RESET}\n"
printf "${C_BOLD}==================================================${C_RESET}\n"

# ── 1. Detect Environment ─────────────────────────────────────────────────────
if [[ -d "/data/data/com.termux" || -n "${TERMUX_VERSION:-}" ]]; then
    IS_TERMUX=true
    TARGET_DIR="/storage/emulated/0/Termux"
    BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
    SD="${MEDIA_DIR:-/storage/emulated/0}"
    printf "${C_BLUE}[*] Target Environment:${C_RESET} Android (Termux)\n"
else
    IS_TERMUX=false
    TARGET_DIR="${CURRENT_DIR}"
    BIN_DIR="${PREFIX:-$HOME/.local/bin}"
    SD="${MEDIA_DIR:-$HOME/TermuxMedia}"
    printf "${C_BLUE}[*] Target Environment:${C_RESET} PC / Desktop Linux / Git Bash\n"
fi

# ── 2. Storage Setup & Permissions ────────────────────────────────────────────
if [[ "$IS_TERMUX" == true ]]; then
    printf "${C_BLUE}[1/5] Configuring Android storage permissions...${C_RESET}\n"
    if [[ ! -d "$HOME/storage" ]]; then
        termux-setup-storage
        printf "${C_YELLOW}[!] Please tap 'Allow' on the Android permission popup...${C_RESET}\n"
        while [[ ! -d "/storage/emulated/0" || ! -w "/storage/emulated/0" ]]; do
            sleep 2
        done
    fi
    printf "${C_GREEN}[✓] Android shared storage is accessible.${C_RESET}\n"
fi

printf "${C_BLUE}[*] Initializing media workspace folders...${C_RESET}\n"
mkdir -p "$SD/DCIM/TikTok" \
         "$SD/Download/yt-dlp" \
         "$SD/Pictures/TikTok_Assets" \
         "$SD/Movies/NormalizedVideo" \
         "$SD/Documents" \
         "$TARGET_DIR"
printf "${C_GREEN}[✓] Workspace folders ready.${C_RESET}\n"

# ── 3. Package & Dependency Check ─────────────────────────────────────────────
printf "${C_BLUE}[2/5] Verifying binary dependencies...${C_RESET}\n"
if [[ "$IS_TERMUX" == true ]]; then
    pkg update -y
    pkg install -y git ffmpeg python python-pip termux-api
    if ! command -v yt-dlp &>/dev/null; then
        pip install --upgrade yt-dlp
    fi
else
    for cmd in ffmpeg ffprobe python3; do
        if ! command -v "$cmd" &>/dev/null; then
            printf "${C_YELLOW}[!] Warning: '%s' is not in PATH. Please install using your package manager.${C_RESET}\n" "$cmd"
        fi
    done
    if ! command -v yt-dlp &>/dev/null; then
        printf "${C_BLUE}[*] Installing yt-dlp via pip...${C_RESET}\n"
        pip install --upgrade yt-dlp 2>/dev/null || python3 -m pip install --upgrade yt-dlp 2>/dev/null || true
    fi
fi
printf "${C_GREEN}[✓] Binary dependencies checked.${C_RESET}\n"

# ── 4. Synchronize Repository in Shared Storage ──────────────────────────────
printf "${C_BLUE}[3/5] Preparing pipeline scripts in %s...${C_RESET}\n" "$TARGET_DIR"
if [[ "$IS_TERMUX" == true ]]; then
    if [[ -d "$TARGET_DIR/.git" ]]; then
        printf "${C_BLUE}[*] Existing repository detected. Safely pulling updates...${C_RESET}\n"
        git -C "$TARGET_DIR" fetch origin main 2>/dev/null || true
        git -C "$TARGET_DIR" pull --ff-only 2>/dev/null || {
            printf "${C_YELLOW}[*] Stashing local changes and pulling updates...${C_RESET}\n"
            git -C "$TARGET_DIR" stash push -m "Pre-install stash" 2>/dev/null || true
            git -C "$TARGET_DIR" pull --rebase origin main 2>/dev/null || git -C "$TARGET_DIR" pull origin main 2>/dev/null || true
            git -C "$TARGET_DIR" stash pop 2>/dev/null || true
        }
    elif [[ "$CURRENT_DIR" != "$TARGET_DIR" ]]; then
        if [[ -d "$CURRENT_DIR/.git" ]]; then
            printf "${C_BLUE}[*] Copying repository to %s...${C_RESET}\n" "$TARGET_DIR"
            cp -rn "$CURRENT_DIR/." "$TARGET_DIR/" 2>/dev/null || true
        else
            printf "${C_BLUE}[*] Cloning repository to %s...${C_RESET}\n" "$TARGET_DIR"
            git clone "$REPO_URL" "$TARGET_DIR"
        fi
    fi
fi

# Ensure user configuration file exists (never overwritten if already present)
if [[ ! -f "$TARGET_DIR/config.env" && -f "$TARGET_DIR/config.env.example" ]]; then
    cp "$TARGET_DIR/config.env.example" "$TARGET_DIR/config.env"
    printf "${C_GREEN}[✓] Initialized config.env from example (-9 LUFS default).${C_RESET}\n"
fi
printf "${C_GREEN}[✓] Scripts and configuration synchronized.${C_RESET}\n"

# ── 5. Generate Global CLI Shortcuts ─────────────────────────────────────────
printf "${C_BLUE}[4/5] Registering global shortcuts in %s...${C_RESET}\n" "$BIN_DIR"
mkdir -p "$BIN_DIR"

# 'tiktok' shortcut
cat << EOF > "$BIN_DIR/tiktok"
#!/usr/bin/env bash
exec bash "$TARGET_DIR/master_run.sh" "\$@"
EOF

# 'dl' shortcut
cat << EOF > "$BIN_DIR/dl"
#!/usr/bin/env bash
set -eu
if [ \$# -lt 1 ]; then
    echo "Usage: dl <URL> [extra yt-dlp options...]" >&2
    exit 1
fi
bash "$TARGET_DIR/download.sh" "\$@"
exec bash "$TARGET_DIR/master_run.sh"
EOF

# 'queue' shortcut
cat << EOF > "$BIN_DIR/queue"
#!/usr/bin/env bash
exec bash "$TARGET_DIR/queue.sh" "\$@"
EOF

# 'webui' shortcut
cat << EOF > "$BIN_DIR/webui"
#!/usr/bin/env bash
exec bash "$TARGET_DIR/webui.sh" "\$@"
EOF

chmod +x "$TARGET_DIR"/*.sh "$TARGET_DIR"/shortcuts/*.sh "$TARGET_DIR"/*.py 2>/dev/null || true
chmod +x "$BIN_DIR/tiktok" "$BIN_DIR/dl" "$BIN_DIR/queue" "$BIN_DIR/webui"

printf "${C_GREEN}[✓] Global shortcuts registered: 'dl', 'tiktok', 'queue', 'webui'.${C_RESET}\n"

# ── 6. Android Share & Quick Settings Integration ────────────────────────────
if [[ "$IS_TERMUX" == true ]]; then
    printf "${C_BLUE}[5/5] Configuring Android Share & Quick Settings integrations...${C_RESET}\n"
    mkdir -p "$HOME/bin" "$HOME/.termux/tasker" "$HOME/.shortcuts/tasks"

    # Android Share URL receiver
    cat << EOF > "$HOME/bin/termux-url-opener"
#!/usr/bin/env bash
exec bash "$TARGET_DIR/share_handler.sh" "\$@"
EOF
    chmod +x "$HOME/bin/termux-url-opener"

    # Android Share File receiver
    cat << EOF > "$HOME/bin/termux-file-editor"
#!/usr/bin/env bash
file="\$1"
case "\${file,,}" in
    *.mp4|*.mov|*.mkv|*.webm|*.avi|*.3gp|*.flv|*.ts|*.m4v)
        exec bash "$TARGET_DIR/share_handler.sh" "\$file"
        ;;
    *)
        exec "\${EDITOR:-nano}" "\$file"
        ;;
esac
EOF
    chmod +x "$HOME/bin/termux-file-editor"

    # Quick Settings Tile & Termux:Widget Shortcuts
    cp -f "$TARGET_DIR/shortcuts/media_normalize.sh" "$HOME/.termux/tasker/media_normalize.sh" 2>/dev/null || true
    cp -f "$TARGET_DIR/shortcuts/media_webui.sh" "$HOME/.termux/tasker/media_webui.sh" 2>/dev/null || true
    cp -f "$TARGET_DIR/shortcuts/media_normalize.sh" "$HOME/.shortcuts/tasks/media_normalize.sh" 2>/dev/null || true
    cp -f "$TARGET_DIR/shortcuts/media_webui.sh" "$HOME/.shortcuts/tasks/media_webui.sh" 2>/dev/null || true
    chmod +x "$HOME/.termux/tasker"/*.sh "$HOME/.shortcuts/tasks"/*.sh 2>/dev/null || true

    printf "${C_GREEN}[✓] Android Share & Quick Settings integrations configured.${C_RESET}\n"
else
    printf "${C_BLUE}[5/5] Desktop configuration complete.${C_RESET}\n"
fi

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    printf "\n${C_YELLOW}--------------------------------------------------${C_RESET}\n"
    printf "${C_YELLOW}  NOTE: %s is not currently in your PATH.${C_RESET}\n" "$BIN_DIR"
    printf "  Add it to your profile (e.g., ~/.bashrc or ~/.zshrc):\n"
    printf "    export PATH=\"%s:\$PATH\"\n" "$BIN_DIR"
    printf "${C_YELLOW}--------------------------------------------------${C_RESET}\n"
fi

printf "\n${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Installation Complete!                         ${C_RESET}\n"
printf "  - Target Audio Loudness: ${C_GREEN}-9 LUFS (Constant Linear Gain)${C_RESET}\n"
printf "  - Storage Directory:     ${C_GREEN}%s${C_RESET}\n" "$TARGET_DIR"
printf "  - Commands:\n"
printf "      ${C_GREEN}dl <URL>${C_RESET}       Download & normalize immediately\n"
printf "      ${C_GREEN}tiktok${C_RESET}         Batch process existing media\n"
printf "      ${C_GREEN}queue add <U>${C_RESET}  Add to persistent FIFO background queue\n"
printf "      ${C_GREEN}webui open${C_RESET}     Launch mobile Web UI in browser\n"
printf "  - Android Share:       Share any video/link to Termux to queue\n"
printf "  - Notification Tile:   Pin via Web UI or run 'bash %s/notification_tile.sh'\n" "$TARGET_DIR"
printf "${C_BOLD}==================================================${C_RESET}\n"
