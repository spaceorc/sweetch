#!/usr/bin/env python3
"""The iPhone keyboard's lexicon: the words its decoder looks for, with how common each is.

Sources:
- HeliBoard's Russian and English word lists (codeberg.org/Helium314/aosp-dictionaries, built
  from the Leipzig corpora, CC BY 4.0): word forms with a 0–255 log frequency. Downloaded once
  into ~/Library/Caches/sweetch/lexicon.
- The user's own words: what they dictated (sweetch's dictations), what Wispr Flow wrote for
  them, and what they finished typing on the keyboard (its log) — their terms and names, and
  the common words they use, made more likely.

Output: one binary file the keyboard memory-maps (nothing is turned into strings in memory —
that's what runs a keyboard out of memory). Little-endian:

    "SWLX" u32 version
    u32 alphabet size, then each symbol as a u32 Unicode scalar
    u32 node count N, then five arrays of N:
        u32 first child (index of the node's first child; children are contiguous, by label)
        u8  child count
        u8  label (alphabet index of the letter leading into the node; the root's is 0)
        u8  frequency (0: no word ends here; 1–255: a word does, this common)
        u8  flags (1: written with a capital first letter, 2: all capitals,
                   4: written otherwise — see the casing table, 8: the user's own word)
    u32 casing count, then for each: u16 length + UTF-8 of the word in lower case,
                                      u16 length + UTF-8 as written

Keys are lower case; ё is kept (the decoder treats е and ё as one key).

Usage: Tools/keyboard/build_lexicon.py [output path]
"""

import collections
import json
import math
import re
import struct
import sys
import urllib.request
from pathlib import Path

CACHE = Path.home() / "Library/Caches/sweetch/lexicon"
SUPPORT = Path.home() / "Library/Application Support/sweetch"
SOURCES = {
    "ru": "https://codeberg.org/Helium314/aosp-dictionaries/raw/branch/main/wordlists/main_ru__experimental.combined",
    "en": "https://codeberg.org/Helium314/aosp-dictionaries/raw/branch/main/wordlists/main_en_US__experimental.combined",
}
KEEP = {"ru": 400_000, "en": 150_000}
LETTERS = "абвгдеёжзийклмнопрстуфхцчшщъыьэюяabcdefghijklmnopqrstuvwxyz"
ALPHABET = list(LETTERS) + ["-", "'"]
WORD = re.compile(r"^[а-яёa-z]+(?:[-'][а-яёa-z]+)*$")
TOKEN = re.compile(r"[A-Za-zА-Яа-яЁё]+(?:[-'’][A-Za-zА-Яа-яЁё]+)*")


def source(lang):
    path = CACHE / f"{lang}.combined"
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        print(f"downloading {SOURCES[lang]}")
        urllib.request.urlretrieve(SOURCES[lang], path)
    return path


def read_list(lang):
    """(frequency, word as written) for words of the keyboard's letters, most common first."""
    words = []
    for line in source(lang).open(encoding="utf-8"):
        if not line.startswith(" word="):
            continue
        word, rest = line[6:].rstrip("\n").rsplit(",f=", 1)
        frequency = int(rest.split(",")[0])
        if frequency > 0 and WORD.match(word.lower().replace("’", "'")):
            words.append((frequency, word.replace("’", "'")))
    words.sort(key=lambda fw: -fw[0])
    return words[:KEEP[lang]]


def personal_texts():
    """What the user dictated and what Wispr Flow wrote for them — their own sentences."""
    texts = []
    for path in SUPPORT.glob("dictation/*/session.json"):
        try:
            texts.append(json.loads(path.read_text()).get("text") or "")
        except (OSError, ValueError):
            pass
    for path in SUPPORT.glob("wispr-flow/history/*/entry.json"):
        try:
            entry = json.loads(path.read_text())
            texts.append(entry.get("editedText") or entry.get("formattedText") or "")
        except (OSError, ValueError):
            pass
    texts.extend(sent_messages())
    return texts


def sent_messages():
    """What the user sent Claude Code — written to an agent and put right before sending: their
    own words, imperatives and all («сделай», not the «сделаю» dictation hears)."""
    messages = []
    for path in (Path.home() / ".claude/projects").glob("*/*.jsonl"):
        for line in path.open(encoding="utf-8", errors="ignore"):
            if '"type":"user"' not in line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") != "user" or event.get("isMeta"):
                continue
            content = event.get("message", {}).get("content")
            if isinstance(content, list):
                content = " ".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
            # Not the harness's own messages (commands, tool output, reminders).
            if isinstance(content, str) and content.strip() and not content.lstrip().startswith("<"):
                messages.append(content)
    return messages


def personal_words():
    """The user's words: how often they used them, as they wrote them most often, and how many of
    those uses were typed (a typed word may be a typo; dictated ones are spelled right)."""
    texts, typed = personal_texts(), []
    for path in SUPPORT.glob("keyboard/*.jsonl"):
        for line in path.open(encoding="utf-8"):
            if '"e":"word"' in line:
                try:
                    typed.append(json.loads(line).get("word") or "")
                except ValueError:
                    pass
    counts, spellings, typed_counts = collections.Counter(), collections.defaultdict(collections.Counter), collections.Counter()
    for source, is_typed in ((texts, False), (typed, True)):
        for text in source:
            for token in TOKEN.findall(text):
                token = token.replace("’", "'")
                key = token.lower()
                counts[key] += 1
                spellings[key][token] += 1
                if is_typed:
                    typed_counts[key] += 1
    return counts, spellings, typed_counts


def casing(written):
    """Flags and, for odd casing, the form to keep."""
    if written == written.lower():
        return 0, None
    if written == written.upper() and len(written) > 1:
        return 2, None
    if written[0].isupper() and written[1:] == written[1:].lower():
        return 1, None
    return 4, written


def build(entries):
    """A trie over the keys, nodes in breadth-first order so each node's children are contiguous.
    Each word's node index is its id (the bigrams refer to words by it; the root, 0, stands for a
    sentence's start)."""
    root = {"children": {}, "frequency": 0, "flags": 0}
    for key, (frequency, flags) in entries.items():
        node = root
        for letter in key:
            node = node["children"].setdefault(letter, {"children": {}, "frequency": 0, "flags": 0})
        node["frequency"], node["flags"] = frequency, flags
    for key in entries:
        node = root
        for letter in key:
            node = node["children"][letter]
        node["key"] = key
    order, labels = [root], [0]
    first, count = [], []
    i = 0
    while i < len(order):
        node = order[i]
        children = sorted(node["children"].items(), key=lambda lc: ALPHABET.index(lc[0]))
        first.append(len(order))
        count.append(len(children))
        for letter, child in children:
            order.append(child)
            labels.append(ALPHABET.index(letter))
        i += 1
    return order, labels, first, count


SENTENCE = re.compile(r"[.!?…\n]+")


def bigrams(ids):
    """(previous word id, word id) → weight 0–15: how much likelier the word is after that one.
    The root's id, 0, is a sentence's start. From the user's own sentences (the more often a pair,
    the heavier) and the general lists' top three next words for each word."""
    weights = {}
    pairs = collections.Counter()
    for text in personal_texts():
        for sentence in SENTENCE.split(text):
            previous = 0
            for token in TOKEN.findall(sentence):
                key = token.replace("’", "'").lower()
                node = ids.get(key)
                if node is not None and previous is not None:
                    pairs[(previous, node)] += 1
                previous = node
    for pair, n in pairs.items():
        weights[pair] = min(15, 5 + int(3 * math.log2(n)))
    for lang in ("ru", "en"):
        word = None
        for line in source(lang).open(encoding="utf-8"):
            if line.startswith(" word="):
                word = ids.get(line[6:].rsplit(",f=", 1)[0].replace("’", "'").lower())
            elif line.startswith("  bigram=") and word is not None:
                name, rank = line[9:].rstrip("\n").rsplit(",f=", 1)
                node = ids.get(name.replace("’", "'").lower())
                if node is not None:
                    pair = (word, node)
                    weights[pair] = max(weights.get(pair, 0), {1: 8, 2: 6, 3: 4}.get(int(rank), 4))
    return weights


def write_bigrams(weights, path):
    """"SWBG" u32 version, u32 count, then sorted by (previous, word): u32 previous[], u32 word[],
    u8 weight[]."""
    items = sorted(weights.items())
    data = bytearray(b"SWBG") + struct.pack("<II", 1, len(items))
    data += struct.pack(f"<{len(items)}I", *(p for (p, _), _ in items))
    data += struct.pack(f"<{len(items)}I", *(w for (_, w), _ in items))
    data += bytes(weight for _, weight in items)
    path.write_bytes(bytes(data))
    return len(data)


def main():
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "iOS/SweetchKeyboard/Lexicon.bin"
    entries, written_as = {}, {}
    for lang in ("ru", "en"):
        for frequency, written in read_list(lang):
            key = written.lower()
            if key not in entries or entries[key][0] < frequency:
                flags, odd = casing(written)
                entries[key] = (frequency, flags)
                if odd:
                    written_as[key] = odd
    general = len(entries)

    counts, spellings, typed_counts = personal_words()
    added = boosted = 0
    # The user's own frequency ranks their words: the most used near the top of the scale, the
    # others below by how often — over the general lists' order, which knows nothing of them.
    most = max(counts.values(), default=1)
    for key, n in counts.items():
        # Dictated once is enough — dictation spells right; typed, only from twice.
        said = n - typed_counts[key]
        if (said < 1 and n < 2) or not WORD.match(key) or len(key) < 2:
            continue
        written = spellings[key].most_common(1)[0][0]
        own = 190 + int(65 * math.log(n) / math.log(max(most, 2)))
        if key in entries:
            frequency, flags = entries[key]
            entries[key] = (min(255, max(frequency, own)), flags | 8)
            boosted += 1
        else:
            flags, odd = casing(written)
            entries[key] = (min(240, own), flags | 8)
            if odd:
                written_as[key] = odd
            added += 1

    order, labels, first, count = build(entries)
    ids = {node["key"]: i for i, node in enumerate(order) if "key" in node}
    data = bytearray(b"SWLX") + struct.pack("<I", 1)
    data += struct.pack("<I", len(ALPHABET)) + b"".join(struct.pack("<I", ord(c)) for c in ALPHABET)
    data += struct.pack("<I", len(order))
    data += struct.pack(f"<{len(order)}I", *first)
    data += bytes(count) + bytes(labels)
    data += bytes(node["frequency"] for node in order) + bytes(node["flags"] for node in order)
    data += struct.pack("<I", len(written_as))
    for key, written in sorted(written_as.items()):
        k, w = key.encode(), written.encode()
        data += struct.pack("<H", len(k)) + k + struct.pack("<H", len(w)) + w
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(bytes(data))
    weights = bigrams(ids)
    bigram_path = output.with_name("Bigrams.bin")
    size = write_bigrams(weights, bigram_path)
    print(f"{bigram_path}: {len(weights)} word pairs, {size / 1e6:.1f} MB")
    print(f"{output}: {len(entries)} words ({general} general, {boosted} of them yours, {added} only yours), "
          f"{len(order)} nodes, {len(data) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
