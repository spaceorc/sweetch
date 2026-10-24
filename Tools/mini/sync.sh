#!/bin/sh
# sweetch's recordings, the same on this Mac and the Mac mini: whatever is new — or newer — on
# either side is copied to the other, and nothing is deleted by accident, so a recording lost on
# one Mac is still on the other. What was removed on purpose (a screenshot with a password on it, a
# dictation forgotten) is named in a tombstone — sweetch's Tombstones, a file per Mac — which goes
# across first and is carried out on both sides before anything else is copied, so it stays gone. Each dictation is its own timestamped folder, so the two Macs never
# write the same one. Over Tailscale, so it works away from home too.
set -u
MINI=${MINI:-ivandashkevich@100.64.10.10}
SSH="ssh -i $HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=ivans-mac-mini.local"
HERE="$HOME/Library/Application Support/sweetch"
THERE='Library/Application\ Support/sweetch'

# Over Tailscale, or on the home network when Tailscale can't get through (the work VPN claims part
# of Tailscale's addresses).
if ! $SSH "$MINI" true 2>/dev/null; then
    MINI="${MINI%@*}@ivans-mac-mini.local"
    if ! $SSH "$MINI" true 2>/dev/null; then
        echo "$(date '+%F %T') the Mac mini is out of reach"
        exit 0
    fi
fi
status=0
mkdir -p "$HERE/tombstones"
$SSH "$MINI" "mkdir -p $THERE/tombstones"
rsync -a --update -e "$SSH" "$HERE/tombstones/" "$MINI:$THERE/tombstones/" || status=1
rsync -a --update -e "$SSH" "$MINI:$THERE/tombstones/" "$HERE/tombstones/" || status=1
# Only paths inside the synced folders, nothing climbing out of them.
dead=$(cat "$HERE"/tombstones/*.jsonl 2>/dev/null | sed -n 's/.*"path":"\([^"]*\)".*/\1/p' \
    | grep -E '^(dictation|wispr-flow|keyboard|typing|llm-usage|ui)/[^/]+(/[^/]+)*$' | grep -v '\.\.' | sort -u)
if [ -n "$dead" ]; then
    printf '%s\n' "$dead" | while IFS= read -r p; do rm -rf -- "$HERE/$p"; done
    printf '%s\n' "$dead" | $SSH "$MINI" "cd $THERE && while IFS= read -r p; do rm -rf -- \"\$p\"; done" || status=1
fi
for dir in dictation wispr-flow keyboard typing llm-usage ui; do
    mkdir -p "$HERE/$dir"
    $SSH "$MINI" "mkdir -p $THERE/$dir"
    rsync -a --update -e "$SSH" "$HERE/$dir/" "$MINI:$THERE/$dir/" || status=1
    rsync -a --update -e "$SSH" "$MINI:$THERE/$dir/" "$HERE/$dir/" || status=1
done
echo "$(date '+%F %T') synced$( [ $status = 0 ] || echo ' with errors')"
exit $status
