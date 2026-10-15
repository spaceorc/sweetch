#!/bin/sh
# sweetch's recordings, the same on this Mac and the Mac mini: whatever is new — or newer — on
# either side is copied to the other, and nothing is ever deleted, so a recording lost on one
# Mac is still on the other. Each dictation is its own timestamped folder, so the two Macs never
# write the same one. Over Tailscale, so it works away from home too.
set -u
MINI=${MINI:-ivandashkevich@100.102.243.87}
SSH="ssh -i $HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=ivans-mac-mini.local"
HERE="$HOME/Library/Application Support/sweetch"
THERE='Library/Application\ Support/sweetch'

if ! $SSH "$MINI" true 2>/dev/null; then
    echo "$(date '+%F %T') the Mac mini is out of reach"
    exit 0
fi
status=0
for dir in dictation wispr-flow keyboard; do
    mkdir -p "$HERE/$dir"
    $SSH "$MINI" "mkdir -p $THERE/$dir"
    rsync -a --update -e "$SSH" "$HERE/$dir/" "$MINI:$THERE/$dir/" || status=1
    rsync -a --update -e "$SSH" "$MINI:$THERE/$dir/" "$HERE/$dir/" || status=1
done
echo "$(date '+%F %T') synced$( [ $status = 0 ] || echo ' with errors')"
exit $status
