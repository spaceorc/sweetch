#!/usr/bin/env python3
"""Words typed on the Mac, as the keys that typed them and the word they became — the Mac's test
set for the decoder (Tools/keyboard/replay), in the iPhone export's shape (export_words.py).

From the Mac's typing log (TypingLog.swift: typing/<day>-<host>.jsonl) the text is followed key by
key, as far as it can be — a click, an arrow, a shortcut, another app lose the place — and each
finished word becomes one example:
- "clean": typed and left as it was;
- "fixed": typed, then put right by deleting and retyping one or two letters — the first attempt's
  keys, and the word it became;
- "layout": typed in the wrong layout and put right — retyped in the other one, or converted with
  sweetch's ⌥Space — the keys, and the word in the other layout.
Rewrites are left out: the user changed their mind, not their keys.

A key becomes a tap in the middle of its key on a Mac keyboard's grid (ANSI, 40 pt keys, rows
staggered as drawn), both layouts on the same grid: the letter each key types in each layout is
read from the log itself.

Usage: Tools/keyboard/export_mac_words.py [out.json]
"""
import collections
import datetime
import glob
import importlib.util
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOG = Path.home() / "Library/Application Support/sweetch/typing"

# Mac key codes by row, left to right (ANSI), and where each row starts, in key widths.
ROWS = [
    (0.0, [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]),
    (1.5, [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),
    (1.75, [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]),
    (2.25, [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]),
]
KEY = 40.0
GEOMETRY = {code: ((start + i) * KEY, row * KEY) for row, (start, codes) in enumerate(ROWS) for i, code in enumerate(codes)}
CODE_AT = {(x + KEY / 2, y + KEY / 2): code for code, (x, y) in GEOMETRY.items()}
LAYOUTS = ("en", "ru")
BACKSPACE, SPACE = 51, 49
LOSE_PLACE = {123, 124, 125, 126, 115, 116, 119, 121, 36, 76, 48, 53}   # arrows, home/end/page, return, tab, escape

spec = importlib.util.spec_from_file_location("export_words", HERE / "export_words.py")
phone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phone)


def events():
    out = []
    since = os.environ.get("SWEETCH_SINCE")
    start = datetime.datetime.strptime(since, "%Y-%m-%d").timestamp() if since else 0
    for path in sorted(glob.glob(str(LOG / "*.jsonl"))):
        for line in open(path, encoding="utf-8"):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("t", 0) >= start:
                out.append(e)
    out.sort(key=lambda e: e["t"])
    return out


def cyrillic(c):
    return "а" <= c.lower() <= "я" or c.lower() == "ё"


def letters_by_key(evs):
    """(key code, layout) → the letter it types there, lower case — the commonest seen where the
    letter's script and the layout agree."""
    seen = collections.defaultdict(collections.Counter)
    for e in evs:
        c = e.get("c", "")
        if e.get("e") == "d" and len(c) == 1 and c.isalpha() and cyrillic(c) == (e.get("l") == "ru") \
                and "⌘" not in e.get("m", "") and "⌥" not in e.get("m", ""):
            seen[(e["k"], e.get("l"))][c.lower()] += 1
    return {key: counts.most_common(1)[0][0] for key, counts in seen.items() if key[0] in GEOMETRY}


def examples(evs, letters):
    buf = []            # (char, key code, layout)
    times = []          # when each of buf was typed
    session = 0         # one go of typing: a new one each time the place is lost
    finished = {}       # start index in buf → example, until the place is lost
    out = []
    pending = None      # a deletion under way: (the word's keys before it, its start)

    def tap(c, code, layout):
        x, y = GEOMETRY[code]
        return {"char": c, "x": x + KEY / 2, "y": y + KEY / 2, "layout": layout, "deliberate": False}

    def word_start(upto=None):
        i = len(buf) if upto is None else upto
        while i > 0 and (buf[i - 1][0].isalpha() or buf[i - 1][0] in "-'"):
            i -= 1
        return i

    def context_of(start):
        text = "".join(c for c, _, _ in buf[:start])
        return phone_context(text)

    def flush():
        nonlocal finished
        out.extend(finished[k] for k in sorted(finished))
        finished = {}

    def when(start, n):
        """When the word at `start`, `n` keys long, began and ended, and its go."""
        return {"t0": times[start], "t1": times[min(start + n, len(times)) - 1], "session": session}

    def lose_place():
        nonlocal buf, times, session, pending
        close()
        flush()
        buf, times = [], []
        session += 1

    def finish():
        start = word_start()
        word = buf[start:]
        if start in finished:
            return   # put right on the way: the attempt is the example
        # One letter too: «z» for «я», «b» for «и» are what stays behind when the word after
        # them is switched to the other layout alone.
        if len(word) >= 1 and all(code in GEOMETRY for _, code, _ in word) and len({l for _, _, l in word}) == 1:
            finished[start] = {"kind": "clean", "taps": [tap(*k) for k in word], "truth": "".join(c for c, _, _ in word),
                               **context_of(start), **when(start, len(word))}

    def close():
        nonlocal pending
        if pending is None:
            return
        before, start, before_times = pending
        pending = None
        after = buf[word_start():]
        if len(before) < 2 or not after or any(code not in GEOMETRY for _, code, _ in before):
            return
        wb = "".join(c for c, _, _ in before)
        wa = "".join(c for c, _, _ in after)
        if not wa.replace("-", "").replace("'", "").isalpha() or len({l for _, _, l in before}) != 1:
            return
        if wb.lower() == wa.lower():
            return
        if before[0][2] != after[0][2] and [k for _, k, _ in before] == [k for _, k, _ in after]:
            kind = "layout"
        elif before[0][2] == after[0][2] and phone.damerau(wb.lower(), wa.lower()) <= 2:
            kind = "fixed"
        else:
            return
        finished[start] = {"kind": kind, "taps": [tap(*k) for k in before], "truth": wa, **context_of(start),
                           "t0": before_times[0], "t1": before_times[-1], "session": session}

    def delete():
        """One letter deleted: a word it reaches is being put right (or rewritten), no longer as typed."""
        nonlocal pending
        if not buf:
            return
        if pending is None:
            start = word_start()
            if start == len(buf):   # a space or a mark first: the word before it
                end = len(buf)
                while end > 0 and not buf[end - 1][0].isalpha():
                    end -= 1
                start = word_start(end)
                pending = (list(buf[start:end]), start, list(times[start:end]))
            else:
                pending = (list(buf[start:]), start, list(times[start:]))
        at = len(buf) - 1
        for s in [s for s, ex in finished.items() if s + len(ex["taps"]) > at]:
            del finished[s]
        buf.pop()
        times.pop()

    for e in evs:
        kind = e.get("e")
        if kind == "switch":
            continue
        if kind == "convert":
            # ⌥Space: the last word, typed in the wrong layout, now in the other.
            close()
            end = len(buf)
            while end > 0 and not buf[end - 1][0].isalpha():
                end -= 1
            start = word_start(end)
            word = buf[start:end]
            if len(word) >= 2 and all(code in GEOMETRY for _, code, _ in word) and len({l for _, _, l in word}) == 1:
                layout = word[0][2]
                other = "ru" if layout == "en" else "en"
                converted = [(letters.get((code, other)), code, other) for _, code, _ in word]
                if all(c for c, _, _ in converted):
                    truth = "".join(c.upper() if o.isupper() else c for (c, _, _), (o, _, _) in zip(converted, word))
                    finished[start] = {"kind": "layout", "taps": [tap(*k) for k in word], "truth": truth,
                                       **context_of(start), **when(start, len(word))}
            lose_place()
            continue
        if kind in ("app", "click", "private", "private-end"):
            lose_place()
            continue
        if kind == "u" and e.get("k") == BACKSPACE and e.get("r"):
            for _ in range(e["r"]):
                delete()
            continue
        if kind != "d":
            continue
        code, c, mods, layout = e.get("k"), e.get("c", ""), e.get("m", ""), e.get("l")
        # The letter as the layout types it: the event's character was often the layout's before
        # the last switch (logged «ckjvfkfcm» where «сломалась» was sent, 19 Oct) — the log's own
        # fix (its "cx") came later.
        if len(c) == 1 and c.isalpha() and cyrillic(c) != (layout == "ru") and (code, layout) in letters:
            right = letters[(code, layout)]
            c = right.upper() if c.isupper() else right
        repeat = e.get("r") == 1        # the old log's autorepeat lines
        if code == SPACE and "⌘" in mods:
            continue                    # ⌘Space switches the layout
        if code == SPACE and repeat:
            lose_place()                # Space held: a dictation goes in
            continue
        if "⌘" in mods or "⌃" in mods or code in LOSE_PLACE or (code == BACKSPACE and "⌥" in mods):
            if code in (36, 76):
                finish()
            lose_place()
            continue
        if code == BACKSPACE:
            delete()
            continue
        if repeat or len(c) != 1 or not c.isprintable():
            continue
        if not (c.isalpha() or c in "-'"):
            close()
            finish()
        buf.append((c, code, layout))
        times.append(e["t"])
    lose_place()
    return out


def phone_context(text):
    """The word before, whether a sentence starts there, and the word before that."""
    def previous_word(text):
        i = len(text)
        while i > 0 and not (text[i - 1].isalpha() or text[i - 1].isdigit()):
            i -= 1
        gap = text[i:]
        if i == 0 or any(c in ".!?…\n" for c in gap):
            return None, True, i
        j = i
        while j > 0 and (text[j - 1].isalpha() or text[j - 1] in "'’-"):
            j -= 1
        return text[j:i], False, j
    previous, start, j = previous_word(text)
    previous2, start2 = None, False
    if previous is not None:
        previous2, start2, _ = previous_word(text[:j])
    return {"previous": previous, "sentence_start": start, "previous2": previous2, "previous2_start": start2}


def main():
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/mac-words.json")
    evs = events()
    letters = letters_by_key(evs)
    words = examples(evs, letters)
    is_word = phone.valid_words()
    kept = []
    for w in words:
        literal = "".join(t["char"] for t in w["taps"])
        w["typed_is_word"] = is_word(literal) if is_word else None
        if w["kind"] != "clean":
            # What it became must be a word: a ⌥Space pressed by mistake and taken back, or a word
            # left half-typed, is no example of what the keys meant.
            if not is_word or literal.lower() == w["truth"].lower() or not is_word(w["truth"]):
                continue
        elif is_word and not w["typed_is_word"]:
            # Left as typed but no word — and a word in the other layout: typed in the wrong one
            # and never put right (sent as it was, or retyped elsewhere). Marked, not counted as
            # the user's choice.
            other = "ru" if w["taps"][0]["layout"] == "en" else "en"
            converted = "".join(letters.get((CODE_AT[(t["x"], t["y"])], other), "?") for t in w["taps"])
            if "?" not in converted and is_word(converted):
                w["kind"], w["truth"] = "layout-left", converted
        kept.append(w)
    words = kept
    layouts = {layout: [[letter, GEOMETRY[code][0], GEOMETRY[code][1], KEY, KEY]
                        for (code, l), letter in sorted(letters.items()) if l == layout] for layout in LAYOUTS}
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({"layouts": layouts, "words": words}, ensure_ascii=False))
    kinds = collections.Counter(w["kind"] for w in words)
    print(f"{target}: {len(words)} words — {dict(kinds)}")


if __name__ == "__main__":
    main()
