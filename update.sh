#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  @file        update.sh
#  @brief       Safe Git updater preserving user configuration & local changes.
#  @author      Anna Morgrett (https://github.com/AnnaMorgrett/Termux)
#  @license     MIT
#  @version     3.0.0
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/media_processor_log.txt"

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

log_update() {
    printf '[%s] [UPDATE] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

printf "${C_BOLD}==================================================${C_RESET}\n"
printf "${C_BOLD}  Media Pipeline Updater (Safe Git Pull)          ${C_RESET}\n"
printf "${C_BOLD}==================================================${C_RESET}\n"

if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    printf "${C_RED}[ERROR] %s is not a Git repository.${C_RESET}\n" "$SCRIPT_DIR" >&2
    exit 1
fi

cd "$SCRIPT_DIR"

# 1. Check for remote updates
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
printf "${C_BLUE}[*] Fetching updates from remote repository (branch: %s)...${C_RESET}\n" "$current_branch"
log_update "Fetching origin/$current_branch"

git fetch origin "$current_branch" 2>&1 | tee -a "$LOG_FILE" || {
    printf "${C_YELLOW}[!] Warning: git fetch encountered an error (check network connection).${C_RESET}\n" >&2
}

local_hash=$(git rev-parse HEAD)
remote_hash=$(git rev-parse "origin/$current_branch" 2>/dev/null || echo "$local_hash")

if [[ "$local_hash" == "$remote_hash" ]]; then
    printf "${C_GREEN}[✓] Pipeline is already up to date! (Commit: %s)${C_RESET}\n" "${local_hash:0:7}"
    exit 0
fi

printf "${C_BLUE}[*] Updates detected: %s -> %s${C_RESET}\n" "${local_hash:0:7}" "${remote_hash:0:7}"

# 2. Check for local modifications
has_diff=$(git status --porcelain 2>/dev/null || true)
stashed=0

if [[ -n "$has_diff" ]]; then
    printf "${C_YELLOW}[*] Local modifications detected. Safely stashing changes...${C_RESET}\n"
    git stash push -m "Auto-stashed before update $(date '+%F %T')" >> "$LOG_FILE" 2>&1 || true
    stashed=1
fi

# 3. Pull latest commits without overwriting untracked user configs
printf "${C_BLUE}[*] Applying latest commits...${C_RESET}\n"
if git pull --ff-only origin "$current_branch" 2>&1 | tee -a "$LOG_FILE"; then
    printf "${C_GREEN}[✓] Successfully pulled new commits.${C_RESET}\n"
    log_update "Pulled updates successfully to $(git rev-parse --short HEAD)"
elif git pull --rebase origin "$current_branch" 2>&1 | tee -a "$LOG_FILE"; then
    printf "${C_GREEN}[✓] Successfully rebased with new commits.${C_RESET}\n"
    log_update "Rebased updates successfully to $(git rev-parse --short HEAD)"
else
    printf "${C_YELLOW}[!] Fast-forward failed; resetting tracked files to origin/%s while preserving untracked files...${C_RESET}\n" "$current_branch"
    git reset origin/"$current_branch" >> "$LOG_FILE" 2>&1
    git checkout -- . >> "$LOG_FILE" 2>&1
fi

# 4. Restore stashed changes if any
if (( stashed == 1 )); then
    printf "${C_BLUE}[*] Restoring local modifications...${C_RESET}\n"
    git stash pop >> "$LOG_FILE" 2>&1 || {
        printf "${C_YELLOW}[!] Note: Stashed changes restored with potential conflicts. Check 'git status'.${C_RESET}\n"
    }
fi

# 5. Restore executable permissions
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/shortcuts/*.sh 2>/dev/null || true

printf "\n${C_GREEN}[✓] Update completed successfully!${C_RESET}\n"
printf "  Current commit: ${C_BOLD}%s${C_RESET} (%s)\n" "$(git rev-parse --short HEAD)" "$(git log -1 --pretty=%B | head -1)"
printf "  User config (config.env) and queue state were completely preserved.\n"
printf "${C_BOLD}==================================================${C_RESET}\n"
