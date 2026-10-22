"""The next word, from the two before it: counts of word triples and pairs in the Leipzig corpora
(sentences from the web and the news, CC BY 4.0 — downloaded once into ~/Library/Caches/sweetch/
corpora) and in the user's own texts, smoothed by interpolated absolute discounting (Kneser–Ney's
simpler sibling), and for each context the likeliest few next words kept — what the keyboard offers
before a letter is typed. build_lexicon.py calls `write` with the lexicon's node ids.

NextWords.bin (little-endian):
    "SWNW", u32 version 1, u32 contexts, u32 entries
    contexts, sorted by (first, second): u32 first (0xFFFFFFFF: a pair's context, one word),
        u32 second, u32 index of its first entry, u8 entries, u8 backoff (the weight left for the
        pair's words, as the entries' scale)
    entries: u32 word, u8 −log2 of its probability × 16
Node id 0, the root, is a sentence's start.
"""
import os
import re
import struct
import urllib.request
from array import array
from pathlib import Path

import numpy as np

CORPORA = ["rus-ru_web-public_2019_1M", "rus_news_2024_1M", "eng-com_web-public_2018_1M"]
CACHE = Path.home() / "Library/Caches/sweetch/corpora"
TOKEN = re.compile(r"[A-Za-zА-Яа-яЁё]+(?:[-'’][A-Za-zА-Яа-яЁё]+)*")
SENTENCE = re.compile(r"[.!?…\n]+")
NONE = 0xFFFFFFFF

# How much a sentence of the user's own counts against one of the corpora's
# (SWEETCH_NGRAM_PERSONAL): theirs are few, and what the keyboard should sound like.
PERSONAL = float(os.environ.get("SWEETCH_NGRAM_PERSONAL", "200"))
DISCOUNT = 0.75
# Kept: next words per pair's context, per triple's; a triple's context seen at least this often.
# Deep enough that the letters typed still leave some to offer (WordDecoder.completions): 24 after a
# word put the word among three after one letter for 15% of held-out words against 4% with 4; the
# triples' depth and how often they were seen hardly mattered — 18 MB.
PAIR_WORDS, TRIPLE_WORDS, TRIPLE_SEEN = (int(x) for x in os.environ.get("SWEETCH_NGRAM_KEEP", "24,12,20").split(","))


def corpus(name):
    path = CACHE / f"{name}-sentences.txt"
    if not path.exists():
        import tarfile
        CACHE.mkdir(parents=True, exist_ok=True)
        url = f"https://downloads.wortschatz-leipzig.de/corpora/{name}.tar.gz"
        print(f"downloading {url}")
        with urllib.request.urlopen(url) as response, tarfile.open(fileobj=response, mode="r|gz") as tar:
            for member in tar:
                if member.name.endswith("sentences.txt"):
                    path.write_bytes(tar.extractfile(member).read())
                    break
    with path.open(encoding="utf-8") as f:
        for line in f:
            yield line.split("\t", 1)[-1]


BITS = 21   # node ids are below 2²¹: three fit one 64-bit key


def count(texts, ids, weight):
    """Keys of the pairs and triples of lexicon words in `texts`, with `weight` each; a word not in
    the lexicon breaks them."""
    pairs, triples = array("q"), array("q")
    for text in texts:
        for sentence in SENTENCE.split(text):
            a, b = None, 0
            for token in TOKEN.findall(sentence):
                c = ids.get(token.replace("’", "'").lower())
                if c is not None and b is not None:
                    pairs.append(b << BITS | c)
                    if a is not None:
                        triples.append((a << BITS | b) << BITS | c)
                a, b = b, c
    return (np.frombuffer(pairs, dtype=np.int64), np.full(len(pairs), weight)), \
           (np.frombuffer(triples, dtype=np.int64), np.full(len(triples), weight))


def summed(parts):
    """Each key once, its weights added."""
    keys = np.concatenate([k for k, _ in parts])
    weights = np.concatenate([w for _, w in parts])
    unique, inverse = np.unique(keys, return_inverse=True)
    return unique, np.bincount(inverse, weights=weights)


def best(keys, counts, context_of, limit, seen=0):
    """Per context (`context_of(keys)`, the keys sorted by it): its total, how many words follow it,
    and its `limit` likeliest next words seen twice or more — as index arrays into `keys`."""
    contexts = context_of(keys)
    starts = np.flatnonzero(np.r_[True, contexts[1:] != contexts[:-1]])
    totals = np.add.reduceat(counts, starts)
    distinct = np.diff(np.r_[starts, len(keys)])
    group = np.repeat(np.arange(len(starts)), distinct)
    order = np.lexsort((-counts, group))   # within each context, the likeliest first
    rank = np.arange(len(keys)) - starts[group[order]]
    keep = order[(rank < limit) & (counts[order] >= 2) & (totals[group[order]] >= seen)]
    return contexts, starts, totals, distinct, group, keep


def quantise(p):
    return np.clip(np.round(-np.log2(np.maximum(p, 1e-12)) * 16), 0, 255).astype(np.uint8)


def write(ids, path, personal_texts):
    pair_parts, triple_parts = [], []
    for name in CORPORA:
        p, t = count(corpus(name), ids, 1.0)
        pair_parts.append(p); triple_parts.append(t)
        print(f"{name}: {len(p[0])} pairs")
    p, t = count(personal_texts, ids, PERSONAL)
    pair_parts.append(p); triple_parts.append(t)
    pairs, pair_n = summed(pair_parts)
    triples, triple_n = summed(triple_parts)
    mask = (1 << BITS) - 1

    # A pair's probability, discounted; what the discount leaves is the backoff weight (spread, in
    # Kneser–Ney, over the words by how many contexts they follow — the keyboard needs only the
    # kept words, and ranks them by this).
    ctx, starts, totals, distinct, group, keep = best(pairs, pair_n, lambda k: k >> BITS, PAIR_WORDS)
    pair_p = np.maximum(pair_n - DISCOUNT, 0) / totals[group]
    pair_backoff = DISCOUNT * distinct / totals
    kept_pairs = pairs[keep]   # sorted by context, then likeliest first
    by_key = np.argsort(kept_pairs)
    kept_pairs_sorted, kept_pairs_p = kept_pairs[by_key], pair_p[keep][by_key]

    tctx, tstarts, ttotals, tdistinct, tgroup, tkeep = best(triples, triple_n, lambda k: k >> BITS, TRIPLE_WORDS, TRIPLE_SEEN)
    triple_backoff = DISCOUNT * tdistinct / ttotals
    tp = np.maximum(triple_n[tkeep] - DISCOUNT, 0) / ttotals[tgroup[tkeep]]
    # Plus the backoff's share of the pair's probability, for the words the pair kept.
    bc = (triples[tkeep] >> BITS & mask) << BITS | (triples[tkeep] & mask)
    found = np.searchsorted(kept_pairs_sorted, bc)
    known = (found < len(kept_pairs_sorted)) & (kept_pairs_sorted[np.minimum(found, len(kept_pairs_sorted) - 1)] == bc)
    lift = np.where(known, kept_pairs_p[np.minimum(found, len(kept_pairs_sorted) - 1)], 0.0)
    tp = tp + triple_backoff[tgroup[tkeep]] * lift

    # The table: pairs' contexts (first = NONE) and triples' (first, second), sorted.
    rows = []   # (first, second, words, probabilities, backoff)
    def collect(keep_idx, context_ids, groups, probs, backoffs, two):
        if len(keep_idx) == 0:
            return
        g = groups[keep_idx]
        cuts = np.flatnonzero(np.r_[True, g[1:] != g[:-1]])
        for i, j in zip(cuts, np.r_[cuts[1:], len(g)]):
            context = int(context_ids[g[i]])
            first, second = (context >> BITS, context & mask) if two else (NONE, context)
            order = np.argsort(-probs[i:j])
            rows.append((first, second, (keys_of(keep_idx[i:j]) & mask)[order], probs[i:j][order], backoffs[g[i]]))
    keys_of = lambda idx: pairs[idx]
    collect(keep, ctx[starts], group, pair_p[keep], pair_backoff, False)
    keys_of = lambda idx: triples[idx]
    collect(tkeep, tctx[tstarts], tgroup, tp, triple_backoff, True)
    rows.sort(key=lambda r: (r[0], r[1]))

    head = bytearray(b"SWNW") + struct.pack("<III", 1, len(rows), sum(len(r[2]) for r in rows))
    table, entries = bytearray(), bytearray()
    index = 0
    for first, second, words, probs, backoff in rows:
        table += struct.pack("<IIIBB", first, second, index, len(words), int(quantise(np.array([min(backoff, 1.0)]))[0]))
        q = quantise(probs)
        for w, x in zip(words.tolist(), q.tolist()):
            entries += struct.pack("<IB", w, x)
        index += len(words)
    path.write_bytes(bytes(head + table + entries))
    two = sum(1 for r in rows if r[0] != NONE)
    print(f"{path}: {len(rows)} contexts ({two} of two words), {index} next words, {path.stat().st_size / 1e6:.1f} MB")
