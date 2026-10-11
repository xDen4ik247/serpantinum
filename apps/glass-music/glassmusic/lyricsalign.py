"""Lyrics <-> transcript alignment and transcript -> lyric lines. Dependency-free (stdlib only),
so it runs both in the app backend (tests) and inside the Whisper helper process.

words: [[start, end, text, seg0], ...] from Whisper word timestamps; seg0 marks the first word of a
Whisper segment, whose start is snapped to the segment start and therefore unreliable.

align(lines, words) gives every lyric line a start time: a semi-global alignment of the lyric tokens
against the transcript tokens (exact or fuzzy word matches, CJK per character), then each line takes
the time of its earliest reliable match (minus the words sung before it), unmatched lines are
interpolated by token count, and times are made strictly increasing."""

import difflib
import re
import unicodedata

_CJK = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]")
_PUNCT = re.compile(r"[^\w\s぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]", re.U)
WORD_S = 0.30          # typical sung word length used to back off from a later word in the line
HALLUCINATIONS = (
    "thank you", "thanks for watching", "thank you for watching", "subtitles by", "please subscribe",
    "продолжение следует", "субтитры", "редактор субтитров", "спасибо за просмотр",
    "ご視聴ありがとうございました", "字幕",
)


def norm(s):
    s = unicodedata.normalize("NFKC", s).lower().replace("ё", "е").replace("’", "").replace("'", "")
    return _PUNCT.sub(" ", s)


def tokens(s):
    """Normalised tokens of a text: words, CJK characters one by one."""
    out = []
    for w in norm(s).split():
        if _CJK.search(w):
            buf = ""
            for ch in w:
                if _CJK.match(ch):
                    if buf:
                        out.append(buf)
                        buf = ""
                    out.append(ch)
                else:
                    buf += ch
            if buf:
                out.append(buf)
        else:
            out.append(w)
    return out


def language_of(text):
    """A Whisper language hint from the script of a text (None = let Whisper detect)."""
    if re.search(r"[぀-ヿ]", text):
        return "ja"
    if re.search(r"[가-힯]", text):
        return "ko"
    if re.search(r"[一-鿿]", text):
        return "zh"
    cyr = len(re.findall(r"[а-яА-ЯёЁ]", text))
    lat = len(re.findall(r"[a-zA-Z]", text))
    if cyr > lat:
        return "uk" if re.search(r"[іїєґІЇЄҐ]", text) else "ru"
    return "en" if lat > 20 else None


def _transcript_tokens(words):
    """[(token, time, reliable)] with CJK words spread evenly over their duration."""
    out = []
    for w in words:
        t, e, text, seg0 = w[0], w[1], w[2], bool(w[3]) if len(w) > 3 else False
        toks = tokens(text)
        if not toks:
            continue
        step = max(0.0, (e - t)) / len(toks)
        for i, tok in enumerate(toks):
            out.append((tok, t + i * step, not (seg0 and i == 0)))
    return out


def _sim(a, b, cache):
    if a == b:
        return 2.0
    k = (a, b)
    v = cache.get(k)
    if v is None:
        if len(a) < 3 or len(b) < 3 or _CJK.match(a) or _CJK.match(b):
            v = -1.0
        else:
            r = difflib.SequenceMatcher(None, a, b).ratio()
            v = 1.0 if r >= 0.75 else (0.3 if r >= 0.6 else -1.0)
        cache[k] = v
    return v


def _dp(L, T):
    """Semi-global alignment (free leading/trailing gaps on both sides). Returns [(i, j)] matches."""
    n, m = len(L), len(T)
    GAP_L, GAP_T = -0.6, -0.35          # skipping a lyric token costs more than a transcript one
    cache = {}
    rows = [[0.0] * (m + 1)]            # free leading gaps in T
    back = []
    for i in range(1, n + 1):
        prev = rows[-1]
        cur = [0.0] * (m + 1)           # cur[0] = 0: free leading gaps in L
        bi = bytearray(m + 1)
        li = L[i - 1]
        for j in range(1, m + 1):
            d = prev[j - 1] + _sim(li, T[j - 1], cache)
            u = prev[j] + GAP_L
            lft = cur[j - 1] + GAP_T
            if d >= u and d >= lft:
                cur[j], bi[j] = d, 1
            elif u >= lft:
                cur[j], bi[j] = u, 2
            else:
                cur[j], bi[j] = lft, 3
        back.append(bi)
        rows.append(cur)
    # best end anywhere on the last row or column (free trailing gaps)
    best, bi_, bj = -1e9, n, m
    for j in range(m + 1):
        if rows[n][j] > best:
            best, bi_, bj = rows[n][j], n, j
    for i in range(n + 1):
        if rows[i][m] > best:
            best, bi_, bj = rows[i][m], i, m
    i, j, pairs = bi_, bj, []
    while i > 0 and j > 0:
        b = back[i - 1][j]
        if b == 1:
            if L[i - 1] == T[j - 1] or _sim(L[i - 1], T[j - 1], cache) > 0:
                pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif b == 2:
            i -= 1
        elif b == 3:
            j -= 1
        else:
            break
    pairs.reverse()
    return pairs


def align(lines, words, duration=0.0):
    """(start times per line (None for blank lines), quality 0..1)."""
    L, owner, pos = [], [], []
    for li, x in enumerate(lines):
        for k, tok in enumerate(tokens(x)):
            L.append(tok)
            owner.append(li)
            pos.append(k)
    TT = _transcript_tokens(words)
    if not L or not TT:
        return [None] * len(lines), 0.0
    pairs = _dp(L, [t[0] for t in TT])
    quality = len(pairs) / len(L)
    cand = {}
    for i, j in pairs:
        li, k = owner[i], pos[i]
        _, t, reliable = TT[j]
        est = t - k * WORD_S
        old = cand.get(li)
        # earliest token of the line wins; a reliable match beats a segment-start one
        key = (0 if reliable else 1, k)
        if old is None or key < old[0]:
            cand[li] = (key, est)
    ntok = [len(tokens(x)) for x in lines]
    times = [None] * len(lines)
    for li, (_, est) in cand.items():
        times[li] = max(0.0, est)
    # drop matches that go backwards (a chorus matched to the wrong repetition)
    idx = [i for i in range(len(lines)) if times[i] is not None]
    keep = _longest_increasing(idx, times)
    for i in idx:
        if i not in keep:
            times[i] = None
    # interpolate lines without a match by their token counts
    known = [i for i in range(len(lines)) if times[i] is not None and ntok[i]]
    if not known:
        return [None] * len(lines), 0.0
    def sung(i):
        return max(1.5, ntok[i] * WORD_S * 1.3)
    for a, b in zip([None] + known, known + [None]):
        lo = a + 1 if a is not None else 0
        hi = b if b is not None else len(lines)
        gap = [i for i in range(lo, hi) if ntok[i]]
        if not gap:
            continue
        if a is None:            # before the first match: back off at sung speed
            t = times[b]
            for i in reversed(gap):
                t -= sung(i)
                times[i] = max(0.0, t)
        elif b is None:          # after the last match: forward at sung speed
            t = times[a] + sung(a)
            for i in gap:
                times[i] = t
                t += sung(i)
        else:                    # between two matches: share the time by token count
            weights = [ntok[a]] + [ntok[i] for i in gap]
            tot, acc = float(sum(weights)), weights[0]
            for i, w in zip(gap, weights[1:]):
                times[i] = times[a] + (times[b] - times[a]) * acc / tot
                acc += w
    # strictly increasing, at least 0.4 s apart; blank lines get no time
    last = -1.0
    for i in range(len(lines)):
        if not ntok[i]:
            times[i] = None
            continue
        if times[i] is None or times[i] <= last + 0.4:
            times[i] = last + 0.4 if last >= 0 else max(0.0, times[i] or 0.0)
        last = times[i]
    return [round(t, 2) if t is not None else None for t in times], round(quality, 3)


def _longest_increasing(idx, times):
    """The set of line indexes whose times form the longest increasing run (O(n^2), n is small)."""
    n = len(idx)
    if not n:
        return set()
    best = [1] * n
    prev = [-1] * n
    for a in range(n):
        for b in range(a):
            if times[idx[b]] < times[idx[a]] and best[b] + 1 > best[a]:
                best[a], prev[a] = best[b] + 1, b
    k = max(range(n), key=lambda i: best[i])
    out = set()
    while k >= 0:
        out.add(idx[k])
        k = prev[k]
    return out


def to_lrc_lines(lines, times):
    """[(t, text)] for an aligned result; blank lines become stanza breaks shortly after the previous line."""
    out = []
    last = None
    for x, t in zip(lines, times):
        if t is None:
            if last is not None and out and out[-1][1]:
                out.append((round(last + 0.2, 2), ""))
            continue
        out.append((t, x))
        last = t
    while out and not out[-1][1]:
        out.pop()
    return out


def transcript_lines(words, max_words=9, gap_s=0.7):
    """Lyric-like lines from Whisper words: break on pauses, sentence ends, length and segments."""
    lines, cur, start, last_end = [], [], None, None
    for w in words:
        t, e, text = w[0], w[1], w[2].strip()
        seg0 = bool(w[3]) if len(w) > 3 else False
        if not text:
            continue
        brk = cur and (seg0 or (last_end is not None and t - last_end >= gap_s) or len(cur) >= max_words
                       or (len(cur) >= 4 and re.search(r"[.!?。！？]$", cur[-1])))
        if brk:
            lines.append((start, _join(cur)))
            cur, start = [], None
        if start is None:
            start = t
        cur.append(text)
        last_end = e
    if cur:
        lines.append((start, _join(cur)))
    # drop known hallucinations and long runs of the same line
    out, run = [], 0
    for t, x in lines:
        n = norm(x).strip()
        if not n or any(n == h or n.startswith(h + " ") for h in HALLUCINATIONS):
            continue
        run = run + 1 if out and norm(out[-1][1]).strip() == n else 1
        if run > 4:
            continue
        out.append((round(t, 2), x))
    return out


def _join(ws):
    s = ""
    for w in ws:
        if s and not (_CJK.match(w[:1]) and _CJK.search(s[-1:])):
            s += " "
        s += w
    return re.sub(r"\s+([,.!?])", r"\1", s).strip()
