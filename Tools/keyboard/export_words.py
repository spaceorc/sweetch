#!/usr/bin/env python3
"""Words typed on the iPhone keyboard, as the taps that typed them and the word they became —
the test set for the decoder (Tools/keyboard/replay).

From the keyboard's log, each finished word becomes one example:
- "clean": typed and left as it was — the taps meant exactly that word;
- "fixed": typed, then put right (letters deleted and retyped, or a suggestion picked) — the
  first attempt's taps, and the word it became, which is what they meant. Rewrites (more than
  two letters changed) are left out: the user changed their mind, not their taps.

Each tap carries where it came down, which layout it was on, and whether it was deliberate (held,
slid, or picked from the alternates). Key frames for each layout come along.

Usage: Tools/keyboard/export_words.py [out.json]
"""

import importlib.util
import datetime
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("analyse", HERE / "analyse.py")
analyse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyse)


def damerau(a, b):
    d = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1):
        d[i][0] = i
    for j in range(len(b) + 1):
        d[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[-1][-1]


def examples(events):
    out = []
    buffer = []          # dicts for taps, plain strings for anything else
    attempts = {}        # word start → its taps when it was first changed
    finished = {}        # word start → example
    downs, deliberate = {}, set()
    last_touch, last_up = None, None

    def word_start():
        i = len(buffer)
        while i > 0 and isinstance(buffer[i - 1], dict):
            i -= 1
        return i

    def previous_word(start, text=None):
        """The word before the one at `start`, and whether a sentence starts there."""
        if text is None:
            text = "".join(t["char"] if isinstance(t, dict) else t for t in buffer[:start])
        i = len(text)
        while i > 0 and not (text[i - 1].isalpha() or text[i - 1].isdigit()):
            i -= 1
        gap = text[i:]
        if i == 0 or any(c in ".!?…\n" for c in gap):
            return None, True
        j = i
        while j > 0 and (text[j - 1].isalpha() or text[j - 1] in "'’-"):
            j -= 1
        return text[j:i], False

    def context_of(start):
        """The word before the one at `start`, whether a sentence starts there, and the word
        before that (previous2_start: a sentence starts before the previous word)."""
        text = "".join(t["char"] if isinstance(t, dict) else t for t in buffer[:start])
        previous, sentence_start = previous_word(start, text)
        previous2, previous2_start = None, False
        if previous is not None:
            i = len(text)
            while i > 0 and not (text[i - 1].isalpha() or text[i - 1].isdigit()):
                i -= 1
            previous2, previous2_start = previous_word(start, text[:i - len(previous)])
        return {"previous": previous, "sentence_start": sentence_start, "previous2": previous2, "previous2_start": previous2_start}

    def finish():
        start = word_start()
        letters = buffer[start:]
        if not letters:
            return
        ctx = context_of(start)
        truth = "".join(t["char"] for t in letters)
        taps = attempts.pop(start, None)
        if taps is None:
            finished[start] = {"kind": "clean", "taps": letters, "truth": truth, **ctx}
        else:
            literal = "".join(t["char"] for t in taps)
            if literal.lower() == truth.lower():
                finished[start] = {"kind": "clean", "taps": letters, "truth": truth, **ctx}
            elif damerau(literal.lower(), truth.lower()) <= 2:
                finished[start] = {"kind": "fixed", "taps": taps, "truth": truth, **ctx}

    def flush():
        finish()
        # Each word's next word in the text as it ended up (none past a sentence's end), and whether
        # it was typed fast — taps under 0.35 s apart, the median.
        for start, example in finished.items():
            end = start
            while end < len(buffer) and isinstance(buffer[end], dict):
                end += 1
            after = "".join(t["char"] if isinstance(t, dict) else t for t in buffer[end:])
            stripped = after.lstrip(" ")
            word = ""
            if stripped[:1].isalpha() and after[:1] == " ":
                for c in stripped:
                    if not (c.isalpha() or c in "'’-"):
                        break
                    word += c
            example["next"] = word or None
            times = [t.get("t") for t in example["taps"] if isinstance(t, dict) and t.get("t")]
            gaps = sorted(b - a for a, b in zip(times, times[1:]))
            example["fast"] = bool(gaps) and gaps[len(gaps) // 2] < 0.35
        out.extend(finished.values())
        finished.clear()
        attempts.clear()
        buffer.clear()

    def delete():
        if not buffer:
            return
        start = word_start()
        if isinstance(buffer[-1], dict):
            attempts.setdefault(start, [t for t in buffer[start:]])
            buffer.pop()
        else:
            buffer.pop()
            # Back into the word before: it's being changed after all.
            start = word_start()
            if start in finished:
                example = finished.pop(start)
                attempts.setdefault(start, example["taps"] if example["kind"] == "clean" else example["taps"])

    picked = None        # the start of a word just picked from the strip, while nothing else was done
    for e in events:
        kind = e["e"]
        # A picked word deleted into straight away was picked for being nearly right («синтетически»
        # → «синтетические»): it isn't what the taps meant — the word as it ends up is.
        if kind in ("delete", "delete-word", "suggestion-edited") and picked is not None:
            finished.pop(picked, None)
        if kind not in ("choose", "word", "suggestions", "decoder", "shadow", "raw", "gesture", "up", "down", "keys", "status"):
            picked = None
        if kind == "appear":
            flush()
        elif kind == "down":
            downs[e.get("touch")] = e
        elif kind in ("slide", "alternates-shown"):
            deliberate.add(e.get("touch"))
        elif kind in ("up", "rollover"):
            last_touch, last_up = e.get("touch"), e if kind == "up" else None
        elif kind == "type":
            char = e["char"]
            if char.isalpha():
                down = downs.get(last_touch) or {}
                layout = analyse.script(char)
                if down.get("x") is None or layout is None:
                    buffer.append(char)
                    continue
                held = (last_up or {}).get("held_ms", 0)
                buffer.append({"char": char, "x": down["x"], "y": down["y"], "layout": layout,
                               "deliberate": last_touch in deliberate or held > 350, "t": down.get("t")})
            else:
                finish()
                if e.get("before_our_space") and buffer and buffer[-1] == " ":
                    buffer.pop()
                    buffer.extend(char + " ")
                else:
                    buffer.append(char)
        elif kind == "space":
            finish()
            if e.get("absorbed"):
                continue   # stood for the space a picked suggestion had put there already
            if e.get("period"):
                if buffer and buffer[-1] == " ":
                    buffer.pop()
                buffer.extend(". ")
            else:
                buffer.append(" ")
        elif kind == "return":
            finish()
            buffer.append("\n")
        elif kind == "delete":
            delete()
        elif kind == "delete-word":
            for _ in range(e.get("chars", 1)):
                delete()
        elif kind == "choose":
            start = word_start()
            attempts.setdefault(start, [t for t in buffer[start:]])
            for _ in e.get("word", ""):
                if buffer:
                    buffer.pop()
            taps = attempts.pop(start, None)
            if taps and damerau("".join(t["char"] for t in taps).lower(), e["suggestion"].lower()) <= 2:
                ctx = context_of(start)
                finished[start] = {"kind": "fixed", "taps": taps, "truth": e["suggestion"], **ctx}
            picked = start
            buffer.extend(e.get("suggestion", "") + " ")
        elif kind in ("heard", "autofix"):
            finish()
            buffer.extend(e.get("text") or e.get("fixed") or "")
    flush()
    return out


def valid_words():
    """A check of whether a word is one, independent of the keyboard's lexicon: OpenCorpora (via
    pymorphy3, when this runs in a Python that has it), the English word list, and every word the
    user ever dictated. Nil without pymorphy3."""
    try:
        import pymorphy3
    except ImportError:
        return None
    morph = pymorphy3.MorphAnalyzer()
    english = set()
    english_list = Path.home() / "Library/Caches/sweetch/lexicon/en.combined"
    if english_list.exists():
        for line in english_list.open(encoding="utf-8"):
            if line.startswith(" word="):
                english.add(line[6:].rsplit(",f=", 1)[0].lower())
    builder_spec = importlib.util.spec_from_file_location("build_lexicon", HERE / "build_lexicon.py")
    builder = importlib.util.module_from_spec(builder_spec)
    builder_spec.loader.exec_module(builder)
    counts, _, typed = builder.personal_words()
    said = {k for k, n in counts.items() if n - typed[k] > 0}
    return lambda w: (w := w.lower()) in english or w in said or morph.word_is_known(w)


def main():
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/keyboard-words.json")
    events = analyse.load(analyse.LOG_DIR)
    # `SWEETCH_SINCE=YYYY-MM-DD`: only the words typed from that day — the bench's test days, with a
    # lexicon built from the days before (SWEETCH_UNTIL).
    since = os.environ.get("SWEETCH_SINCE")
    if since:
        start = datetime.datetime.strptime(since, "%Y-%m-%d").timestamp()
        events = [e for e in events if e.get("t", 0) >= start]
    words = examples(events)
    is_word = valid_words()
    for w in words:
        literal = "".join(t["char"] for t in w["taps"])
        w["typed_is_word"] = is_word(literal) if is_word else None
    layouts = {name: [[letter, *frame] for letter, frame in analyse.layout_keys(name).items()] for name in analyse.ROWS}
    target.write_text(json.dumps({"layouts": layouts, "words": words}, ensure_ascii=False))
    kinds = {}
    for w in words:
        kinds[w["kind"]] = kinds.get(w["kind"], 0) + 1
    print(f"{target}: {len(words)} words — {kinds}")


if __name__ == "__main__":
    main()
