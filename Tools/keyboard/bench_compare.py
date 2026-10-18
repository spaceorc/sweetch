"""The bench's runs side by side: `python3 bench_compare.py base variant…` (names under build/bench).
Each line a measure, each column a run, the difference from the first run in brackets."""
import json
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parents[2] / "build/bench"
LINES = [
    ("decoder: first pick is the word, %", ("decoder", "top1_pct"), 1),
    ("decoder: first pick is the word", ("decoder", "top1"), 1),
    ("decoder: the word in its three", ("decoder", "top3"), 1),
    ("taps landed on the word's keys", ("decoder", "literal_right"), 1),
    ("autocorrect: real words broken", ("autocorrect", "breaks"), -1),
    ("autocorrect: typos left in, fixed", ("autocorrect", "typos_left_fixed"), 1),
    ("autocorrect: user's fixes made", ("autocorrect", "made_right"), 1),
    ("autocorrect: user's fixes made wrong", ("autocorrect", "made_wrong"), -1),
    ("second look: put right", ("post", "fixed"), 1),
    ("second look: made wrong", ("post", "breaks"), -1),
    ("prediction: next word first", ("prediction", "top1"), 1),
    ("prediction: next word in three", ("prediction", "top3"), 1),
    ("suggestions 2-3: first at some point", ("suggestions", "2-3", "top1"), 1),
    ("suggestions 4-6: first at some point", ("suggestions", "4-6", "top1"), 1),
    ("suggestions 7+: first at some point", ("suggestions", "7+", "top1"), 1),
    ("suggestions 7+: letters left when first", ("suggestions", "7+", "top1_left_median"), 1),
    ("keystrokes saved by suggestions, %", ("suggestions", "keystrokes_saved_pct"), 1),
    ("ms per word", ("ms_per_word",), -1),
]


def get(run, path):
    for key in path:
        run = run.get(key, {}) if isinstance(run, dict) else {}
    return run if isinstance(run, (int, float)) else None


def main():
    runs = [json.loads((DIR / f"{name}.json").read_text()) for name in sys.argv[1:]]
    width = max(len(label) for label, _, _ in LINES)
    print(" " * width + "".join(f"{r['name']:>22}" for r in runs))
    for label, path, better in LINES:
        base = get(runs[0], path)
        cells = []
        for r in runs:
            v = get(r, path)
            if v is None:
                cells.append(f"{'—':>22}")
                continue
            text = f"{v:.1f}" if isinstance(v, float) else str(v)
            if r is not runs[0] and base is not None and v != base:
                d = v - base
                mark = "+" if (d > 0) == (better > 0) else "−"
                text += f" ({d:+.1f}{mark})" if isinstance(d, float) else f" ({d:+d}{mark})"
            cells.append(f"{text:>22}")
        print(f"{label:<{width}}" + "".join(cells))


if __name__ == "__main__":
    main()
