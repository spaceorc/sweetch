#!/bin/bash
# The Mac mini's sweetch keeps itself up to date: every five minutes (launchd, see update.plist) it
# fetches main and, when there's something new, builds it here and swaps the dictation server for
# it. A build that fails, or a server that doesn't answer once started, is rolled back: a server
# that's a version behind beats one that's gone. A dictation being heard isn't cut short — the swap
# waits for a quiet moment. Installed by `make mini` on the MacBook.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
SERVICE="com.spaceorc.sweetch.server"
INSTALLED="$HOME/sweetch/sweetch.app"
# The commit the running server was built from.
INSTALLED_COMMIT="$HOME/sweetch/commit"
LOG="$HOME/Library/Logs/sweetch-update.log"
LOCK="$ROOT/.update.lock"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# mkdir is atomic: a lock without flock, which macOS lacks.
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

git fetch --quiet origin main 2>/dev/null || { log "git fetch failed"; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    log "local changes in $ROOT — not updating"
    exit 0
fi
before=$(git rev-parse HEAD)
after=$(git rev-parse origin/main)
running=$(cat "$INSTALLED_COMMIT" 2>/dev/null)
[ "$running" = "$after" ] && [ -d "$INSTALLED" ] && exit 0

# Not in the middle of a dictation, nor right after one (the next may be coming).
idle=$(curl -s -m 3 http://127.0.0.1:8180/ping | python3 -c 'import json,sys; print(json.load(sys.stdin).get("idle", 999))' 2>/dev/null || echo 999)
if [ "$idle" -lt 60 ]; then
    log "waiting: a dictation $idle s ago"
    exit 0
fi

short=$(git rev-parse --short "$after")
log "updating ${running:0:7} → $short: $(git log --format=%s -1 "$after" | cut -c1-120)"
if ! git merge --ff-only --quiet "$after"; then
    log "can't fast-forward to $short"
    exit 1
fi
if ! make serve-app >> "$LOG" 2>&1; then
    log "build failed — staying on ${before:0:7}"
    git reset --hard --quiet "$before"
    exit 1
fi

# launchd reads its own copy of the plist: a changed one is put in place and reloaded.
plist="$HOME/Library/LaunchAgents/$SERVICE.plist"
fresh=$(sed "s|__HOME__|$HOME|g" Tools/mini/server.plist)
plist_changed=0
[ "$fresh" != "$(cat "$plist" 2>/dev/null)" ] && plist_changed=1

answers() {
    for _ in $(seq 1 60); do
        curl -s -m 2 http://127.0.0.1:8180/ping >/dev/null && return 0
        sleep 1
    done
    return 1
}

restart() {
    if [ "$plist_changed" = 1 ]; then
        echo "$fresh" > "$plist"
        launchctl bootout "gui/$(id -u)/$SERVICE" 2>/dev/null
        launchctl bootstrap "gui/$(id -u)" "$plist"
    else
        launchctl kickstart -k "gui/$(id -u)/$SERVICE"
    fi
}

rm -rf "$INSTALLED.previous"
[ -d "$INSTALLED" ] && mv "$INSTALLED" "$INSTALLED.previous"
mkdir -p "$(dirname "$INSTALLED")"
cp -R build/serve/sweetch.app "$INSTALLED"
restart
if answers; then
    echo "$after" > "$INSTALLED_COMMIT"
    log "running $short"
    exit 0
fi

log "$short doesn't answer — back to ${before:0:7}"
git reset --hard --quiet "$before"
if [ -d "$INSTALLED.previous" ]; then
    rm -rf "$INSTALLED"
    mv "$INSTALLED.previous" "$INSTALLED"
fi
launchctl kickstart -k "gui/$(id -u)/$SERVICE"
exit 1
