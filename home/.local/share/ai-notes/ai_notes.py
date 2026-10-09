#!/usr/bin/env python3
"""ai-notes - local AI tools for the Obsidian vault (everything stays on this laptop).

  ai-notes ask "question" [-k N] [--jsonl]     answer from your notes with [[note]] citations
  ai-notes search "query" [-k N] [--json]       semantic search only (no LLM)
  ai-notes index [--full] [--quiet]             update the embedding index (incremental)
  ai-notes status [--json]                      index / servers state
  ai-notes current [--json]                     the note open in Obsidian (workspace.json)
  ai-notes suggest [NOTE] [--json]              link + tag suggestions (never edits)
  ai-notes apply-suggest NOTE [--link T]... [--tag T]...   write accepted suggestions
  ai-notes tidy [NOTE] [--json]                 propose a tidied version as a diff (never edits)
  ai-notes tidy-apply PROPOSAL.json             apply a tidy proposal (refused if the note changed)
  ai-notes cards [NOTE] [--text T | --ocr] [--json]   propose study cards (JA -> vocab with furigana)
  ai-notes cards-send PROPOSAL.json --to anki|sr [--select 0,2,...] [--deck D]
  ai-notes voice start|stop|toggle|cancel|status       voice note (Whisper via `aidict file`) -> note
  ai-notes weekly [--week 2026-W41] [--write] [--force] [--json]   weekly review note
  ai-notes weekly-write PROPOSAL.json [--force]  write a weekly preview made by `weekly`
  ai-notes watch                                inotify watcher (ai-notes-watch.service)

NOTE = vault-relative path, absolute path or note title; default = the note open in Obsidian.
Chat LLM: 127.0.0.1:8765 (AI_URL). Embeddings: 127.0.0.1:8767 (ai-notes-embed.service, on demand,
stopped by ai-notes-embed-idle.timer after 10 idle minutes). Vault: ~/Obsidian/Vault (AI_NOTES_VAULT).
"""
import argparse
import datetime as dt
import difflib
import hashlib
import json
import os
import re
import select
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path

import numpy as np

HOME = Path.home()
VAULT = Path(os.environ.get("AI_NOTES_VAULT", HOME / "Obsidian/Vault")).expanduser()
VAULT_NAME = os.environ.get("AI_NOTES_VAULT_NAME", VAULT.name)
DATA = Path(os.environ.get("AI_NOTES_DATA", HOME / ".local/share/ai-notes"))
DB_PATH = DATA / "index.sqlite"
RUN = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "ai-notes"
LLM = os.environ.get("AI_URL", "http://127.0.0.1:8765").rstrip("/").removesuffix("/v1")
EMB = os.environ.get("AI_NOTES_EMBED_URL", "http://127.0.0.1:8767").rstrip("/")
EMB_UNIT = "ai-notes-embed.service"
IDLE_TIMER = "ai-notes-embed-idle.timer"
DIM = 1024
SKIP_DIRS = {".obsidian", ".trash", ".git", ".stfolder", "node_modules"}
QUERY_INSTRUCT = "Instruct: Given a question, retrieve passages from personal study notes that answer it\nQuery: "
JA_RE = re.compile(r"[぀-ヿ一-鿿]")
LINK_RE = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]")
TAG_RE = re.compile(r"(?<![\w&/#])#([A-Za-zА-Яа-яЁё][\w/-]{1,40})")

JSONL = False


# ------------------------------------------------------------------------------------------ utils
def emit(kind, /, **kw):
    """Machine-readable progress for the panel (--jsonl) or a short line on stderr."""
    if JSONL:
        print(json.dumps({**kw, "type": kind}, ensure_ascii=False), flush=True)
    elif kind == "status" and sys.stderr.isatty():
        print(f"\033[2m{kw.get('msg', '')}\033[0m", file=sys.stderr, flush=True)


def die(msg, code=1):
    if JSONL:
        emit("error", msg=msg)
    else:
        print(f"ai-notes: {msg}", file=sys.stderr)
    sys.exit(code)


def notify(title, body="", *extra):
    subprocess.run(["notify-send", "-a", "AI notes", *extra, title, body], capture_output=True)


def uri(rel):
    rel = rel[:-3] if rel.endswith(".md") else rel
    return "obsidian://open?" + urllib.parse.urlencode({"vault": VAULT_NAME, "file": rel}, quote_via=urllib.parse.quote)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def title_of(rel):
    return Path(rel).stem


def est_tokens(t):
    ja = len(JA_RE.findall(t))
    cyr = len(re.findall(r"[А-Яа-яЁё]", t))
    return int(ja * 1.1 + cyr / 2.6 + (len(t) - ja - cyr) / 3.6) + 8


def http_json(url, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data, {"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def md_files():
    out = []
    for root, dirs, files in os.walk(VAULT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in files:
            if f.endswith(".md"):
                p = Path(root) / f
                out.append(str(p.relative_to(VAULT)))
    return sorted(out)


def split_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end > 0:
            nl = text.find("\n", end + 4)
            nl = len(text) if nl < 0 else nl + 1
            return text[:nl], text[nl:]
    return "", text


def note_tags(text):
    fm, body = split_frontmatter(text)
    tags = set()
    m = re.search(r"^tags:\s*\[([^\]]*)\]", fm, re.M)
    if m:
        tags |= {t.strip().strip("'\"#") for t in m.group(1).split(",") if t.strip()}
    m = re.search(r"^tags:\s*\n((?:\s*-\s*.+\n?)+)", fm, re.M)
    if m:
        tags |= {ln.strip()[1:].strip().strip("'\"#") for ln in m.group(1).splitlines() if ln.strip().startswith("-")}
    m = re.search(r"^tags:\s*([^\[\n].*)$", fm, re.M)
    if m and m.group(1).strip():
        tags |= {t.strip("#, ") for t in m.group(1).split() if t.strip("#, ")}
    body_nc = re.sub(r"```.*?```", "", body, flags=re.S)
    tags |= set(TAG_RE.findall(body_nc))
    return {t for t in tags if t}


def resolve_note(arg):
    """NOTE argument -> vault-relative path."""
    if not arg:
        cur = current_note()
        if not cur:
            die("no note given and no note open in Obsidian")
        return cur
    p = Path(arg).expanduser()
    if p.is_absolute() and p.exists():
        try:
            return str(p.resolve().relative_to(VAULT.resolve()))
        except ValueError:
            die(f"{arg} is outside the vault")
    a = arg if arg.endswith(".md") else arg + ".md"
    if (VAULT / a).exists():
        return a
    low = a.lower()
    for f in md_files():
        if f.lower().endswith("/" + low) or f.lower() == low or Path(f).stem.lower() == Path(low).stem:
            return f
    die(f"note not found: {arg}")


def current_note():
    try:
        ws = json.loads((VAULT / ".obsidian/workspace.json").read_text())
    except (OSError, ValueError):
        return None
    active = ws.get("active")

    def walk(n):
        if isinstance(n, dict):
            if n.get("id") == active and n.get("type") == "leaf":
                return n
            for v in n.values():
                r = walk(v)
                if r:
                    return r
        elif isinstance(n, list):
            for v in n:
                r = walk(v)
                if r:
                    return r
        return None

    leaf = walk(ws)
    f = None
    if leaf:
        f = (leaf.get("state") or {}).get("state", {}).get("file")
    if not f or not f.endswith(".md") or not (VAULT / f).exists():
        f = next((x for x in ws.get("lastOpenFiles", []) if x.endswith(".md") and (VAULT / x).exists()), None)
    return f


def recent_notes(n=8):
    try:
        ws = json.loads((VAULT / ".obsidian/workspace.json").read_text())
        lst = [x for x in ws.get("lastOpenFiles", []) if x.endswith(".md") and (VAULT / x).exists()]
    except (OSError, ValueError):
        lst = []
    cur = current_note()
    if cur and cur in lst:
        lst.remove(cur)
    return ([cur] if cur else []) + lst[: n - 1]


def link_target(rel, all_files=None):
    """Link text in the vault's own style: [[folder/name]] when the vault uses folder links."""
    stem = rel[:-3] if rel.endswith(".md") else rel
    style = vault_link_style()
    if style == "folder" and "/" in stem:
        parts = stem.split("/")
        files = all_files or md_files()
        for k in range(2, len(parts) + 1):
            cand = "/".join(parts[-k:])
            if sum(1 for f in files if f[:-3] == cand or f[:-3].endswith("/" + cand)) == 1:
                return cand
        return stem
    return Path(stem).name


_style = None


def vault_link_style():
    global _style
    if _style is None:
        with_slash = without = 0
        for f in md_files()[:200]:
            try:
                for t in LINK_RE.findall((VAULT / f).read_text(errors="replace")):
                    if "/" in t:
                        with_slash += 1
                    else:
                        without += 1
            except OSError:
                pass
        _style = "folder" if with_slash > without else "name"
    return _style


# -------------------------------------------------------------------------------------------- LLM
def llm_chat(messages, max_tokens=800, temperature=0.3, schema=None, stream=False, on_delta=None, wait=120):
    """OpenAI-style chat with retries while the server restarts / swaps models (no model name)."""
    body = {"messages": messages, "max_tokens": max_tokens, "temperature": temperature, "stream": stream}
    if schema:
        body["response_format"] = {"type": "json_schema", "json_schema": {"name": "out", "schema": schema}}
    t_end = time.time() + wait
    first = True
    while True:
        try:
            req = urllib.request.Request(LLM + "/v1/chat/completions", json.dumps(body).encode(),
                                         {"Content-Type": "application/json"})
            r = urllib.request.urlopen(req, timeout=600)
            if not stream:
                d = json.load(r)
                return d["choices"][0]["message"]["content"]
            out = []
            for raw in r:
                ln = raw.decode("utf-8", "replace").strip()
                if not ln.startswith("data:"):
                    continue
                p = ln[5:].strip()
                if p == "[DONE]":
                    break
                try:
                    c = json.loads(p)["choices"][0]["delta"].get("content") or ""
                except (ValueError, KeyError, IndexError):
                    continue
                if c:
                    out.append(c)
                    if on_delta:
                        on_delta(c)
            return "".join(out)
        except urllib.error.HTTPError as e:
            if e.code not in (502, 503) or time.time() > t_end:
                raise RuntimeError(f"LLM error {e.code}") from e
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            if time.time() > t_end:
                raise RuntimeError("local LLM (127.0.0.1:8765) is offline — systemctl --user start npu-llm") from e
        if first:
            emit("status", msg="Waiting for the local LLM…")
            first = False
        time.sleep(2)


def llm_json(messages, schema, max_tokens=1500, temperature=0.2):
    txt = llm_chat(messages, max_tokens=max_tokens, temperature=temperature, schema=schema)
    try:
        return json.loads(txt)
    except ValueError:
        m = re.search(r"\{.*\}", txt, re.S)
        if m:
            return json.loads(m.group(0))
        raise RuntimeError("the LLM returned invalid JSON")


# ------------------------------------------------------------------------------------- embeddings
def systemctl(*a):
    return subprocess.run(["systemctl", "--user", *a], capture_output=True, text=True)


def embed_up():
    try:
        http_json(EMB + "/health", timeout=2)
        return True
    except Exception:  # noqa: BLE001
        return False


def ensure_embed():
    """Start the embedding server on demand and re-arm the 10-minute idle stop."""
    if not embed_up():
        emit("status", msg="Starting the embedding server…")
        systemctl("start", EMB_UNIT)
        t0 = time.time()
        while not embed_up():
            if time.time() - t0 > 120:
                die("embedding server did not start — journalctl --user -u ai-notes-embed")
            time.sleep(0.4)
    systemctl("restart", IDLE_TIMER)


def embed(texts, batch=4):
    ensure_embed()
    out = []
    for i in range(0, len(texts), batch):
        d = http_json(EMB + "/v1/embeddings", {"input": texts[i:i + batch]}, timeout=300)
        out += [x["embedding"] for x in sorted(d["data"], key=lambda x: x["index"])]
    a = np.asarray(out, dtype=np.float32)
    n = np.linalg.norm(a, axis=1, keepdims=True)
    return a / np.maximum(n, 1e-9)


# ------------------------------------------------------------------------------------------ index
def db():
    DATA.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DB_PATH, timeout=30)
    c.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL, size INTEGER, sha TEXT, indexed REAL);
        CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT, heading TEXT, line INTEGER,
                                          text TEXT, emb BLOB);
        CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS ecache(h TEXT PRIMARY KEY, emb BLOB, used REAL);
    """)
    return c


def chunk_note(rel, text):
    """Split by headings, then into ~token-bounded pieces on paragraph boundaries."""
    fm, body = split_frontmatter(text)
    fm_lines = fm.count("\n")
    tags = sorted(note_tags(text))
    title = title_of(rel)
    sections, cur, head, start = [], [], "", fm_lines + 1
    in_code = False
    for i, ln in enumerate(body.splitlines(), fm_lines + 1):
        if ln.lstrip().startswith("```"):
            in_code = not in_code
        m = None if in_code else re.match(r"^(#{1,6})\s+(.*)", ln)
        if m:
            if "".join(cur).strip():
                sections.append((head, start, "\n".join(cur)))
            head, cur, start = m.group(2).strip(), [ln], i
        else:
            cur.append(ln)
    if "".join(cur).strip():
        sections.append((head, start, "\n".join(cur)))
    if not sections and title:
        sections = [("", 1, title)]
    chunks = []
    for head, line, txt in sections:
        paras = re.split(r"\n\s*\n", txt.strip())
        buf, bl = [], line
        for p in paras:
            while est_tokens(p) > 600:   # very long paragraph: hard split
                cut = max(200, int(len(p) * 600 / est_tokens(p)))
                if buf:
                    chunks.append((head, bl, "\n\n".join(buf)))
                    buf = []
                chunks.append((head, bl, p[:cut]))
                p = p[cut:]
            if buf and est_tokens("\n\n".join(buf + [p])) > 450:
                chunks.append((head, bl, "\n\n".join(buf)))
                buf = []
            buf.append(p)
        if buf:
            chunks.append((head, bl, "\n\n".join(buf)))
    prefix = f"Note: {title}" + (f"\nTags: {', '.join(tags)}" if tags else "")
    return [(h, ln, t, prefix + (f"\nSection: {h}" if h else "") + "\n\n" + t) for h, ln, t in chunks if t.strip()]


def bulk_guard(n_new):
    """Bulk embedding (> 12 new chunks): hold the shared model lock and require >= 10 GB MemAvailable
    (RULES CRITICAL #2). Returns the open lock file (close it to release) or None for small jobs."""
    if n_new <= 12:
        return None
    import fcntl
    lock_path = os.environ.get("AI_NOTES_LOCK", str(HOME / "claude/.workers/gpu.lock"))
    try:
        f = open(lock_path, "a")
    except OSError:
        RUN.mkdir(parents=True, exist_ok=True)
        f = open(RUN / "bulk.lock", "a")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        emit("status", msg="Waiting for the shared model lock…")
        fcntl.flock(f, fcntl.LOCK_EX)
    avail = next(int(ln.split()[1]) for ln in open("/proc/meminfo") if ln.startswith("MemAvailable"))
    if avail < 10485760:
        f.close()
        raise RuntimeError(f"only {avail // 1024} MB RAM available (< 10 GB): not embedding {n_new} chunks now")
    return f


def stale_files(c, full=False):
    have = {p: (m, s, h) for p, m, s, h in c.execute("SELECT path, mtime, size, sha FROM files")}
    files = md_files()
    todo = []
    for f in files:
        st = (VAULT / f).stat()
        old = have.get(f)
        if full or not old or old[0] != st.st_mtime or old[1] != st.st_size:
            todo.append(f)
    gone = [p for p in have if p not in set(files)]
    return todo, gone


def update_index(full=False, quiet=False, need_embed=True):
    c = db()
    todo, gone = stale_files(c, full)
    for p in gone:
        c.execute("DELETE FROM chunks WHERE path=?", (p,))
        c.execute("DELETE FROM files WHERE path=?", (p,))
    changed = 0
    if todo:
        have_sha = dict(c.execute("SELECT path, sha FROM files"))
        work = []
        for f in todo:
            try:
                txt = (VAULT / f).read_text(errors="replace")
            except OSError:
                continue
            st = (VAULT / f).stat()
            h = sha(txt)
            if not full and have_sha.get(f) == h:   # touched but unchanged
                c.execute("UPDATE files SET mtime=?, size=? WHERE path=?", (st.st_mtime, st.st_size, f))
                continue
            work.append((f, txt, st, h))
        if work:
            if not quiet:
                emit("status", msg=f"Indexing {len(work)} note(s)…")
            work = [(f, txt, st, h, chunk_note(f, txt)) for f, txt, st, h in work]
            allh = list({sha(x[3]) for *_, ch in work for x in ch})
            known = set()
            for i in range(0, len(allh), 500):
                q = allh[i:i + 500]
                known |= {r[0] for r in c.execute(f"SELECT h FROM ecache WHERE h IN ({','.join('?' * len(q))})", q)}
            guard = bulk_guard(len(allh) - len(known))
            for f, txt, st, h, ch in work:
                # per-chunk cache: editing one paragraph re-embeds only that chunk
                hs = [sha(x[3]) for x in ch]
                cached = {h_: np.frombuffer(e, np.float32) for h_, e in
                          c.execute(f"SELECT h, emb FROM ecache WHERE h IN ({','.join('?' * len(hs))})", hs)} if hs else {}
                miss = [i for i, h_ in enumerate(hs) if h_ not in cached]
                if miss:
                    new = embed([ch[i][3] for i in miss])
                    for i, v in zip(miss, new):
                        cached[hs[i]] = v
                        c.execute("INSERT OR REPLACE INTO ecache VALUES (?,?,?)", (hs[i], v.astype(np.float32).tobytes(), time.time()))
                vecs = [cached[h_] for h_ in hs]
                c.execute("DELETE FROM chunks WHERE path=?", (f,))
                c.executemany("INSERT INTO chunks(path, heading, line, text, emb) VALUES (?,?,?,?,?)",
                              [(f, h_, ln, t, v.astype(np.float32).tobytes()) for (h_, ln, t, _), v in zip(ch, vecs)])
                c.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)", (f, st.st_mtime, st.st_size, h, time.time()))
                c.commit()
                changed += 1
            if guard:
                guard.close()
    if changed or gone:
        c.execute("DELETE FROM ecache WHERE used < ? AND h NOT IN (SELECT h FROM ecache ORDER BY used DESC LIMIT 5000)",
                  (time.time() - 30 * 86400,))
    c.execute("INSERT OR REPLACE INTO meta VALUES ('updated', ?)", (str(time.time()),))
    c.commit()
    c.close()
    return changed, len(gone)


def load_matrix(c):
    rows = c.execute("SELECT id, path, heading, line, text, emb FROM chunks").fetchall()
    if not rows:
        return rows, np.zeros((0, DIM), np.float32)
    return rows, np.vstack([np.frombuffer(r[5], np.float32) for r in rows])


def search(query, k=6, per_note=2):
    update_index(quiet=True)
    ensure_embed()
    q = embed([QUERY_INSTRUCT + query])[0]
    c = db()
    rows, M = load_matrix(c)
    c.close()
    if not rows:
        return []
    sims = M @ q
    qwords = {w.lower() for w in re.findall(r"\w{3,}", query)}
    for i, r in enumerate(rows):   # small lexical boost: title words in the question
        tw = {w.lower() for w in re.findall(r"\w{3,}", title_of(r[1]))}
        if tw and qwords & tw:
            sims[i] += 0.04 * len(qwords & tw) / len(tw)
    out, count = [], {}
    for i in np.argsort(-sims):
        r = rows[i]
        if count.get(r[1], 0) >= per_note:
            continue
        count[r[1]] = count.get(r[1], 0) + 1
        out.append({"path": r[1], "title": title_of(r[1]), "heading": r[2], "line": r[3], "text": r[4],
                    "score": round(float(sims[i]), 4), "uri": uri(r[1]), "link": link_target(r[1])})
        if len(out) >= k:
            break
    return out


# -------------------------------------------------------------------------------------------- ask
ASK_SYS = (
    "You answer questions using ONLY the user's own study notes, given as numbered excerpts. "
    "Cite the excerpts you used right after the sentence, like [1] or [2][3]. Never cite a number that is not listed. "
    "If the notes do not contain the answer, say so in one sentence and suggest what to add. "
    "Answer in the language of the question. Be concise; use short markdown (bullets, bold) when it helps.")


def cmd_ask(a):
    srcs = search(a.question, k=a.k)
    if not srcs:
        die("the index is empty — run `ai-notes index`")
    # number notes (not chunks) so one note = one citation number
    order = []
    for s in srcs:
        if s["path"] not in order:
            order.append(s["path"])
    notes = []
    for s in srcs:
        n = order.index(s["path"]) + 1
        s["n"] = n
    for i, p in enumerate(order, 1):
        first = next(s for s in srcs if s["path"] == p)
        notes.append({"n": i, "title": first["title"], "path": p, "uri": first["uri"], "link": first["link"],
                      "score": max(s["score"] for s in srcs if s["path"] == p)})
    emit("sources", sources=notes)
    ctx = "\n\n".join(
        f"[{s['n']}] {s['title']}" + (f" › {s['heading']}" if s["heading"] else "") + f"\n{s['text'][:1800]}"
        for s in srcs)
    msgs = [{"role": "system", "content": ASK_SYS},
            {"role": "user", "content": f"Notes:\n\n{ctx}\n\nQuestion: {a.question}"}]
    t0 = time.time()
    if JSONL:
        llm_chat(msgs, max_tokens=900, temperature=0.2, stream=True, on_delta=lambda d: emit("delta", text=d))
        emit("done", ms=round((time.time() - t0) * 1000))
        return
    titles = {n["n"]: n["link"] for n in notes}
    buf = [""]

    def out(d):   # replace [n] with [[note]] on the fly, holding back a partial "[12"
        buf[0] += d
        s = buf[0]
        cut = len(s)
        m = re.search(r"\[\d{0,3}$", s)
        if m:
            cut = m.start()
        sys.stdout.write(re.sub(r"\[(\d{1,3})\]", lambda m: f"[[{titles.get(int(m.group(1)), m.group(1))}]]", s[:cut]))
        sys.stdout.flush()
        buf[0] = s[cut:]
    llm_chat(msgs, max_tokens=900, temperature=0.2, stream=True, on_delta=out)
    out("\n")
    print("\nSources:")
    for n in notes:
        print(f"  [[{n['link']}]]  {n['uri']}")


def cmd_search(a):
    r = search(a.query, k=a.k, per_note=1)
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=1))
        return
    for s in r:
        print(f"{s['score']:.3f}  {s['path']}" + (f"  › {s['heading']}" if s["heading"] else ""))


def cmd_index(a):
    ch, gone = update_index(full=a.full, quiet=a.quiet)
    if not a.quiet:
        print(f"indexed {ch} note(s), removed {gone}")


def cmd_status(a):
    c = db()
    nf = c.execute("SELECT count(*) FROM files").fetchone()[0]
    nc = c.execute("SELECT count(*) FROM chunks").fetchone()[0]
    todo, gone = stale_files(c)
    c.close()
    st = {"vault": str(VAULT), "notes": nf, "chunks": nc, "stale": len(todo) + len(gone),
          "embed_server": embed_up(), "watcher": systemctl("is-active", "ai-notes-watch.service").stdout.strip(),
          "voice": voice_state(), "current": current_note(), "db_mb": round(DB_PATH.stat().st_size / 1e6, 2) if DB_PATH.exists() else 0}
    print(json.dumps(st, ensure_ascii=False, indent=None if a.json else 1))


def cmd_current(a):
    cur = current_note()
    if a.json:
        print(json.dumps({"current": cur, "title": title_of(cur) if cur else "", "recent": recent_notes(),
                          "voice": voice_state()}, ensure_ascii=False))
    else:
        print(cur or "")


# ------------------------------------------------------------------------------- links and tags
SUGGEST_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["links", "tags"],
    "properties": {
        "links": {"type": "array", "maxItems": 6, "items": {
            "type": "object", "additionalProperties": False, "required": ["n", "reason"],
            "properties": {"n": {"type": "integer"}, "reason": {"type": "string"}}}},
        "tags": {"type": "array", "maxItems": 5, "items": {"type": "string"}},
    }}


def vault_tags():
    tags = {}
    for f in md_files():
        try:
            for t in note_tags((VAULT / f).read_text(errors="replace")):
                tags[t] = tags.get(t, 0) + 1
        except OSError:
            pass
    return tags


def cmd_suggest(a):
    rel = resolve_note(a.note)
    text = (VAULT / rel).read_text(errors="replace")
    update_index(quiet=True)
    c = db()
    rows, M = load_matrix(c)
    c.close()
    mine = [i for i, r in enumerate(rows) if r[1] == rel]
    linked = {t.strip().lower() for t in LINK_RE.findall(text)}
    files = md_files()
    cands = []
    if mine:
        sims = M[[i for i in range(len(rows))]] @ M[mine].T        # chunks x my chunks
        best = {}
        for i, r in enumerate(rows):
            if r[1] == rel:
                continue
            s = float(sims[i].max())
            best[r[1]] = max(best.get(r[1], -1), s)
        for p, s in sorted(best.items(), key=lambda x: -x[1]):
            lt = link_target(p, files)
            stem = p[:-3]
            if lt.lower() in linked or stem.lower() in linked or Path(stem).name.lower() in linked:
                continue
            if Path(p).name in ("_log.md", "_index.md", "CLAUDE.md"):
                continue
            cands.append({"path": p, "title": title_of(p), "link": lt, "score": round(s, 3), "uri": uri(p)})
            if len(cands) >= 8:
                break
    have = note_tags(text)
    vt = vault_tags()
    known = sorted((t for t in vt if t not in have), key=lambda t: -vt[t])[:60]
    desc = "\n".join(f"{i}. {c_['title']} — " + re.sub(r"\s+", " ", (VAULT / c_["path"]).read_text(errors="replace")[:300])
                     for i, c_ in enumerate(cands, 1))
    body = split_frontmatter(text)[1]
    msgs = [{"role": "system", "content":
             "You help organise an Obsidian vault. Given a note and candidate related notes, pick the candidates that are "
             "genuinely related (a reader of the note would benefit from the link) and give a short reason (max 12 words, "
             "same language as the note). Then suggest 1-4 tags for the note: prefer tags from the existing list; new tags "
             "must be lowercase-kebab-case English. Do not repeat tags the note already has."},
            {"role": "user", "content": f"NOTE: {title_of(rel)}\nCurrent tags: {', '.join(sorted(have)) or 'none'}\n\n{body[:3500]}\n\n"
                                        f"CANDIDATES:\n{desc or '(none)'}\n\nExisting vault tags: {', '.join(known) or 'none'}"}]
    emit("status", msg="Asking the local LLM…")
    try:
        r = llm_json(msgs, SUGGEST_SCHEMA, max_tokens=700)
    except RuntimeError as e:
        die(str(e))
    links = []
    for l in r.get("links", []):
        n = l.get("n", 0)
        if 1 <= n <= len(cands) and cands[n - 1]["path"] not in [x["path"] for x in links]:
            links.append({**cands[n - 1], "reason": l.get("reason", "").strip()})
    tags = []
    for t in r.get("tags", []):
        t = t.strip().lstrip("#").strip()
        t = re.sub(r"\s+", "-", t)
        if t and t not in have and t not in [x["tag"] for x in tags] and re.fullmatch(r"[\w/-]{2,40}", t):
            tags.append({"tag": t, "existing": t in vt})
    res = {"note": rel, "title": title_of(rel), "links": links, "tags": tags, "candidates": cands}
    if a.json or JSONL:
        emit("result", **res) if JSONL else print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        print(f"{rel}\nLinks:")
        for l in links:
            print(f"  [[{l['link']}]]  ({l['score']})  {l['reason']}")
        print("Tags: " + " ".join("#" + t["tag"] + ("" if t["existing"] else " (new)") for t in tags))
        print("\nApply with: ai-notes apply-suggest " + json.dumps(rel) + " --link 'X' --tag 'y'")


def add_tags_frontmatter(text, tags):
    fm, body = split_frontmatter(text)
    if not tags:
        return text
    if not fm:
        return "---\ntags: [" + ", ".join(tags) + "]\n---\n" + text
    lines = fm.splitlines(keepends=True)
    for i, ln in enumerate(lines):
        m = re.match(r"^tags:\s*\[(.*)\]\s*$", ln)
        if m:
            cur = [t.strip() for t in m.group(1).split(",") if t.strip()]
            lines[i] = "tags: [" + ", ".join(cur + tags) + "]\n"
            return "".join(lines) + body
        if re.match(r"^tags:\s*$", ln):
            j = i + 1
            ind = "  "
            while j < len(lines) and re.match(r"^\s*-\s", lines[j]):
                ind = re.match(r"^(\s*)-", lines[j]).group(1)
                j += 1
            lines[j:j] = [f"{ind}- {t}\n" for t in tags]
            return "".join(lines) + body
        m = re.match(r"^tags:\s*(\S.*)$", ln)
        if m:
            lines[i] = "tags: [" + ", ".join([x.strip("#, ") for x in m.group(1).split() if x.strip("#, ")] + tags) + "]\n"
            return "".join(lines) + body
    # no tags key: insert before closing ---
    lines.insert(len(lines) - 1, "tags: [" + ", ".join(tags) + "]\n")
    return "".join(lines) + body


def add_links_section(text, links):
    if not links:
        return text
    items = "".join(f"- [[{l}]]\n" for l in links)
    m = re.search(r"^## (Related|See also|Связанные заметки|Связи)\s*$", text, re.M)
    if m:
        # append to the end of that section
        nxt = re.search(r"^#{1,2} ", text[m.end():], re.M)
        pos = m.end() + nxt.start() if nxt else len(text)
        head = text[:pos].rstrip("\n") + "\n"
        return head + items + ("\n" + text[pos:] if nxt else "")
    return text.rstrip("\n") + "\n\n## Related\n\n" + items


def backup(rel, text):
    d = DATA / "backups"
    d.mkdir(parents=True, exist_ok=True)
    name = dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + rel.replace("/", "__")
    (d / name).write_text(text)
    return d / name


def write_note(rel, new, old):
    p = VAULT / rel
    if p.read_text(errors="replace") != old:
        die("the note changed meanwhile — nothing written; run the action again")
    backup(rel, old)
    tmp = p.with_name("." + p.name + ".ai-notes.tmp")
    tmp.write_text(new)
    os.replace(tmp, p)


def cmd_apply_suggest(a):
    rel = resolve_note(a.note)
    old = (VAULT / rel).read_text(errors="replace")
    tags = [t.lstrip("#") for t in (a.tag or []) if t.strip()]
    tags = [t for t in tags if t not in note_tags(old)]
    links = [l for l in (a.link or []) if l.strip() and l.strip().lower() not in {x.lower() for x in LINK_RE.findall(old)}]
    new = add_links_section(add_tags_frontmatter(old, tags), links)
    if new == old:
        res = {"ok": True, "changed": False}
    else:
        write_note(rel, new, old)
        res = {"ok": True, "changed": True, "links": links, "tags": tags, "note": rel}
    emit("result", **res) if JSONL else print(json.dumps(res, ensure_ascii=False))


# ------------------------------------------------------------------------------------------- tidy
TIDY_SYS = (
    "You tidy one part of a Markdown note from an Obsidian vault. Return the SAME content, improved only in form:\n"
    "- fix spelling and typos in Russian and English (and obvious punctuation), keep the author's wording and language;\n"
    "- consistent Markdown: one blank line around headings and lists, '-' bullets, proper heading levels (no skipped levels), "
    "trailing spaces removed;\n"
    "- keep EVERY [[wiki link]], #tag, URL, code block, table, math, task checkbox and emoji marker exactly as is;\n"
    "- do not add, remove, summarise or translate content; do not add a title; do not wrap the answer in ``` fences.\n"
    "Output only the tidied Markdown.")


def protected_tokens(t):
    return sorted(re.findall(r"\[\[[^\]]+\]\]|https?://\S+|`[^`]+`|%%.*?%%|[📅⏳🛫➕✅❌🔁]\s*\S*", t))


def tidy_part(part):
    if not part.strip():
        return part
    out = llm_chat([{"role": "system", "content": TIDY_SYS}, {"role": "user", "content": part}],
                   max_tokens=min(3500, est_tokens(part) * 2 + 200), temperature=0.1)
    out = re.sub(r"^```(?:markdown|md)?\n(.*)\n```\s*$", r"\1", out.strip(), flags=re.S)
    # guard rails: same links/code/urls, similar length
    ratio = len(out) / max(1, len(part.strip()))
    if protected_tokens(out) != protected_tokens(part) or not (0.75 <= ratio <= 1.3):
        return None
    lead = part[: len(part) - len(part.lstrip("\n"))]
    trail = part[len(part.rstrip("\n")):]
    return lead + out.strip("\n") + trail


def split_parts(body, limit=900):
    """Split at headings into parts of at most ~limit tokens (code blocks never split)."""
    parts, cur, in_code = [], [], False
    for ln in body.splitlines(keepends=True):
        if ln.lstrip().startswith("```"):
            in_code = not in_code
        if not in_code and re.match(r"^#{1,6}\s", ln) and cur and est_tokens("".join(cur)) > 120:
            parts.append("".join(cur))
            cur = []
        cur.append(ln)
        if not in_code and est_tokens("".join(cur)) > limit and ln.strip() == "":
            parts.append("".join(cur))
            cur = []
    if cur:
        parts.append("".join(cur))
    return parts


def diff_lines(old, new):
    out = []
    for ln in difflib.unified_diff(old.splitlines(), new.splitlines(), lineterm="", n=2):
        if ln.startswith("---") or ln.startswith("+++"):
            continue
        t = "hunk" if ln.startswith("@@") else "add" if ln.startswith("+") else "del" if ln.startswith("-") else "ctx"
        out.append({"t": t, "s": ln[1:] if t != "hunk" else ln})
    return out


def cmd_tidy(a):
    rel = resolve_note(a.note)
    old = (VAULT / rel).read_text(errors="replace")
    fm, body = split_frontmatter(old)
    parts = split_parts(body)
    new_parts, kept = [], 0
    for i, p in enumerate(parts, 1):
        emit("status", msg=f"Tidying part {i}/{len(parts)}…")
        try:
            r = tidy_part(p)
        except RuntimeError as e:
            die(str(e))
        if r is None:
            kept += 1
            r = p
        new_parts.append(r)
    new = fm + "".join(new_parts)
    new = re.sub(r"[ \t]+\n", "\n", new)
    new = re.sub(r"\n{3,}", "\n\n", new)
    if not new.endswith("\n"):
        new += "\n"
    RUN.mkdir(parents=True, exist_ok=True)
    prop = RUN / f"tidy-{sha(rel)[:10]}.json"
    d = diff_lines(old, new)
    res = {"note": rel, "title": title_of(rel), "orig_sha": sha(old), "proposal": str(prop), "new": new,
           "diff": d, "added": sum(1 for x in d if x["t"] == "add"), "removed": sum(1 for x in d if x["t"] == "del"),
           "parts": len(parts), "parts_kept": kept}
    prop.write_text(json.dumps(res, ensure_ascii=False))
    if JSONL:
        emit("result", **{k: v for k, v in res.items() if k != "new"})
    elif a.json:
        print(json.dumps({k: v for k, v in res.items() if k != "new"}, ensure_ascii=False, indent=1))
    else:
        for x in d:
            col = {"add": "\033[32m+", "del": "\033[31m-", "hunk": "\033[36m", "ctx": " "}[x["t"]]
            print(f"{col}{x['s']}\033[0m" if sys.stdout.isatty() else f"{col[-1] if x['t'] != 'hunk' else ''}{x['s']}")
        print(f"\n{res['added']} added / {res['removed']} removed lines. Apply: ai-notes tidy-apply {prop}")


def cmd_tidy_apply(a):
    res = json.loads(Path(a.proposal).read_text())
    rel = res["note"]
    old = (VAULT / rel).read_text(errors="replace")
    if sha(old) != res["orig_sha"]:
        die("the note changed since the proposal — run tidy again")
    if res["new"] == old:
        out = {"ok": True, "changed": False}
    else:
        write_note(rel, res["new"], old)
        out = {"ok": True, "changed": True, "note": rel}
    emit("result", **out) if JSONL else print(json.dumps(out))


# ------------------------------------------------------------------------------------------ cards
QA_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["cards"], "properties": {
    "cards": {"type": "array", "maxItems": 12, "items": {
        "type": "object", "additionalProperties": False, "required": ["front", "back"],
        "properties": {"front": {"type": "string"}, "back": {"type": "string"}}}}}}
VOCAB_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["cards"], "properties": {
    "cards": {"type": "array", "maxItems": 15, "items": {
        "type": "object", "additionalProperties": False,
        "required": ["expression", "reading", "meaning_en", "meaning_ru", "example", "example_translation"],
        "properties": {"expression": {"type": "string"}, "reading": {"type": "string"},
                       "meaning_en": {"type": "string"}, "meaning_ru": {"type": "string"},
                       "example": {"type": "string"}, "example_translation": {"type": "string"}}}}}}


def furigana(text):
    """jocr daemon /furigana -> (anki 'kanji[kana]' string, hiragana) or (None, None)."""
    try:
        d = http_json("http://127.0.0.1:8766/furigana", {"text": text}, timeout=10)
    except Exception:  # noqa: BLE001
        return None, None
    parts = []
    for tok in d.get("tokens", []):
        for seg, kana in tok.get("ruby") or [[tok.get("surface", ""), ""]]:
            if kana and kana != seg and JA_RE.search(seg):
                parts.append((" " if parts else "") + f"{seg}[{kana}]")
            else:
                parts.append(seg)
    return "".join(parts), d.get("hiragana")


def last_ocr_text():
    run = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "jocr"
    st = sorted(run.glob("state-*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not st:
        return ""
    try:
        return ((json.loads(st[0].read_text()).get("result") or {}).get("text") or "").strip()
    except (OSError, ValueError):
        return ""


def cmd_cards(a):
    if a.ocr:
        text, rel, title = last_ocr_text(), None, "jocr OCR"
        if not text:
            die("no recent jocr OCR text")
    elif a.text:
        text, rel, title = a.text, None, "text"
    else:
        rel = resolve_note(a.note)
        text = split_frontmatter((VAULT / rel).read_text(errors="replace"))[1]
        title = title_of(rel)
    ja = len(JA_RE.findall(text)) >= 8 if a.kind == "auto" else a.kind == "vocab"
    text = text[:6000]
    emit("status", msg="Writing cards with the local LLM…")
    try:
        if ja:
            r = llm_json([{"role": "system", "content":
                           "You make Japanese vocabulary flashcards for a learner (native Russian, fluent English). "
                           "From the text pick the most useful content words (nouns, verbs in dictionary form, adjectives, set phrases) "
                           "that are worth learning, max 12, skip trivial ones (する, ある, です, これ). For each: expression as in a "
                           "dictionary, reading in hiragana, short meaning in English and in Russian, one natural example sentence in "
                           "Japanese (prefer the sentence from the text) and its translation into English (always English)."},
                          {"role": "user", "content": text}], VOCAB_SCHEMA, max_tokens=2500)
        else:
            r = llm_json([{"role": "system", "content":
                           "You make spaced-repetition flashcards from a study note. Write 4-10 atomic cards: one fact per card, "
                           "a precise question on the front, a short answer (max 25 words) on the back. Cover definitions, key "
                           "numbers, names and relationships. Same language as the note. No cards about trivia like dates of "
                           "note creation."},
                          {"role": "user", "content": f"Note: {title}\n\n{text}"}], QA_SCHEMA, max_tokens=1800)
    except RuntimeError as e:
        die(str(e))
    cards = []
    for c_ in r.get("cards", []):
        if ja:
            expr = c_["expression"].strip()
            if not expr:
                continue
            anki_reading, hira = furigana(expr)
            c_["reading_anki"] = anki_reading if anki_reading and "[" in anki_reading else (
                f"{expr}[{c_['reading']}]" if JA_RE.search(expr) and c_["reading"] and c_["reading"] != expr else expr)
            if hira:
                c_["reading"] = hira
            c_["furigana_from"] = "jocr" if anki_reading and "[" in anki_reading else "llm"
            ex_f, _ = furigana(c_["example"]) if c_["example"] else (None, None)
            c_["example_furigana"] = ex_f or c_["example"]
        cards.append(c_)
    RUN.mkdir(parents=True, exist_ok=True)
    prop = RUN / f"cards-{sha((rel or '') + text)[:10]}.json"
    res = {"note": rel, "title": title, "kind": "vocab" if ja else "qa", "cards": cards, "proposal": str(prop)}
    prop.write_text(json.dumps(res, ensure_ascii=False))
    if JSONL:
        emit("result", **res)
    elif a.json:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        for i, c_ in enumerate(cards):
            if ja:
                print(f"{i}. {c_['expression']} 【{c_['reading']}】 {c_['meaning_en']} / {c_['meaning_ru']}\n   {c_['example']} — {c_['example_translation']}")
            else:
                print(f"{i}. Q: {c_['front']}\n   A: {c_['back']}")
        print(f"\nSend: ai-notes cards-send {prop} --to anki|sr [--select 0,1,...]")


def anki_connect(action, **params):
    d = http_json(os.environ.get("ANKI_CONNECT_URL", "http://127.0.0.1:8770"),
                  {"action": action, "version": 6, "params": params}, timeout=10)
    if d.get("error"):
        raise RuntimeError(d["error"])
    return d.get("result")


def cmd_cards_send(a):
    res = json.loads(Path(a.proposal).read_text())
    cards = res["cards"]
    if a.select:
        idx = {int(x) for x in a.select.split(",") if x.strip().isdigit()}
        cards = [c_ for i, c_ in enumerate(cards) if i in idx]
    if not cards:
        die("no cards selected")
    rel, src = res.get("note"), "Obsidian: " + res.get("title", "")
    out = {"ok": True, "to": a.to, "sent": 0, "queued": 0, "duplicate": 0, "errors": []}
    if a.to == "sr":
        if not rel:
            die("SR cards need a note (they are appended to it)")
        old = (VAULT / rel).read_text(errors="replace")
        if res["kind"] == "vocab":
            lines = [f"{c_['expression']} ({c_['reading']})::{c_['meaning_en']} · {c_['meaning_ru']}<br>{c_['example']} — {c_['example_translation']}" for c_ in cards]
        else:
            lines = [f"{c_['front'].replace(chr(10), ' ')}::{c_['back'].replace(chr(10), ' ')}" for c_ in cards]
        new = old.rstrip("\n") + "\n\n## Flashcards\n\n#flashcards\n\n" + "\n".join(lines) + "\n"
        write_note(rel, new, old)
        out["sent"] = len(cards)
    elif res["kind"] == "vocab":
        for c_ in cards:
            note = {"expression": c_["expression"], "reading": c_.get("reading_anki") or c_["expression"],
                    "meaning": f"{c_['meaning_en']} · {c_['meaning_ru']}",
                    "sentence": c_["example"].replace(c_["expression"], f"<b>{c_['expression']}</b>", 1),
                    "sentence_translation": c_["example_translation"], "source": src,
                    "tags": ["ai-notes", "obsidian"]}
            if a.deck:
                note["deck"] = a.deck
            p = subprocess.run([str(HOME / ".local/bin/anki-add")] + (["--deck", a.deck] if a.deck else []),
                               input=json.dumps(note, ensure_ascii=False), capture_output=True, text=True)
            st = (json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}).get("status", "error")
            key = {"added": "sent", "queued": "queued", "duplicate": "duplicate"}.get(st)
            if key:
                out[key] += 1
            else:
                out["errors"].append(p.stderr.strip()[-200:] or st)
    else:
        deck = a.deck or "Obsidian::" + (Path(rel).parts[0] if rel and len(Path(rel).parts) > 1 else "Notes")
        try:
            anki_connect("createDeck", deck=deck)
            for c_ in cards:
                try:
                    anki_connect("addNote", note={"deckName": deck, "modelName": "Basic",
                                                  "fields": {"Front": c_["front"], "Back": c_["back"]},
                                                  "tags": ["ai-notes", "obsidian"], "options": {"allowDuplicate": False}})
                    out["sent"] += 1
                except RuntimeError as e:
                    if "duplicate" in str(e):
                        out["duplicate"] += 1
                    else:
                        out["errors"].append(str(e))
        except (urllib.error.URLError, ConnectionError, OSError):
            die("Anki is not running (AnkiConnect :8770). Start Anki, or use “Append to note (SR)”.")
    out["ok"] = not out["errors"]
    emit("result", **out) if JSONL else print(json.dumps(out, ensure_ascii=False))


# ------------------------------------------------------------------------------------------ voice
VOICE_WAV = RUN / "voice.wav"
VOICE_PID = RUN / "voice.pid"
VOICE_STATE = RUN / "voice.json"


def voice_state():
    try:
        st = json.loads(VOICE_STATE.read_text())
    except (OSError, ValueError):
        return {"phase": "idle"}
    if st.get("phase") == "recording":
        try:
            os.kill(int(VOICE_PID.read_text()), 0)
        except (OSError, ValueError):
            return {"phase": "idle"}
    return st


def set_voice(**kw):
    RUN.mkdir(parents=True, exist_ok=True)
    VOICE_STATE.write_text(json.dumps(kw, ensure_ascii=False))


def voice_start():
    if voice_state().get("phase") == "recording":
        return {"ok": True, "phase": "recording"}
    RUN.mkdir(parents=True, exist_ok=True)
    VOICE_WAV.unlink(missing_ok=True)
    p = subprocess.Popen(["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", str(VOICE_WAV)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    VOICE_PID.write_text(str(p.pid))
    set_voice(phase="recording", t0=time.time())
    notify("Recording a voice note…", "Mod+Shift+N → Stop, or `ai-notes voice stop`", "-t", "4000")
    return {"ok": True, "phase": "recording"}


def read_pcm(path):
    raw = Path(path).read_bytes()
    try:
        with wave.open(str(path)) as w:
            return np.frombuffer(w.readframes(w.getnframes()), np.int16)
    except (wave.Error, EOFError):
        return np.frombuffer(raw[44:len(raw) - (len(raw) - 44) % 2], np.int16)


def segments(pcm, sr=16000, max_s=28.0, min_s=12.0):
    """Cut long audio into <=28 s pieces at the quietest 0.3 s window after 12 s."""
    out, i, n = [], 0, len(pcm)
    win = int(0.3 * sr)
    while n - i > max_s * sr:
        lo, hi = i + int(min_s * sr), i + int(max_s * sr)
        x = pcm[lo:hi].astype(np.float32)
        k = (len(x) // win) * win
        e = (x[:k].reshape(-1, win) ** 2).mean(axis=1)
        cut = lo + int(np.argmin(e)) * win + win // 2
        out.append(pcm[i:cut])
        i = cut
    out.append(pcm[i:])
    return [s for s in out if len(s) > 0.4 * sr]


def transcribe(pcm, lang=None):
    """Whisper (NPU) through the dictation daemon's transcribe-only file API: `aidict file X.wav` (never types)."""
    texts = []
    segs = segments(pcm)
    for j, s in enumerate(segs):
        emit("status", msg=f"Transcribing {j + 1}/{len(segs)}…")
        f = RUN / f"voice-seg{j}.wav"
        with wave.open(str(f), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(s.astype(np.int16).tobytes())
        p = subprocess.run([str(HOME / ".local/bin/aidict"), "file", str(f)] + ([lang] if lang else []),
                           capture_output=True, text=True, timeout=600)
        f.unlink(missing_ok=True)
        try:
            r = json.loads(p.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise RuntimeError("dictation daemon failed: " + (p.stderr.strip()[-200:] or "no output"))
        t = (r.get("text") or "").strip()
        if t and t.strip(" .!?。！").lower() not in ("you", "thank you", "thanks for watching", "продолжение следует"):
            texts.append(t)
    return " ".join(texts).strip()


NOTE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["title", "tags", "markdown"],
               "properties": {"title": {"type": "string"}, "tags": {"type": "array", "maxItems": 5, "items": {"type": "string"}},
                              "markdown": {"type": "string"}}}


def structure_note(transcript):
    return llm_json([{"role": "system", "content":
                      "Turn a raw speech transcript (a lecture, idea or memo; may contain recognition errors) into a clean, "
                      "structured Obsidian note in the SAME language as the transcript. Give: a short title (max 8 words, no "
                      "date), 1-4 lowercase-kebab-case English tags, and Markdown with: '## Summary' (2-4 sentences), then "
                      "topical '##' sections with bullet points, '## Key terms' (bold term — short definition) when there are "
                      "any, and '## Action items' as '- [ ]' tasks ONLY for things the speaker explicitly says must be done (otherwise omit the "
                      "section). Fix obvious recognition errors. Do not add facts, names or context that are not in the transcript. Do not include the title as a heading."},
                     {"role": "user", "content": transcript[:12000]}], NOTE_SCHEMA, max_tokens=2500, temperature=0.2)


def safe_name(s):
    s = re.sub(r'[\\/:*?"<>|#^\[\]]', " ", s).strip()
    return re.sub(r"\s+", " ", s)[:70] or "Voice note"


def voice_stop(lang=None, folder="Voice notes", wav=None, open_note=True):
    if wav is None:
        st = voice_state()
        if st.get("phase") != "recording":
            return {"ok": False, "error": "not recording"}
        try:
            os.kill(int(VOICE_PID.read_text()), signal.SIGINT)
        except (OSError, ValueError):
            pass
        time.sleep(0.4)
        wav = VOICE_WAV
        rec_s = time.time() - st.get("t0", time.time())
    else:
        rec_s = 0
    set_voice(phase="transcribing")
    try:
        pcm = read_pcm(wav)
        if len(pcm) < 16000 * 0.5:
            raise RuntimeError("recording too short")
        t0 = time.time()
        text = transcribe(pcm, lang)
        asr_s = time.time() - t0
        if not text:
            raise RuntimeError("nothing recognised")
        set_voice(phase="writing", transcript=text[:400])
        emit("status", msg="Structuring the note…")
        r = structure_note(text)
        now = dt.datetime.now()
        title = safe_name(r.get("title") or "Voice note")
        body = re.sub(r"^\s*#\s+[^\n]*\n+", "", r["markdown"].strip()).strip()   # the model sometimes repeats the title
        rel = f"{folder}/{now:%Y-%m-%d %H%M} {title}.md"
        tags = ["voice-note"] + [re.sub(r"\s+", "-", t.strip().lstrip("#")) for t in r.get("tags", []) if t.strip()]
        md = (f"---\ncreated: {now:%Y-%m-%dT%H:%M}\nsource: voice\nduration: {len(pcm) / 16000:.0f}s\n"
              f"tags: [{', '.join(dict.fromkeys(tags))}]\n---\n\n# {title}\n\n{body}\n\n"
              f"> [!quote]- Transcript\n> " + text.replace("\n", "\n> ") + "\n")
        p = VAULT / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists():
            p = p.with_name(p.stem + f" {now:%S}.md")
            rel = str(p.relative_to(VAULT))
        p.write_text(md)
        res = {"ok": True, "note": rel, "uri": uri(rel), "title": title, "audio_s": round(len(pcm) / 16000, 1),
               "asr_s": round(asr_s, 1), "chars": len(text)}
        set_voice(phase="done", **res)
        if open_note:
            subprocess.Popen(["xdg-open", uri(rel)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            notify("Voice note saved", f"{title}\n{rel}")
        return res
    except Exception as e:  # noqa: BLE001
        set_voice(phase="error", error=str(e))
        notify("Voice note failed", str(e))
        return {"ok": False, "error": str(e)}
    finally:
        if wav == VOICE_WAV:
            VOICE_WAV.unlink(missing_ok=True)


def cmd_voice(a):
    act = a.action
    if act == "toggle":
        act = "stop" if voice_state().get("phase") == "recording" else "start"
    if act == "start":
        r = voice_start()
    elif act == "stop":
        r = voice_stop(a.lang, a.folder, open_note=not a.no_open)
    elif act == "cancel":
        try:
            os.kill(int(VOICE_PID.read_text()), signal.SIGINT)
        except (OSError, ValueError):
            pass
        VOICE_WAV.unlink(missing_ok=True)
        set_voice(phase="idle")
        r = {"ok": True, "phase": "idle"}
    elif act == "file":   # test hook: a WAV instead of the mic
        r = voice_stop(a.lang, a.folder, wav=Path(a.wav), open_note=not a.no_open)
    else:
        r = voice_state()
    emit("result", **r) if JSONL else print(json.dumps(r, ensure_ascii=False))
    if r.get("ok") is False:
        sys.exit(1)


# ----------------------------------------------------------------------------------------- weekly
DONE_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[[xX]\]\s+(.*)$")
OPEN_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[[ /]\]\s+(.*)$")
DATE = r"(\d{4}-\d{2}-\d{2})"


def daily_cfg():
    try:
        c = json.loads((VAULT / ".obsidian/daily-notes.json").read_text())
    except (OSError, ValueError):
        c = {}
    return (c.get("folder") or "").strip("/"), c.get("format") or "YYYY-MM-DD"


def daily_rel(d):
    folder, fmt = daily_cfg()
    name = (fmt.replace("YYYY", f"{d.year:04d}").replace("MM", f"{d.month:02d}").replace("DD", f"{d.day:02d}")
            .replace("ddd", d.strftime("%a")))
    return (folder + "/" if folder else "") + name + ".md"


def clean_task(t):
    t = re.sub(r"%%.*?%%", "", t)
    t = re.sub(r"[📅⏳🛫➕✅❌🕒]\s*[\d:–-]+(?:\s*[\d:–-]+)?", "", t)
    t = re.sub(r"\(@[\d-]+(?:\s+[\d:]+)?\)", "", t)
    return re.sub(r"\s+", " ", t).strip()


def cmd_weekly(a):
    today = dt.date.today()
    if a.week:
        y, w = a.week.upper().split("-W")
        mon = dt.date.fromisocalendar(int(y), int(w), 1)
    else:
        mon = today - dt.timedelta(days=today.weekday())
    days = [mon + dt.timedelta(days=i) for i in range(7)]
    sun = days[-1]
    iso = mon.isocalendar()
    wk = f"{iso[0]}-W{iso[1]:02d}"
    daily = []
    for d in days:
        p = VAULT / daily_rel(d)
        if p.exists():
            daily.append((d, daily_rel(d), split_frontmatter(p.read_text(errors="replace"))[1].strip()))
    done, overdue, upcoming = [], [], []
    for f in md_files():
        try:
            lines = (VAULT / f).read_text(errors="replace").splitlines()
        except OSError:
            continue
        for ln in lines:
            m = DONE_RE.match(ln)
            if m:
                dm = re.search(r"✅\s*" + DATE, ln)
                dd = dt.date.fromisoformat(dm.group(1)) if dm else None
                if dd is None and f in [x[1] for x in daily]:
                    dd = next(x[0] for x in daily if x[1] == f)
                if dd and mon <= dd <= sun:
                    done.append({"task": clean_task(m.group(1)), "date": dd.isoformat(), "note": f})
                continue
            m = OPEN_RE.match(ln)
            if m:
                dm = re.search(r"(?:📅|due::?)\s*" + DATE, ln) or re.search(r"\(@" + DATE, ln)
                if dm:
                    dd = dt.date.fromisoformat(dm.group(1))
                    item = {"task": clean_task(m.group(1)), "due": dd.isoformat(), "note": f}
                    if dd < min(today, sun + dt.timedelta(days=1)):
                        overdue.append(item)
                    elif sun < dd <= sun + dt.timedelta(days=7):
                        upcoming.append(item)
    events, nxt = [], []
    try:
        ev = json.loads((HOME / ".cache/gcal-sync/events.json").read_text()).get("events", [])
    except (OSError, ValueError):
        ev = []
    for e in ev:
        sd = dt.date.fromisoformat(e["startDate"])
        rec = {"title": e.get("title", ""), "date": e["startDate"], "time": "" if e.get("allDay") else e["start"][11:16],
               "calendar": e.get("calendar", "")}
        if mon <= sd <= sun:
            rec["happened"] = e.get("endMs", 0) / 1000 < time.time()
            if not any((x["date"], x["time"], x["title"]) == (rec["date"], rec["time"], rec["title"]) for x in events):
                events.append(rec)
        elif sun < sd <= sun + dt.timedelta(days=7):
            nxt.append(rec)
    facts = {"week": wk, "from": mon.isoformat(), "to": sun.isoformat(), "now": dt.datetime.now().strftime("%Y-%m-%d %H:%M"),
             "daily_notes": [{"date": d.isoformat(), "text": t[:1500]} for d, _, t in daily],
             "done_tasks": done[:60], "overdue_tasks": overdue[:40],
             "past_events_this_week": [{k: v for k, v in e.items() if k != "happened"} for e in events if e["happened"]][:60],
             "still_upcoming_this_week": [{k: v for k, v in e.items() if k != "happened"} for e in events if not e["happened"]][:40],
             "next_week_events": nxt[:40], "next_week_tasks": upcoming[:30]}
    emit("status", msg="Summarising the week…")
    try:
        summary = llm_chat([{"role": "system", "content":
                             "Write the body of a weekly review note for the user's Obsidian vault from the JSON facts. "
                             "Sections (Markdown '##'): 'Summary' (3-5 sentences: what the week was about, what got done, how it went), "
                             "'Highlights' (bullets, max 8, most important events/notes/achievements), "
                             "'Carry over' (overdue or unfinished things that need attention, as '- [ ]' tasks; omit if none), "
                             "'Next week' (bullets with the important upcoming events/deadlines with dates; omit if none). "
                             "Only past_events_this_week happened; still_upcoming_this_week have NOT happened yet: never say they were attended "
                             "or completed — list them under 'Next week' as still ahead (or omit). Write tasks as clean short text without emoji/date markers or %%comments%%. "
                             "Use only the facts; do not invent. Write in English, keep Russian/Japanese names as they are. "
                             "No title heading."},
                            {"role": "user", "content": json.dumps(facts, ensure_ascii=False)[:14000]}],
                           max_tokens=1200, temperature=0.3)
    except RuntimeError as e:
        die(str(e))
    folder = a.folder.strip("/")
    rel = f"{folder}/{wk}.md" if folder else f"{wk}.md"
    lines = [f"---\ntype: weekly-review\nweek: {wk}\nfrom: {mon}\nto: {sun}\ncreated: {dt.datetime.now():%Y-%m-%dT%H:%M}\n"
             f"tags: [weekly-review]\n---\n", f"# Week {iso[1]} · {mon:%d %b} – {sun:%d %b %Y}\n", summary.strip(), ""]
    lines.append("## Daily notes\n")
    lines += [f"- [[{daily_rel(d)[:-3]}|{d:%a %d %b}]]" for d, _, _ in daily] or ["- none this week"]
    lines.append("\n## Done this week\n")
    lines += [f"- [x] {t['task']} ✅ {t['date']}" for t in done] or ["- nothing ticked this week"]
    if events:
        lines.append("\n## Calendar\n")
        lines += [f"- {e['date']} {e['time']} {e['title']}".replace("  ", " ") for e in sorted(events, key=lambda e: (e["date"], e["time"]))]
    md = "\n".join(lines).rstrip() + "\n"
    res = {"week": wk, "note": rel, "uri": uri(rel), "exists": (VAULT / rel).exists(), "written": False,
           "counts": {"daily": len(daily), "done": len(done), "overdue": len(overdue), "events": len(events), "next": len(nxt)},
           "markdown": md}
    RUN.mkdir(parents=True, exist_ok=True)
    prop = RUN / f"weekly-{wk}.json"
    res["proposal"] = str(prop)
    prop.write_text(json.dumps(res, ensure_ascii=False))
    if a.write:
        p = VAULT / rel
        if p.exists() and not a.force:
            res["error"] = "exists (use --force to overwrite)"
        else:
            if p.exists():
                backup(rel, p.read_text(errors="replace"))
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(md)
            res["written"] = True
            if a.notify:
                notify(f"Weekly review {wk} written", rel)
    if JSONL:
        emit("result", **res)
    elif a.json:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        print(md)
        print(f"-> {rel}: " + ("written" if res["written"] else res.get("error", "preview only (add --write)")), file=sys.stderr)


def cmd_weekly_write(a):
    """Write a weekly preview made earlier (the panel shows the preview first; no second LLM run)."""
    res = json.loads(Path(a.proposal).read_text())
    p = VAULT / res["note"]
    out = {"ok": True, "note": res["note"], "uri": res["uri"], "written": False}
    if p.exists() and not a.force:
        out.update(ok=False, error="exists")
    else:
        if p.exists():
            backup(res["note"], p.read_text(errors="replace"))
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(res["markdown"])
        out["written"] = True
    emit("result", **out) if JSONL else print(json.dumps(out, ensure_ascii=False))


# ------------------------------------------------------------------------------------------ watch
def cmd_watch(a):
    """inotify (no polling). After 20 s of quiet: re-index now if the embedding server is up,
    otherwise just leave it — the next ask/suggest indexes the changed notes incrementally.
    AI_NOTES_EAGER=1 always indexes (starts the embedding server)."""
    eager = os.environ.get("AI_NOTES_EAGER") == "1"
    debounce = float(os.environ.get("AI_NOTES_DEBOUNCE", "20"))
    p = subprocess.Popen(["inotifywait", "-m", "-r", "-q", "--format", "%w%f",
                          "-e", "close_write,moved_to,moved_from,delete,create",
                          "--exclude", r"(/\.obsidian/|/\.trash/|/\.git/|\.ai-notes\.tmp$)", str(VAULT)],
                         stdout=subprocess.PIPE, text=True, bufsize=1)
    pending = set()
    deadline = None
    while True:
        timeout = None if deadline is None else max(0.0, deadline - time.time())
        r, _, _ = select.select([p.stdout], [], [], timeout)
        if r:
            ln = p.stdout.readline()
            if not ln:
                sys.exit(1)
            if ln.strip().endswith(".md") or os.path.isdir(ln.strip()):
                pending.add(ln.strip())
                deadline = time.time() + debounce
            continue
        if pending:
            n = len(pending)
            pending.clear()
            deadline = None
            if eager or embed_up():
                try:
                    ch, gone = update_index(quiet=True)
                    print(f"{dt.datetime.now():%H:%M:%S} {n} change(s) -> indexed {ch}, removed {gone}", flush=True)
                except Exception as e:  # noqa: BLE001
                    print("index error:", e, flush=True)
            else:
                c = db()
                ch, gone = stale_files(c)
                for g in gone:   # deletions need no embeddings
                    c.execute("DELETE FROM chunks WHERE path=?", (g,))
                    c.execute("DELETE FROM files WHERE path=?", (g,))
                c.commit()
                c.close()
                print(f"{dt.datetime.now():%H:%M:%S} {n} change(s): {len(ch)} note(s) queued for the next query", flush=True)


# ------------------------------------------------------------------------------------------- main
def main():
    global JSONL
    ap = argparse.ArgumentParser(prog="ai-notes", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jsonl", action="store_true", help="machine-readable event lines (for the panel)")
    sp = ap.add_subparsers(dest="cmd")
    p = sp.add_parser("ask"); p.add_argument("question"); p.add_argument("-k", type=int, default=8)
    p = sp.add_parser("search"); p.add_argument("query"); p.add_argument("-k", type=int, default=8); p.add_argument("--json", action="store_true")
    p = sp.add_parser("index"); p.add_argument("--full", action="store_true"); p.add_argument("--quiet", action="store_true")
    p = sp.add_parser("status"); p.add_argument("--json", action="store_true")
    p = sp.add_parser("current"); p.add_argument("--json", action="store_true")
    p = sp.add_parser("suggest"); p.add_argument("note", nargs="?"); p.add_argument("--json", action="store_true")
    p = sp.add_parser("apply-suggest"); p.add_argument("note"); p.add_argument("--link", action="append"); p.add_argument("--tag", action="append")
    p = sp.add_parser("tidy"); p.add_argument("note", nargs="?"); p.add_argument("--json", action="store_true")
    p = sp.add_parser("tidy-apply"); p.add_argument("proposal")
    p = sp.add_parser("cards"); p.add_argument("note", nargs="?"); p.add_argument("--text"); p.add_argument("--ocr", action="store_true")
    p.add_argument("--kind", choices=["auto", "vocab", "qa"], default="auto"); p.add_argument("--json", action="store_true")
    p = sp.add_parser("cards-send"); p.add_argument("proposal"); p.add_argument("--to", choices=["anki", "sr"], default="anki")
    p.add_argument("--select"); p.add_argument("--deck")
    p = sp.add_parser("voice"); p.add_argument("action", choices=["start", "stop", "toggle", "cancel", "status", "file"])
    p.add_argument("wav", nargs="?"); p.add_argument("--lang", choices=["en", "ru", "ja"]); p.add_argument("--folder", default="Voice notes")
    p.add_argument("--no-open", action="store_true")
    p = sp.add_parser("weekly"); p.add_argument("--week"); p.add_argument("--write", action="store_true"); p.add_argument("--force", action="store_true")
    p.add_argument("--json", action="store_true"); p.add_argument("--folder", default="Weekly"); p.add_argument("--notify", action="store_true")
    p = sp.add_parser("weekly-write"); p.add_argument("proposal"); p.add_argument("--force", action="store_true")
    sp.add_parser("watch")
    # allow --jsonl anywhere
    argv = sys.argv[1:]
    if "--jsonl" in argv:
        argv.remove("--jsonl")
        JSONL = True
    a = ap.parse_args(argv)
    if not a.cmd:
        ap.print_help()
        return
    if not VAULT.is_dir():
        die(f"vault not found: {VAULT}")
    fn = {"ask": cmd_ask, "search": cmd_search, "index": cmd_index, "status": cmd_status, "current": cmd_current,
          "suggest": cmd_suggest, "apply-suggest": cmd_apply_suggest, "tidy": cmd_tidy, "tidy-apply": cmd_tidy_apply,
          "cards": cmd_cards, "cards-send": cmd_cards_send, "voice": cmd_voice, "weekly": cmd_weekly,
          "weekly-write": cmd_weekly_write, "watch": cmd_watch}[a.cmd]
    try:
        fn(a)
    except RuntimeError as e:
        die(str(e))
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
