"""A stand-in for the Yandex Music worker (glassmusic.yandex serve) for the parity test: same JSON-lines
protocol, no network. "Downloads" copy a test file into the library or the temp cache."""
import json
import os
import shutil
import sys
import time

from glassmusic import removal

OUT = os.environ["GM_TEST_OUT"]
LIB = os.environ.get("GLASS_MUSIC_DIR", "")
TEMP = os.path.join(os.environ["GLASS_MUSIC_CACHE"], "yandex-temp")
SRC = os.path.join(OUT, "fixtures", "dl.flac")
LYRICS = {"Ym Song": {"lrc": "[00:01.00]from yandex\n[00:02.00]second line", "text": "from yandex\nsecond line"},
          "Plain Song": {"lrc": "", "text": "yandex plain words"}}


def emit(o):
    sys.stdout.write(json.dumps(o, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def fetch(c):
    job, mode, ids = c.get("job", 0), c.get("mode", "play"), [str(i) for i in c.get("ids", [])]
    at = max(0, min(int(c.get("at", 0)), len(ids) - 1)) if ids else 0
    order = list(range(at, len(ids))) + list(range(0, at))
    for n, i in enumerate(order):
        emit({"type": "ym-progress", "job": job, "mode": mode, "done": n, "total": len(order), "text": f"Track {ids[i]}"})
        if ids[i].startswith("lib"):
            d = os.path.join(LIB, "Zz Yandex", "Downloads")
        else:
            d = TEMP
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, f"{ids[i]}.flac")
        shutil.copy(SRC, path)
        emit({"type": "ym-ready", "job": job, "mode": mode, "idx": i, "at": at, "id": ids[i], "path": path,
              "lib": path.startswith(LIB + os.sep), "t": f"Track {ids[i]}", "c": ""})
        time.sleep(0.4)
    emit({"type": "ym-done", "job": job, "mode": mode, "ok": True, "n": len(ids), "text": ""})


def main():
    log = open(os.path.join(OUT, "ym.log"), "a")
    for line in sys.stdin:
        log.write(line)
        log.flush()
        try:
            c = json.loads(line)
        except ValueError:
            continue
        cmd = c.get("cmd")
        if cmd == "status":
            emit({"type": "ym-status", "signed": True, "conf": {"storage": "temp"}})
        elif cmd == "fetch":
            fetch(c)
        elif cmd == "lyrics":
            t = c.get("title", "")
            if t == "Broken Song":
                emit({"type": "ym-error", "cmd": "lyrics", "rid": c.get("rid", 0), "text": "boom"})
            else:
                r = LYRICS.get(t, {"lrc": "", "text": ""})
                emit(dict(r, type="ym-lyrics", rid=c.get("rid", 0)))
        elif cmd == "remove":
            paths = [p for p in c.get("paths", []) if isinstance(p, str)]
            removed, failed, rescan = removal.remove(paths, [LIB, TEMP], [LIB])
            ids = c.get("ids", {})
            for p in removed:
                if p in ids:
                    emit({"type": "ym-liked", "id": ids[p], "on": False})
            emit({"type": "ym-removed", "paths": removed, "failed": failed, "rescan": rescan,
                  "unliked": len([p for p in removed if p in ids]), "notFound": len([p for p in removed if p not in ids])})
        elif cmd == "sync":
            d = os.path.join(LIB, "Zz Yandex", "Synced")
            os.makedirs(d, exist_ok=True)
            p = os.path.join(d, "synced.flac")
            shutil.copy(SRC, p)
            emit({"type": "ym-done", "job": c.get("job", 0), "mode": "sync", "ok": True, "n": 1, "paths": [p]})
        elif cmd == "cancel":
            pass


if __name__ == "__main__":
    main()
