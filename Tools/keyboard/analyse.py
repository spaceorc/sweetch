#!/usr/bin/env python3
"""What the iPhone keyboard's log says about how the user types on it.

Reads every keyboard log the Macs keep (`keyboard/*.jsonl` in sweetch's Application Support),
works out what each tap was meant to be, and reports where taps go wrong:

- a tap is *meant* to be what the user typed in its place after deleting it — a correction is a
  run of deletes and the retyping after it, the two aligned letter by letter: a letter replaced is
  a miss (the tap went to the wrong key), a letter only in the retyping is a lost tap (it never
  typed), a letter only in what was deleted is an extra tap;
- a tap never deleted counted as meant as typed (a hit) — the user may not have noticed, but
  it's the best guess;
- a quick tap (held briefly, the finger still) is told from a deliberate one (held, slid, picked
  while looking at the callout): for a quick one, where it came down is what counts.

Usage: Tools/keyboard/analyse.py [log dir] — prints a report. Pure standard library.
"""

import collections
import json
import math
import statistics
import sys
from pathlib import Path

LOG_DIR = Path.home() / "Library/Application Support/sweetch/keyboard"
QUICK_MS = 150   # held no longer than this, and barely moved: a tap, not a choice
STILL_PT = 6

# The keyboard's layout, as KeyboardSurface.layOut draws it — for logs from before it logged key
# frames (`keys` events).
ROWS = {
    "russian": ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"],
    "english": ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
}
KEY_H, ROW_GAP, GAP, SIDE, TOP = 46, 11, 6, 3, 4


def layout_keys(layout, width=440.0):
    inner = width - 2 * SIDE
    ten = (inner - 9 * GAP) / 10
    rows = ROWS[layout]
    unit = (inner - 10 * GAP) / 11 if len(rows[0]) >= 11 else ten
    keys = {}
    for r, row in enumerate(rows):
        n = len(row)
        x = SIDE + (inner - n * unit - (n - 1) * GAP) / 2
        y = TOP + r * (KEY_H + ROW_GAP)
        for ch in row:
            keys[ch] = (x, y, unit, KEY_H)
            x += unit + GAP
    return keys


def script(char):
    """The layout a letter is typed on: the logs' own layout events lag behind."""
    if "\u0400" <= char.lower() <= "\u04ff":
        return "russian"
    if "a" <= char.lower() <= "z":
        return "english"
    return None


def adjacent(a, b):
    """Two letters' keys touch or nearly: a tap meant for one can land on the other."""
    layout = script(a)
    if layout is None or layout != script(b):
        return False
    keys = layout_keys(layout)
    (ax, ay), (bx, by) = centre(keys[a.lower()]), centre(keys[b.lower()])
    return abs(ax - bx) <= 1.6 * keys[a.lower()][2] and abs(ay - by) <= KEY_H + ROW_GAP + 1


def centre(frame):
    x, y, w, h = frame
    return x + w / 2, y + h / 2


def load(directory):
    seen, events = set(), []
    for path in sorted(directory.glob("*.jsonl")):
        for line in path.open(encoding="utf-8"):
            line = line.strip()
            if not line or line in seen:
                continue
            seen.add(line)
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    events.sort(key=lambda e: e["t"])
    return events


class Tap:
    def __init__(self, char, down, up, slid, layout, prev):
        self.char = char
        self.key = char.lower()
        self.down = down or {}
        self.up = up or {}
        self.slid = slid
        self.layout = layout
        self.prev = prev            # the tap before, if close in time
        self.meant = None           # set by a correction
        self.fate = "hit"           # hit | miss | extra | deleted
        self.shadow = None          # what the shadow decoder would have typed (its event)

    @property
    def quick(self):
        return self.up.get("held_ms", 0) <= QUICK_MS and self.up.get("travel", 0) <= STILL_PT and not self.slid

    @property
    def point(self):
        return self.down.get("x"), self.down.get("y")


def align(deleted, retyped):
    """Levenshtein alignment: pairs (d, r) with None for a gap."""
    n, m = len(deleted), len(retyped)
    cost = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        cost[i][0] = i
    for j in range(m + 1):
        cost[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            same = deleted[i - 1].lower() == retyped[j - 1].lower()
            cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1, cost[i - 1][j - 1] + (0 if same else 1))
    pairs, i, j = [], n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + (0 if deleted[i - 1].lower() == retyped[j - 1].lower() else 1):
            pairs.append((i - 1, j - 1)); i -= 1; j -= 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            pairs.append((i - 1, None)); i -= 1
        else:
            pairs.append((None, j - 1)); j -= 1
    return list(reversed(pairs))


def label(events):
    """Taps with what they were meant to be, and the taps that never arrived."""
    taps, lost = [], []
    downs, slid = {}, set()
    buffer = []                     # what the field holds since the keyboard came up: Tap or a str
    episode = None                  # {"deleted": [...], "retyped": [...]}
    layout, last_touch, last_up = "russian", None, None

    def finish():
        nonlocal episode
        if not episode or not episode["deleted"] or not episode["retyped"]:
            episode = None
            return
        deleted, retyped = episode["deleted"], episode["retyped"]
        dchars = [d.char if isinstance(d, Tap) else d for d in deleted]
        rchars = [r.char if isinstance(r, Tap) else r for r in retyped]
        pairs = align(dchars, rchars)
        changed = sum(1 for di, ri in pairs if di is None or ri is None or dchars[di].lower() != rchars[ri].lower())
        # A typo fixed changes a letter or two; more is the user rewriting, which says nothing
        # about where their taps went.
        if changed > 2:
            for d in deleted:
                if isinstance(d, Tap):
                    d.fate = "deleted"
            episode = None
            return
        for di, ri in pairs:
            if di is not None and ri is not None:
                d = deleted[di]
                if isinstance(d, Tap):
                    if dchars[di].lower() != rchars[ri].lower() and adjacent(dchars[di], rchars[ri]):
                        d.fate, d.meant = "miss", rchars[ri]
                    else:
                        d.fate = "deleted"
            elif di is not None:
                if isinstance(deleted[di], Tap):
                    deleted[di].fate = "extra"
            elif rchars[ri].isalpha():
                lost.append({"meant": rchars[ri], "after": dchars[:ri] and rchars[ri - 1] if ri else None,
                             "retyped": retyped[ri] if isinstance(retyped[ri], Tap) else None})
        episode = None

    def settled():
        """The retyping has caught up with what was deleted: it ends as that did, or ran two past."""
        if episode is None or not episode["deleted"]:
            return
        deleted, retyped = episode["deleted"], episode["retyped"]
        char = lambda x: (x.char if isinstance(x, Tap) else x).lower()
        if len(retyped) >= len(deleted) and char(retyped[-1]) == char(deleted[-1]) or len(retyped) >= len(deleted) + 2:
            finish()

    for e in events:
        kind = e["e"]
        if kind == "appear":
            finish()
            buffer, downs, slid = [], {}, set()
        elif kind == "layout":
            layout = e.get("to", layout)
        elif kind == "down":
            downs[e.get("touch")] = e
        elif kind == "slide":
            slid.add(e.get("touch"))
        elif kind in ("up", "rollover"):
            last_touch, last_up = e.get("touch"), (e if kind == "up" else None)
        elif kind == "type":
            down = downs.get(last_touch)
            prev = next((b for b in reversed(buffer) if isinstance(b, Tap)), None) if buffer else None
            if prev is not None and down and prev.down and down["t"] - prev.down.get("t", 0) > 1.5:
                prev = None
            tap = Tap(e["char"], down, last_up, last_touch in slid, script(e["char"]), prev)
            # The word this tap went on: the field's text before it, up to the last non-letter.
            before = e.get("before", "")[:-len(e["char"])] if e.get("before", "").endswith(e["char"]) else e.get("before", "")
            tap.word_before = "".join(reversed(list(__import__("itertools").takewhile(str.isalpha, reversed(before)))))
            taps.append(tap)
            buffer.append(tap)
            if episode is not None:
                episode["retyped"].append(tap)
                settled()
        elif kind == "space":
            text = ". " if e.get("period") else " "
            buffer.extend(text)
            if episode is not None:
                episode["retyped"].extend(text)
                settled()
        elif kind in ("delete", "delete-word"):
            count = e.get("chars", 1) if kind == "delete-word" else 1
            for _ in range(count):
                if not buffer:
                    break
                gone = buffer.pop()
                if episode is None:
                    episode = {"deleted": [], "retyped": []}
                if episode["retyped"]:
                    episode["retyped"].pop()
                    if isinstance(gone, Tap):
                        gone.fate = "deleted"
                else:
                    episode["deleted"].insert(0, gone)
        elif kind == "shadow":
            # Comes a moment after its tap: the latest tap from the same touch.
            for tap in reversed(taps[-5:]):
                if tap.down.get("touch") == e.get("touch") and e["t"] - tap.down.get("t", 0) < 2:
                    tap.shadow = e
                    break
        elif kind == "heard":
            finish()
            buffer.extend(e.get("text", ""))
        elif kind == "choose":
            finish()
            for _ in e.get("word", ""):
                if buffer:
                    buffer.pop()
            buffer.extend(e.get("suggestion", "") + " ")

    finish()
    return taps, lost


def known_words():
    """Every word the user has dictated or had Wispr write — their own dictionary, to tell a typo
    left in from a word meant."""
    support = LOG_DIR.parent
    words = set()
    texts = []
    for path in support.glob("dictation/*/session.json"):
        try:
            texts.append(json.loads(path.read_text()).get("text") or "")
        except (OSError, ValueError):
            pass
    for path in support.glob("wispr-flow/history/*/entry.json"):
        try:
            entry = json.loads(path.read_text())
            texts.append(entry.get("editedText") or entry.get("formattedText") or "")
        except (OSError, ValueError):
            pass
    for text in texts:
        words.update(w.lower().replace("ё", "е") for w in __import__("re").findall(r"[а-яёa-z]+", text.lower()))
    return words


def shadow_report(events):
    """The shadow decoder's changes, each judged by how its word ended up: the next words finished
    after it that begin as it did. Ended with the letter it would have picked: it'd have saved a
    typo. Ended with the letter typed, the word otherwise as finished: it'd have broken it — or the
    typo was left in, which the dictionary can tell (an unknown word left is a typo kept)."""
    shadows = [(i, e) for i, e in enumerate(events) if e["e"] == "shadow"]
    if not shadows:
        return
    changed = [(i, e) for i, e in shadows if e["would"] != e["typed"]]
    verdicts = collections.Counter()
    lines = []
    dictionary = known_words()
    for i, e in changed:
        prefix = e["prefix"].lower()
        ended = None
        for later in events[i:i + 400]:
            if later["t"] - e["t"] > 30:
                break
            if later["e"] in ("word", "choose"):
                word = (later.get("word") if later["e"] == "word" else later.get("suggestion", "")).lower()
                if word.startswith(prefix):
                    ended = word
        if ended is None:
            verdict = "unknown"
        elif ended.startswith(prefix + e["would"].lower()):
            verdict = "saves"
        elif ended.replace("ё", "е") not in dictionary:
            verdict = "saves (typo left in)"
        else:
            verdict = "BREAKS"
        verdicts[verdict] += 1
        lines.append(f"  {verdict:<20} {e['prefix']}[{e['typed']}→{e['would']}] → ended as «{ended}»  "
                     f"gap {e['gap']} dictionary {e['typed_n']} vs {e['other_n']}")
    print(f"\nshadow decoder: judged {len(shadows)} taps within 9 pt of another letter (not a word's first), "
          f"would change {len(changed)}: " + ", ".join(f"{k} {v}" for k, v in verdicts.items()))
    print("\n".join(lines))


def cursor_report(events):
    """Moves up and down on the space-bar trackpad: how far from where the user settled (after
    nudging sideways) each way of finding the line above or below would have left the cursor."""
    moves = [e for e in events if e["e"] == "cursor-move"]
    if not moves:
        return
    print(f"\ncursor moves up/down: {len(moves)} — characters off from where you settled (mean, exact hits):")
    for key, name in (("rule", "40-character rule"), ("model_guess", "line model, guessed width"),
                      ("model_learned", "line model, learned width (shadow, before it moved the cursor)"),
                      ("model_used", "line model as used, learned width")):
        misses = [abs(e[key] - e["settled"]) for e in moves if e.get(key, -1) >= 0]
        if misses:
            print(f"  {name:<28} {statistics.mean(misses):5.1f}   {sum(m == 0 for m in misses)}/{len(misses)}")
    widths = [e.get("next_width") for e in moves if e.get("next_width", -1) > 0]
    if widths:
        print(f"  learned width now {widths[-1]} pt (guess {moves[-1].get('guess_width')}, font {moves[-1].get('font_size')} pt)")


def report(events):
    taps, lost = label(events)
    letters = [t for t in taps if t.key.isalpha() and t.layout]
    hits = [t for t in letters if t.fate == "hit"]
    misses = [t for t in letters if t.fate == "miss"]
    extras = [t for t in letters if t.fate == "extra"]
    days = sorted({__import__("datetime").datetime.fromtimestamp(e["t"]).strftime("%Y-%m-%d") for e in events})
    print(f"{len(events)} events, {days[0]} … {days[-1]}" if days else "no events")
    print(f"letters tapped: {len(letters)} — hits {len(hits)}, misses {len(misses)}, extra {len(extras)}, "
          f"lost (never typed) {len(lost)}")
    if not letters:
        return

    gap = [t for t in letters if t.down and t.down.get("key_inside") is False]
    print(f"taps between keys: {len(gap)} ({len(gap) / len(letters):.0%}); "
          f"of them misses {sum(t.fate == 'miss' for t in gap)}")

    quick = [t for t in letters if t.quick]
    print(f"quick taps: {len(quick)} ({len(quick) / len(letters):.0%}); misses among quick "
          f"{sum(t.fate == 'miss' for t in quick)}, among deliberate {sum(t.fate == 'miss' for t in letters if not t.quick)}")

    print("\nmisses — typed → meant, where the finger came down against both keys:")
    for t in misses:
        keys = layout_keys(t.layout)
        x, y = t.point
        meant = t.meant.lower()
        line = f"  {t.char} → {t.meant}"
        if x is not None and meant in keys and t.key in keys:
            (mx, my), (tx, ty) = centre(keys[meant]), centre(keys[t.key])
            line += (f"  off typed ({x - tx:+5.1f},{y - ty:+5.1f})  off meant ({x - mx:+5.1f},{y - my:+5.1f})"
                     f"  held {t.up.get('held_ms', '?')} ms  travel {t.up.get('travel', '?')}"
                     f"{'  slid' if t.slid else ''}{'  quick' if t.quick else ''}"
                     f"{'  after ' + t.prev.char if t.prev else ''}")
        print(line)

    if lost:
        print("\nlost taps — a letter that never typed:")
        print("  " + ", ".join(f"{l['meant']}" + (f" (after {l['after']})" if l['after'] else "") for l in lost))

    print("\nwhere you touch each key (hits): mean offset from its centre, pt — n ≥ 5")
    by_key = collections.defaultdict(list)
    for t in hits:
        keys = layout_keys(t.layout)
        x, y = t.point
        if x is None or t.key not in keys:
            continue
        cx, cy = centre(keys[t.key])
        by_key[t.key].append((x - cx, y - cy))
    rows = []
    for key, offsets in sorted(by_key.items(), key=lambda kv: -len(kv[1])):
        if len(offsets) < 5:
            continue
        dx = statistics.mean(o[0] for o in offsets)
        dy = statistics.mean(o[1] for o in offsets)
        spread = statistics.pstdev([math.hypot(*o) for o in offsets])
        rows.append(f"{key} n={len(offsets):<3} ({dx:+5.1f},{dy:+5.1f}) ±{spread:4.1f}")
    for i in range(0, len(rows), 3):
        print("  " + "    ".join(rows[i:i + 3]))

    all_dx = [o[0] for v in by_key.values() for o in v]
    all_dy = [o[1] for v in by_key.values() for o in v]
    if all_dx:
        print(f"  overall ({statistics.mean(all_dx):+.1f},{statistics.mean(all_dy):+.1f}) over {len(all_dx)} hits")

    shadow_report(events)
    cursor_report(events)

    transitions = collections.Counter((t.prev.key, t.key) for t in misses if t.prev)
    if transitions:
        print("\nmisses by the tap before (prev → typed):")
        print("  " + ", ".join(f"{a}→{b}×{n}" for (a, b), n in transitions.most_common(20)))


if __name__ == "__main__":
    directory = Path(sys.argv[1]) if len(sys.argv) > 1 else LOG_DIR
    report(load(directory))
