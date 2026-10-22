#!/bin/zsh
# The keyboard's log off the iPhone when it can't reach a Mac (no Tailscale, a VPN in the way): the
# app, started over the cable or the network, copies the batches waiting into its Documents
# (PhoneLog.flush → KeyLogSpool.mirror); they're copied from there and handed to this Mac's
# sweetch, which keeps each batch once — the phone sending them later adds nothing.
set -e
PHONE=${PHONE_ID:?}
export DEVELOPER_DIR=${XCODE_DEV:-/Applications/Xcode.app/Contents/Developer}
TOKEN=$(cat "$HOME/Library/Application Support/sweetch/server-token")
OUT=$(mktemp -d)
if xcrun devicectl device process launch --device $PHONE com.spaceorc.sweetch.phone >/dev/null 2>&1; then
    sleep 4
else
    echo "couldn't start Sweetch on the phone (locked?) — taking what it left when last opened"
fi
xcrun devicectl device copy from --device $PHONE --domain-type appDataContainer \
    --domain-identifier com.spaceorc.sweetch.phone --source Documents/keylog-out --destination $OUT >/dev/null
kept=0; batches=0
for f in $OUT/**/*.jsonl(N); do
    batch=$(basename $f .jsonl)
    body=$(python3 -c 'import json,sys; print(json.dumps({"batch": sys.argv[2], "events": [json.loads(l) for l in open(sys.argv[1]) if l.strip()]}))' $f $batch)
    n=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data-binary "$body" \
        http://127.0.0.1:8180/keyboard-log | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kept", 0))')
    kept=$((kept + n)); batches=$((batches + 1))
done
rm -rf $OUT
echo "phone log: $batches batches waiting on the phone, $kept new events kept"
