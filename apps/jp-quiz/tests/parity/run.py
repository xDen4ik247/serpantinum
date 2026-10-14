#!/usr/bin/env python3
"""Lockstep differential test: the Python engine and the Rust engine get the same requests and must
give byte-identical replies and leave identical progress databases.

  run.py --rust BIN --content DB [--progress DB|fresh] [--n 400] [--seed 7] OUT

A seeded "player" drives both: it asks for questions, peeks at the right answer and answers right,
wrong, skipped or too slowly; opens stats and the grammar tab, changes settings (target, language,
a grammar drill, auto-add to Anki), adds cards through a stand-in anki-add helper, syncs with a
stand-in AnkiConnect, and sends malformed lines. The clock is fake and jumps across days.
The progress DB is always a copy: the real one is never opened for writing.
"""
import argparse, json, os, random, shutil, sqlite3, subprocess, sys, time

H = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(H, "..", ".."))


def backup(src, dst):
    s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    d = sqlite3.connect(dst)
    s.backup(d)
    d.close()
    s.close()


def anki_cards(content):
    """Fake Anki decks: known / weak / learning words that exist in the quiz (one card kind each)."""
    c = sqlite3.connect(f"file:{content}?mode=ro", uri=True)
    kcs = [k for (k,) in c.execute("SELECT DISTINCT kc FROM items WHERE kc LIKE 'use:%' OR kc LIKE 'read:%' OR kc LIKE 'write:%'")]
    by_word = {}
    for k in kcs:
        by_word.setdefault(k.split(":", 1)[1], []).append(k)
    single = sorted(w for w, ks in by_word.items() if len(ks) == 1 and 1 <= len(w) <= 6)
    rng = random.Random(1)
    words = rng.sample(single, 9)
    cards = []
    for i, w in enumerate(words):
        iv, lapses = [(40, 0), (120, 1), (30, 0), (5, 7), (2, 5), (3, 1), (60, 0), (25, 4), (1, 0)][i]
        cards.append({"deckName": "Japanese::Core", "interval": iv, "lapses": lapses, "factor": 2500, "reps": 9,
                      "fields": {"Meaning": {"value": "meaning", "order": 1}, "Word": {"value": f"<b>{w}</b>", "order": 0}}})
    cards.append({"deckName": "Japanese::Core", "interval": 50, "lapses": 0, "fields": {"Front": {"value": "hello", "order": 0}}})
    cards.append({"deckName": "Japanese::Core", "interval": 50, "lapses": 0,
                  "fields": {"Expression": {"value": f"{words[0]}[よみ]&nbsp;", "order": 0}}})
    return {"decks": ["Default", "Japanese::Core", "Japanese::Quiz", "Japanese::Quiz::Old"], "cards": cards}


class Side:
    def __init__(self, name, cmd, out, content, progress_src, seed, anki_url):
        self.name = name
        self.dir = os.path.join(out, name)
        os.makedirs(self.dir, exist_ok=True)
        self.progress = os.path.join(self.dir, "progress.db")
        if progress_src != "fresh":
            backup(progress_src, self.progress)
        shutil.copy(os.path.join(H, "anki_add_shim.sh"), os.path.join(self.dir, "anki-add"))
        env = dict(os.environ, JPQUIZ_DATA=self.dir, JPQUIZ_CONTENT=content, JPQUIZ_PROGRESS=self.progress,
                   JPQUIZ_SEED=str(seed), JPQUIZ_TEST_CLOCK="1", JPQUIZ_TEST_NOW="1791824000.25", JPQUIZ_ANKI_ADD=os.path.join(self.dir, "anki-add"),
                   JPQUIZ_ANKI_URL=anki_url, JPQUIZ_APP=REPO, PYTHONHASHSEED="0", TZ=os.environ.get("TZ", "Asia/Tokyo"))
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True, bufsize=1, cwd=self.dir)
        self.wall = 0.0

    def ask(self, line):
        t0 = time.perf_counter()
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        out = self.p.stdout.readline()
        self.wall += time.perf_counter() - t0
        return out.rstrip("\n")

    def usage(self):
        st = open(f"/proc/{self.p.pid}/stat").read().rsplit(")", 1)[1].split()
        cpu = (int(st[11]) + int(st[12])) / os.sysconf("SC_CLK_TCK")
        hwm = next(int(l.split()[1]) for l in open(f"/proc/{self.p.pid}/status") if l.startswith("VmHWM"))
        return cpu, hwm / 1024


def dump_db(path):
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    out = []
    for t in ("comp", "card", "answers", "unlock", "days", "kv"):
        out += [f"{t} {r!r}" for r in sorted(c.execute(f"SELECT * FROM {t}").fetchall(), key=repr)]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", required=True)
    ap.add_argument("--content", required=True)
    ap.add_argument("--progress", default="fresh")
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--port", type=int, default=18770)
    ap.add_argument("out")
    a = ap.parse_args()
    a.rust = os.path.abspath(a.rust)
    shutil.rmtree(a.out, ignore_errors=True)
    os.makedirs(a.out)
    cards_json = os.path.join(a.out, "anki-cards.json")
    json.dump(anki_cards(a.content), open(cards_json, "w"), ensure_ascii=False)
    fake = subprocess.Popen([sys.executable, os.path.join(H, "fake_anki.py"), str(a.port), cards_json],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        session(a, cards_json, fake)
    finally:
        fake.terminate()


def session(a, cards_json, fake):
    time.sleep(0.4)
    url = f"http://127.0.0.1:{a.port}"
    py = Side("python", [sys.executable, "-I", os.path.join(H, "ref_server.py")], a.out, a.content, a.progress, a.seed, url)
    rs = Side("rust", [a.rust], a.out, a.content, a.progress, a.seed, url)
    rng = random.Random(a.seed + 1000)
    stats = {"requests": 0, "mismatches": 0, "kinds": {}, "types": {}}
    first_diffs = []
    t = 1791824400.0      # 2026-10-12 06:00 UTC
    rid = [0]

    def send(req, raw=None):
        rid[0] += 1
        if raw is None:
            req = dict(req, rid=rid[0], _now=t)
            line = json.dumps(req, ensure_ascii=False)
        else:
            line = raw
        a_, b_ = py.ask(line), rs.ask(line)
        stats["requests"] += 1
        pa, pb = json.loads(a_), json.loads(b_)
        same = a_ == b_ if pa.get("type") != "error" else (pb.get("type") == "error" and pa.get("rid") == pb.get("rid"))
        stats["types"][pa.get("type")] = stats["types"].get(pa.get("type"), 0) + 1
        if not same:
            stats["mismatches"] += 1
            if len(first_diffs) < 5:
                first_diffs.append({"request": line, "python": a_[:3000], "rust": b_[:3000]})
        return pa

    gp_ids = []
    last_key = None
    send({"cmd": "hello"})
    send({"cmd": "peek"})
    for step in range(a.n):
        t += rng.uniform(2, 30)
        r = rng.random()
        if r < 0.01:
            t += rng.choice([5 * 3600, 86400, 3 * 86400, 9 * 86400])
        q = send({"cmd": "next"})
        guard = 0
        while q.get("type") == "intro" and guard < 5:
            q = send({"cmd": "next"})
            guard += 1
        if q.get("type") != "question":
            continue
        stats["kinds"][q["kind"]] = stats["kinds"].get(q["kind"], 0) + 1
        pk = send({"cmd": "peek"})
        budget = q["budget"]
        ms = int(rng.uniform(900, budget * 1000 * (1.4 if rng.random() < 0.1 else 0.8)))
        t += ms / 1000
        r = rng.random()
        if r < 0.05:
            res = send({"cmd": "skip", "qid": q["qid"], "ms": ms})
        elif q["kind"] == "order":
            tiles = list(pk["correct"]) if r < 0.75 else list(reversed(q["ui"]["tiles"]))
            res = send({"cmd": "answer", "qid": q["qid"], "order": tiles, "ms": ms})
        else:
            n = len(q["ui"]["choices"])
            choice = pk["correct"] if r < 0.72 else (pk["correct"] + 1 + rng.randrange(n - 1)) % n
            if rng.random() < 0.03:
                choice = str(choice)              # the UI may send strings; int() handles them
            res = send({"cmd": "answer", "qid": q["qid"], "choice": choice, "ms": ms})
        last_key = res.get("key", last_key)
        # the rest of the UI, now and then
        if step % 37 == 5:
            send({"cmd": "stats"})
        if step % 53 == 9:
            g = send({"cmd": "grammar"})
            gp_ids = [p["id"] for p in g.get("points", [])]
        if gp_ids and step % 29 == 11:
            send({"cmd": "grammar_example", "id": rng.choice(gp_ids)})
        if step % 61 == 20:
            send({"cmd": "anki_add"})
        if step % 71 == 33 and last_key:
            send({"cmd": "anki_add", "key": last_key})
        if step % 97 == 40:
            send({"cmd": "anki_add", "key": "no-such-item"})
        if step == a.n // 3:
            send({"cmd": "anki_sync"})
            send({"cmd": "settings", "set": {"anki_auto": True, "lang": "ru", "bogus": 1}})
        if step == a.n // 2 and gp_ids:
            send({"cmd": "settings", "set": {"focus_gp": gp_ids[len(gp_ids) // 2], "target": 1.5}})
        if step == a.n // 2 + 25:
            send({"cmd": "settings", "set": {"focus_gp": None, "target": 0.7}})
        if step == a.n // 2 + 30:
            send({"cmd": "settings", "set": {"focus_gp": "no-such-point"}})
        if step % 83 == 17:
            send(None, raw="this is not json")
            send(None, raw="[1, 2, 3]")
            send({"cmd": "bogus"})
            send({"cmd": "answer", "qid": -5, "choice": 0})
            send({"cmd": "skip", "qid": 999999})
    send({"cmd": "anki_sync"})
    send({"cmd": "stats"})
    send({"cmd": "grammar"})
    send({"cmd": "hello"})
    usage = {"python": py.usage(), "rust": rs.usage()}
    for s in (py, rs):
        s.p.stdin.write(json.dumps({"cmd": "quit"}) + "\n")
        s.p.stdin.flush()
        s.p.wait(timeout=30)
    fake.terminate()
    db_py, db_rs = dump_db(py.progress), dump_db(rs.progress)
    db_same = db_py == db_rs
    files = {}
    for f in ("anki-queue.jsonl", "added.jsonl"):
        a_ = open(os.path.join(py.dir, f)).read() if os.path.exists(os.path.join(py.dir, f)) else None
        b_ = open(os.path.join(rs.dir, f)).read() if os.path.exists(os.path.join(rs.dir, f)) else None
        files[f] = a_ == b_
    violations = os.path.exists(cards_json + ".violations")
    report = {"requests": stats["requests"], "mismatches": stats["mismatches"], "db_rows": len(db_rs), "db_same": db_same,
              "files_same": files, "anki_write_attempts": violations, "question_kinds": stats["kinds"],
              "reply_types": stats["types"],
              "python": {"cpu_s": round(usage["python"][0], 2), "peak_rss_mb": round(usage["python"][1], 1), "wall_s": round(py.wall, 2)},
              "rust": {"cpu_s": round(usage["rust"][0], 2), "peak_rss_mb": round(usage["rust"][1], 1), "wall_s": round(rs.wall, 2)},
              "first_diffs": first_diffs}
    if not db_same:
        import difflib
        report["db_diff"] = list(difflib.unified_diff(db_py, db_rs, lineterm="", n=0))[:20]
    json.dump(report, open(os.path.join(a.out, "report.json"), "w"), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in report.items() if k != "first_diffs"}, ensure_ascii=False, indent=1))
    for d in first_diffs[:2]:
        print("--- request:", d["request"][:300])
        print("python:", d["python"][:1500])
        print("rust:  ", d["rust"][:1500])
    ok = stats["mismatches"] == 0 and db_same and all(files.values()) and not violations
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
