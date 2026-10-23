#!/usr/bin/env python3
"""What a word of a dictation could be instead — and, on the user's own corrections, how often the
word they put in its place would have been offered.

A dictated word clicked in the field (the idea, 23 Oct): a menu of what else it might be. Where
those come from:
- heard: the other listenings of the same recording (sweetch hears each several ways);
- latin: written in Latin — transliterated, and the nearest English word or the user's own
  («банкинг» → banking, «инвойсис» → invoices);
- yours: the user's own words that sound alike («Jam» → Gemma, «линкер» → линтер);
- forms: other forms of the same Russian word («перезапуская» → перезапускай);
- joined: two words as code writes them («bank accounts» → bank_accounts, ubuntu-latest).

Usage: Tools/dictation/alternatives.py [--verbose]   (the venv's Python: pymorphy3)
The corrections are taken from each dictation's follow-up: a word or two of what was typed,
replaced in the field by hand.
"""
import collections
import difflib
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DICTATIONS = Path.home() / "Library/Application Support/sweetch/dictation"
EN_LIST = Path.home() / "Library/Caches/sweetch/lexicon/en.combined"
WORD = re.compile(r"[\w'-]+")

TRANSLIT = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
                    ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t",
                     "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))


def words(text):
    return WORD.findall(text or "")


def corrections():
    """(the dictation's folder, the words replaced, what replaced them, the text before them)."""
    out = []
    for folder in sorted(DICTATIONS.iterdir()):
        try:
            session = json.loads((folder / "session.json").read_text())
            follow = json.loads((folder / "followup.json").read_text())
        except (OSError, ValueError):
            continue
        if session.get("handoff"):
            continue
        typed = session.get("inserted") or session.get("text")
        after, final = follow.get("field_after_insert"), follow.get("field_final")
        if not typed or after is None or final is None:
            continue
        a, b = words(after), words(final)
        dictated = {w.lower() for w in words(typed)}
        matcher = difflib.SequenceMatcher(a=[w.lower() for w in a], b=[w.lower() for w in b], autojunk=False)
        for op, i1, i2, j1, j2 in matcher.get_opcodes():
            if op == "replace" and i2 - i1 <= 2 and j2 - j1 <= 2:
                old = a[i1:i2]
                if any(w.lower() in dictated for w in old):
                    out.append((folder, old, b[j1:j2], a[max(0, i1 - 3):i1]))
    return out


def translit(word):
    return "".join(TRANSLIT.get(c, c) for c in word.lower())


def sound(word):
    """A rough key for how a word sounds, Latin or Cyrillic: transliterated, the vowels and the
    doubled letters made alike."""
    s = translit(word)
    s = re.sub(r"(.)\1+", r"\1", s)
    s = re.sub(r"[aeiouy]+", "a", s)
    return s.replace("dzh", "g").replace("zh", "g").replace("j", "g").replace("ph", "f").replace("ck", "k").replace("c", "k")


def main():
    verbose = "--verbose" in sys.argv
    spec = importlib.util.spec_from_file_location("build_lexicon", HERE.parent / "keyboard/build_lexicon.py")
    lexicon = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lexicon)
    counts, spellings, _ = lexicon.personal_words()
    yours = {spellings[k].most_common(1)[0][0]: n for k, n in counts.items() if n >= 3 and len(k) >= 2}
    english = {}
    for line in EN_LIST.open(encoding="utf-8"):
        if line.startswith(" word="):
            w, f = line[6:].split(",f=", 1)
            f = f.split(",", 1)[0].strip()
            if int(f) >= 60 and w.isalpha():
                english[w.lower()] = int(f)
    by_sound = collections.defaultdict(list)
    for w, n in yours.items():
        by_sound[sound(w)].append((n, w))
    import pymorphy3
    morph = pymorphy3.MorphAnalyzer()

    ru_frequency = {}
    for line in (EN_LIST.parent / "ru.combined").open(encoding="utf-8"):
        if line.startswith(" word="):
            w, f = line[6:].split(",f=", 1)
            ru_frequency[w.lower()] = int(f.split(",", 1)[0].strip())

    def aligned(typed, at, n, other):
        """What `other` (a listening's words) has where `typed` has its words at..at+n."""
        matcher = difflib.SequenceMatcher(a=[w.lower() for w in typed], b=[w.lower() for w in other], autojunk=False)
        span = []
        for op, i1, i2, j1, j2 in matcher.get_opcodes():
            if i2 <= at or i1 >= at + n:
                continue
            if op == "equal":
                span += other[j1 + max(0, at - i1):j1 + min(i2, at + n) - i1]
            else:
                span += other[j1:j2]
        return " ".join(span)

    def offers(folder, old):
        """Each source's offers for the words `old`, likeliest first — never `old` itself."""
        session = json.loads((folder / "session.json").read_text())
        joined = " ".join(old)
        typed = words(session.get("inserted") or session.get("text"))
        lowered = [w.lower() for w in typed]
        at = next((i for i in range(len(typed)) if lowered[i:i + len(old)] == [o.lower() for o in old]), None)
        found = {}
        # What the other listenings heard in the same place.
        heard = []
        if at is not None:
            for listening in session.get("listenings", []) + [{"text": v} for v in session.get("versions") or []]:
                span = aligned(typed, at, len(old), words(listening.get("text", "")))
                if span and len(span.split()) <= len(old) + 1:
                    heard.append(span)
        found["heard"] = list(dict.fromkeys(heard))
        latin = []
        if re.search("[а-яё]", joined.lower()):
            t = translit(joined).replace(" ", "")
            near = difflib.get_close_matches(t, list(english) + [w.lower() for w in yours if w.isascii()], n=3, cutoff=0.7)
            latin += near + [t]
        found["latin"] = latin
        key = sound(joined)
        close = difflib.get_close_matches(key, list(by_sound), n=6, cutoff=0.75)
        found["yours"] = [w for k in close for _, w in sorted(by_sound[k], reverse=True)]
        forms = []
        if len(old) == 1 and re.search("[а-яё]", old[0].lower()):
            for f in morph.parse(old[0])[0].lexeme:
                forms.append(f.word)
        found["forms"] = sorted(dict.fromkeys(forms), key=lambda w: -(ru_frequency.get(w, 0) + 10 * counts.get(w, 0)))
        if len(old) == 2:
            a, b = (w.lower().replace("-", "") for w in old)
            found["joined"] = [a + b, a + "_" + b, a + "-" + b]
        else:
            found["joined"] = []
        drop = joined.lower()
        return {k: [w for w in dict.fromkeys(v) if w.lower() != drop] for k, v in found.items()}

    fixes = corrections()
    hits = collections.Counter()
    top5 = 0
    sizes = []
    lines = []
    for folder, old, new, _ in fixes:
        target = " ".join(new).lower()
        found = offers(folder, old)
        which = [source for source, items in found.items() if target in [i.lower() for i in items]]
        for source in which:
            hits[source] += 1
        # The menu: heard first, then yours, latin, joined, forms — five at most.
        menu = []
        for source, take in (("heard", 2), ("yours", 2), ("latin", 1), ("joined", 2), ("forms", 2), ("latin", 2), ("yours", 4), ("forms", 5)):
            for w in found[source][:take]:
                if w.lower() not in [m.lower() for m in menu] and len(menu) < 5:
                    menu.append(w)
        sizes.append(len(menu))
        in_menu = target in [m.lower() for m in menu]
        top5 += in_menu
        lines.append(f"  {'MENU ' if in_menu else ('ANY  ' if which else '     ')}{' '.join(old)} → {' '.join(new)}"
                     f"  [{', '.join(which) or '-'}]  menu: {menu}")
    n = len(fixes)
    anywhere = sum(1 for l in lines if l.startswith("  MENU") or l.startswith("  ANY"))
    print(f"{n} words replaced by hand in dictations: the new one offered by some source {anywhere} "
          f"({100 * anywhere // max(n, 1)}%), in a menu of five {top5} ({100 * top5 // max(n, 1)}%)")
    print("by source:", dict(hits.most_common()))
    print(f"menu length: {sum(sizes) / max(len(sizes), 1):.1f} on average")
    if verbose:
        print("\n".join(lines))


if __name__ == "__main__":
    main()
