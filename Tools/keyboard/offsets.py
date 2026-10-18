"""Where the user's finger lands on each key, from the keyboard's log: the mean offset from the
key's centre, of taps on letters in words that stayed as typed or were put right by autocorrect
(the word's final letter is the label, as Gboard takes it). Shrunk toward zero while few taps
back it. `--clusters`: one offset per group of keys (row × left/middle/right), as Gboard does.
`--until YYYY-MM-DD`: only days before (for the bench's held-out day). Prints {letter: [dx, dy]}."""
import argparse
import collections
import glob
import json
from pathlib import Path

LOG = Path.home() / "Library/Application Support/sweetch/keyboard"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--until")
    ap.add_argument("--clusters", action="store_true")
    ap.add_argument("--fast", action="store_true", help="only taps under 0.35 s after the one before")
    ap.add_argument("--shrink", type=float, default=30)
    a = ap.parse_args()
    keys, sums = {}, collections.defaultdict(lambda: [0.0, 0.0, 0])
    for path in sorted(glob.glob(str(LOG / "*.jsonl"))):
        if a.until and Path(path).name[:10] >= a.until:
            continue
        downs, word, last_up = {}, [], {}
        for line in open(path, encoding="utf-8"):
            if not any(k in line for k in ('"e":"keys"', '"e":"down"', '"e":"up"', '"e":"word"', '"e":"autocorrect"', '"e":"delete', '"e":"choose"')):
                continue
            e = json.loads(line)
            k, run = e["e"], e.get("run")
            if k == "keys" and any(x[0] == "й" for x in e.get("keys", [])):
                keys = {x[0]: x[1:5] for x in e["keys"] if len(x[0]) == 1}
            elif k == "down":
                downs[(run, e.get("touch"))] = e
            elif k == "up":
                key = (e.get("key") or "").lower()
                d = downs.get((run, e.get("touch")))
                gap = e["t"] - last_up.get(run, 0)
                last_up[run] = e["t"]
                if len(key) == 1 and key.isalpha() and d and d.get("x") is not None:
                    word.append((key, d["x"], d["y"], gap))
                elif key == "space" or not key.isalpha():
                    pass
            elif k in ("delete", "delete-word", "choose"):
                word = []
            elif k == "autocorrect":
                typed, fixed = (e.get("typed") or "").lower(), (e.get("fixed") or "").lower()
                if len(typed) == len(fixed) and len(word) >= len(typed) and "".join(t[0] for t in word[-len(typed):]) == typed:
                    word = [(m, x, y, g) for (t, x, y, g), m in zip(word[-len(typed):], fixed)]
                    e["word"] = fixed
            if k in ("word", "autocorrect"):
                final = (e.get("word") or "").lower()
                if k == "word" and len(word) >= len(final) and "".join(t[0] for t in word[-len(final):]) == final:
                    for letter, x, y, gap in word[-len(final):]:
                        if a.fast and gap >= 0.35:
                            continue
                        r = keys.get(letter)
                        if not r:
                            continue
                        group = cluster(letter, keys) if a.clusters else letter
                        s = sums[group]
                        s[0] += x - (r[0] + r[2] / 2)
                        s[1] += y - (r[1] + r[3] / 2)
                        s[2] += 1
                if k == "word":
                    word = []
    out = {}
    for letter in keys:
        s = sums.get(cluster(letter, keys) if a.clusters else letter)
        if s and s[2]:
            shrink = s[2] / (s[2] + a.shrink)
            out[letter] = [round(s[0] / s[2] * shrink, 2), round(s[1] / s[2] * shrink, 2)]
    print(json.dumps(out, ensure_ascii=False))


def cluster(letter, keys):
    """Row × left / middle / right third of the keyboard."""
    x, y, w, h = keys[letter]
    width = max(k[0] + k[2] for k in keys.values())
    return (round(y), min(2, int((x + w / 2) / width * 3)))


if __name__ == "__main__":
    main()
