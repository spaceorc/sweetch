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
    """What the user dictated and what Wispr Flow wrote for them — their own sentences, spelled
    right."""
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
    those uses were typed (a typed word may be a typo; dictated ones are spelled right). Messages
    sent to Claude Code are typed too — on the phone as well, typos and all."""
    texts, typed = personal_texts(), sent_messages()
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
    # Sent messages count here: a typo in them is no word of the lexicon, and makes no pair.
    for text in personal_texts() + sent_messages():
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


PROFILES = ["personal", "work", "agent"]
APP_PROFILE = {
    "Telegram": "personal", "ru.keepcoder.Telegram": "personal", "ph.telegra.Telegraph": "personal",
    "Slack": "work", "com.tinyspeck.slackmacgap": "work", "PyCharm": "work", "com.jetbrains.pycharm": "work",
    "Google Chrome": "work", "com.google.Chrome": "work",
    "Claude": "agent", "com.anthropic.claudefordesktop": "agent", "iTerm2": "agent", "com.googlecode.iterm2": "agent",
}


def profile_texts():
    """The user's sentences by profile — personal (Telegram), work (Slack, the IDE, the browser),
    agent (Claude, Claude Code) — from where each was written, and the keyboard's sessions by the
    profile they ended with on the phone."""
    texts = {name: [] for name in PROFILES}
    for path in SUPPORT.glob("dictation/*/session.json"):
        try:
            session = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        profile = APP_PROFILE.get(session.get("app") or "")
        if profile and session.get("text"):
            texts[profile].append(session["text"])
    for path in SUPPORT.glob("wispr-flow/history/*/entry.json"):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        profile = APP_PROFILE.get(entry.get("app") or "")
        text = entry.get("editedText") or entry.get("formattedText")
        if profile and text:
            texts[profile].append(text)
    texts["agent"].extend(sent_messages())
    # The phone's sessions: the words typed in each, under the profile the session ended with.
    words, label = collections.defaultdict(list), {}
    for path in sorted(SUPPORT.glob("keyboard/*.jsonl")):
        for line in path.open(encoding="utf-8"):
            if '"session"' not in line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            session = event.get("session")
            if event.get("e") == "word" and session:
                words[session].append(event.get("word") or "")
            elif event.get("e") == "profile" and session and event.get("profile") in PROFILES:
                label[session] = event["profile"]
    for session, profile in label.items():
        texts[profile].append(" ".join(words.get(session, [])))
    return texts


def profiles(ids):
    """For each profile: each of the user's words weighted −8…8 by how much likelier (or rarer) it
    is there than across all their writing, and the profile's own word pairs 0–15."""
    texts = profile_texts()
    counts = {name: collections.Counter() for name in PROFILES}
    pairs = {name: collections.Counter() for name in PROFILES}
    for name in PROFILES:
        for text in texts[name]:
            for sentence in SENTENCE.split(text):
                previous = 0
                for token in TOKEN.findall(sentence):
                    node = ids.get(token.replace("’", "'").lower())
                    if node is not None:
                        counts[name][node] += 1
                        if previous is not None:
                            pairs[name][(previous, node)] += 1
                    previous = node
    overall = collections.Counter()
    for c in counts.values():
        overall.update(c)
    total = sum(overall.values()) or 1
    vocabulary = len(overall) or 1
    tables = {}
    for name in PROFILES:
        size = sum(counts[name].values()) or 1
        weights = {}
        for node, n in overall.items():
            if n < 3:
                continue
            here = (counts[name][node] + 0.5) / (size + 0.5 * vocabulary)
            everywhere = (n + 0.5) / (total + 0.5 * vocabulary)
            weight = max(-8, min(8, round(2 * math.log2(here / everywhere))))
            if weight:
                weights[node] = weight
        pair_weights = {pair: min(15, 4 + int(3 * math.log2(n))) for pair, n in pairs[name].items() if n >= 2}
        tables[name] = (weights, pair_weights, len(texts[name]))
    return tables


def write_profiles(tables, path):
    """"SWPF" u32 version, u32 profile count; each profile: u32 n, u32 word[], i8 weight[] (by
    word); u32 m, u32 previous[], u32 word[], u8 weight[] (by previous, word)."""
    data = bytearray(b"SWPF") + struct.pack("<II", 1, len(PROFILES))
    for name in PROFILES:
        weights, pairs, _ = tables[name]
        items = sorted(weights.items())
        data += struct.pack("<I", len(items)) + struct.pack(f"<{len(items)}I", *(w for w, _ in items))
        data += struct.pack(f"<{len(items)}b", *(v for _, v in items))
        items = sorted(pairs.items())
        data += struct.pack("<I", len(items))
        data += struct.pack(f"<{len(items)}I", *(p for (p, _), _ in items))
        data += struct.pack(f"<{len(items)}I", *(w for (_, w), _ in items))
        data += bytes(v for _, v in items)
    path.write_bytes(bytes(data))
    return len(data)


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


try:
    import pymorphy3
    MORPH = pymorphy3.MorphAnalyzer()
except ImportError:
    MORPH = None


def real_word(key):
    """A Russian word pymorphy3 knows; without pymorphy3, none is taken for real."""
    return MORPH is not None and bool(re.search("[а-яё]", key)) and MORPH.word_is_known(key)


RU_ROWS = ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"]
EN_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]


def adjacent_keys(rows):
    """Each letter's neighbours on the keyboard: beside it, and the nearest above and below."""
    near = {}
    for r, row in enumerate(rows):
        for i, letter in enumerate(row):
            keys = set(row[max(0, i - 1):i + 2])
            for other in (r - 1, r + 1):
                if 0 <= other < len(rows):
                    # Rows are offset by about half a key: the two nearest.
                    keys |= set(rows[other][max(0, i - 1):i + 1])
            keys.discard(letter)
            near[letter] = keys
    if "е" in near:
        near["е"].add("ё")
        near["ё"] = near["е"] - {"ё"} | {"е"}
    return near


RU_NEAR, EN_NEAR = adjacent_keys(RU_ROWS), adjacent_keys(EN_ROWS)


def typo(key, n, general):
    """A word the user only typed, taken for a typo: one slip (a letter wrong, missing, extra or
    swapped) from a common word of the general lists — "историб", "чот", "nthe". Their slang has no
    such neighbour ("фолбэк", "парсить", "скилл"). A letter wrong is a neighbouring key's
    ("историб" — б by ю; not "войсы" for "войны"). Not a word typed often (15 times), nor a short
    one, nor a Russian word pymorphy3 knows."""
    if n >= 15 or len(key) < 3 or real_word(key):
        return False
    cyrillic = bool(re.search("[а-яё]", key))
    nearby, common = (RU_NEAR, 120) if cyrillic else (EN_NEAR, 200)
    letters = "".join(nearby)
    splits = [(key[:i], key[i:]) for i in range(len(key) + 1)]
    near = set()
    for a, b in splits:
        if b:
            near.add(a + b[1:])
        if len(b) > 1:
            near.add(a + b[1] + b[0] + b[2:])
        for x in letters:
            if b and x in nearby.get(b[0], ()):
                near.add(a + x + b[1:])
            near.add(a + x + b)
    near.discard(key)
    return any(general.get(word, 0) >= common for word in near)


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
    general_frequency = {key: frequency for key, (frequency, _) in entries.items()}
    added = boosted = dropped = 0
    # The user's own frequency ranks their words: the most used near the top of the scale, the
    # others below by how often — over the general lists' order, which knows nothing of them.
    most = max(counts.values(), default=1)
    for key, n in counts.items():
        # Dictated once is enough — dictation spells right. A word only ever typed may be a typo the
        # user makes again and again, and in the lexicon it would never be put right (see `typo`).
        said = n - typed_counts[key]
        if (said < 1 and n < 2) or not WORD.match(key) or len(key) < 2:
            continue
        if said < 1 and key not in entries and typo(key, n, general_frequency):
            dropped += 1
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
    tables = profiles(ids)
    profile_path = output.with_name("Profiles.bin")
    size = write_profiles(tables, profile_path)
    print(f"{profile_path}: " + ", ".join(f"{name} {len(tables[name][0])} words ±, {len(tables[name][1])} pairs from {tables[name][2]} texts"
                                          for name in PROFILES) + f" — {size / 1e6:.1f} MB")
    print(f"{output}: {len(entries)} words ({general} general, {boosted} of them yours, {added} only yours, {dropped} typed ones taken for typos), "
          f"{len(order)} nodes, {len(data) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
