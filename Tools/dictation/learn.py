#!/usr/bin/env python3
"""What the user's corrections of dictations teach: pairs of what the recognisers heard and what the
user made of it — words of a dictation replaced by hand in the field (each follow-up) and words
picked from the word menu (corrections.jsonl) — the mishearings among them (alike in sound:
«Jam» → Gemma, not «Ну» → кому), gathered into what the settling model can be told.

  learn.py --pairs                  the pairs and what they add up to
  learn.py --cases out.json         each settled dictation with what had been learned before it,
                                    for `sweetch --learn-probe` (does telling the model help?)
  learn.py --score probe.json       how far each settling is from what the user left
  learn.py --learned out.txt        what's learned from everything, as the model is told it
"""
import collections
import difflib
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("alternatives", HERE / "alternatives.py")
alt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alt)
DICTATIONS = alt.DICTATIONS


def alike(a, b):
    """How alike two texts sound, 0…1."""
    return difflib.SequenceMatcher(a=alt.sound(a), b=alt.sound(b)).ratio()


def pairs():
    """(when, heard, corrected, how) for every correction that sounds like what was heard."""
    out = []
    for folder, old, new, _ in alt.corrections():
        heard, fixed = " ".join(old), " ".join(new)
        if alike(heard, fixed) >= 0.5:
            out.append((folder.name, heard, fixed, "by hand"))
    for path in DICTATIONS.glob("*/corrections.jsonl"):
        for line in path.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            out.append((path.parent.name, r.get("heard", ""), r.get("chosen", ""), "menu"))
    return sorted(out)


def relevant(ps, versions):
    """The pairs whose heard words sound like something in these versions: a run of one or two of
    their words alike (0.85) — what bears on this dictation, not all that's learned."""
    spans = set()
    for v in versions:
        ws = alt.words(v)
        spans |= {w.lower() for w in ws} | {" ".join(ws[i:i + 2]).lower() for i in range(len(ws) - 1)}
    keys = {alt.sound(s): s for s in spans}
    out = []
    for p in ps:
        k = alt.sound(p[1])
        if len(k) >= 2 and any(difflib.SequenceMatcher(a=k, b=key).ratio() >= 0.85 for key in keys):
            out.append(p)
    return out


def learned_text(ps):
    """What's learned, as the model is told it: each word the user means, with what was heard for it."""
    by_word = collections.defaultdict(collections.Counter)
    for _, heard, fixed, _ in ps:
        by_word[fixed][heard] += 1
    lines = []
    for fixed, heard in sorted(by_word.items(), key=lambda x: -sum(x[1].values())):
        lines.append(f"«{fixed}» — heard as " + ", ".join(f"«{h}»" for h, _ in heard.most_common(4)))
    return "\n".join(lines)


def truth(folder):
    """The dictation as the user left it: its words, with the replacements made by hand."""
    session = json.loads((folder / "session.json").read_text())
    follow = json.loads((folder / "followup.json").read_text())
    typed = session.get("inserted") or session.get("text") or ""
    after, final = follow.get("field_after_insert"), follow.get("field_final")
    a, b = alt.words(after), alt.words(final)
    tw = [w.lower() for w in alt.words(typed)]
    m = difflib.SequenceMatcher(a=[w.lower() for w in a], b=[w.lower() for w in b], autojunk=False)
    out = list(alt.words(typed))
    # Each small replacement inside the dictation, applied to its words.
    for op, i1, i2, j1, j2 in m.get_opcodes():
        if op == "replace" and i2 - i1 <= 2 and j2 - j1 <= 2:
            old = [w.lower() for w in a[i1:i2]]
            for k in range(len(tw) - len(old) + 1):
                if tw[k:k + len(old)] == old:
                    out[k:k + len(old)] = b[j1:j2]
                    tw[k:k + len(old)] = [w.lower() for w in b[j1:j2]]
                    break
    return " ".join(out)


def cases(path):
    ps = pairs()
    out = []
    for folder in sorted(DICTATIONS.iterdir()):
        try:
            session = json.loads((folder / "session.json").read_text())
            json.loads((folder / "followup.json").read_text())
        except (OSError, ValueError):
            continue
        if session.get("handoff") or not (session.get("settlement") or {}).get("input"):
            continue
        before = [p for p in ps if p[0] < folder.name]
        versions = session.get("versions") or [session.get("text") or ""]
        bearing = relevant(before, versions)
        out.append({"dir": str(folder), "learned": learned_text(bearing), "truth": truth(folder),
                    "settled": session.get("text") or ""})
    Path(path).write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"{path}: {len(out)} settled dictations with something learned before them")


def score(path):
    results = json.loads(Path(path).read_text())

    def dist(a, b):
        x, y = [w.lower() for w in alt.words(a)], [w.lower() for w in alt.words(b)]
        m = difflib.SequenceMatcher(a=x, b=y, autojunk=False)
        return sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in m.get_opcodes() if op != "equal")

    plain = sum(dist(r["plain"], r["truth"]) for r in results)
    taught = sum(dist(r["taught"], r["truth"]) for r in results)
    better = [r for r in results if dist(r["taught"], r["truth"]) < dist(r["plain"], r["truth"])]
    worse = [r for r in results if dist(r["taught"], r["truth"]) > dist(r["plain"], r["truth"])]
    print(f"{len(results)} dictations: words off what the user left — as now {plain}, told what's learned {taught}; "
          f"closer {len(better)}, further {len(worse)}")
    for tag, rs in (("closer", better), ("further", worse)):
        for r in rs[:12]:
            print(f"  {tag}: {r['plain'][:70]!r}\n      → {r['taught'][:70]!r}\n      left: {r['truth'][:70]!r}")


if __name__ == "__main__":
    if "--pairs" in sys.argv:
        ps = pairs()
        print(f"{len(ps)} pairs ({collections.Counter(p[3] for p in ps)})")
        print(learned_text(ps))
    elif "--cases" in sys.argv:
        cases(sys.argv[sys.argv.index("--cases") + 1])
    elif "--score" in sys.argv:
        score(sys.argv[sys.argv.index("--score") + 1])
    elif "--learned" in sys.argv:
        Path(sys.argv[sys.argv.index("--learned") + 1]).write_text(learned_text(pairs()))
