"""jocr daemon: keeps the OCR models compiled on the NPU and serves them on 127.0.0.1:8766.

  GET  /health                 state, device, memory, timings
  GET  /llm                    translator (LLM server) status
  POST /ocr                    image -> text + boxes   (raw image body, or JSON {"path"|"image_b64"})
       query/JSON options: direction=auto|horizontal|vertical  mode=auto|block
                           furigana=1  crop=x,y,w,h  (pixels of the posted image)
  POST /furigana {"text"}      -> tokens with readings / dictionary forms
  POST /translate {"text", "lang": "en"|"ru", "stream": false}
                               -> {"translation", ...} or text/event-stream of {"delta"} then {"done"}
  POST /load, POST /unload     load / free the models (they also unload after --idle-unload s)
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import threading
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np

from . import dictionary, reading, translate
from .engine import Engine

VERSION = "1.0"


def rss_mb():
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return round(int(line.split()[1]) / 1024, 1)
    except OSError:
        pass
    return None


class State:
    def __init__(self, args):
        self.args = args
        self.engine = None
        self.state = "unloaded"
        self.error = None
        self.load_s = None
        self.started = time.time()
        self.last_used = time.time()
        self.requests = 0
        self.lock = threading.Lock()
        self.npu_busy0 = None

    def load(self):
        with self.lock:
            if self.engine is not None:
                return
            self.state = "loading"
            t = time.time()
            try:
                self.engine = Engine(device=self.args.device)
                self.engine.warm_all()
                img = np.full((96, 320, 3), 255, np.uint8)
                cv2.putText(img, "warm up", (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 0, 0), 3)
                self.engine.ocr(img)
                self.engine.ocr(img, mode="block")
                self.load_s = round(time.time() - t, 2)
                self.state = "ready"
                self.error = None
                log(f"models ready on {self.engine.device} in {self.load_s}s, rss {rss_mb()} MB")
            except Exception as e:  # noqa: BLE001
                self.state = "error"
                self.error = f"{type(e).__name__}: {e}"
                log("load failed: " + traceback.format_exc())
            self.last_used = time.time()

    def unload(self):
        with self.lock:
            if self.engine is None:
                return
            self.engine = None
            self.state = "unloaded"
        import gc
        gc.collect()
        log(f"models unloaded, rss {rss_mb()} MB")

    def get(self):
        self.last_used = time.time()
        if self.engine is None:
            self.load()
        if self.engine is None:
            raise RuntimeError(self.error or "engine not loaded")
        return self.engine


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, file=sys.stderr, flush=True)


def decode_image(data):
    arr = np.frombuffer(data, np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("could not decode image")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "jocr")


def save_crop(img, max_w=1280):
    """Keep the OCR'd screen crop (JPEG, <= 1280 px wide) for the Anki Picture field."""
    os.makedirs(RUN, exist_ok=True)
    for f in os.listdir(RUN):  # drop crops older than a day
        p = os.path.join(RUN, f)
        if f.startswith("crop-") and time.time() - os.path.getmtime(p) > 86400:
            os.remove(p)
    h, w = img.shape[:2]
    if w > max_w:
        img = cv2.resize(img, (max_w, int(h * max_w / w)), interpolation=cv2.INTER_AREA)
    path = os.path.join(RUN, f"crop-{int(time.time() * 1000)}.jpg")
    cv2.imwrite(path, cv2.cvtColor(img, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 88])
    return path


def anki_reading(text):
    """Anki furigana syntax: 食[た]べる, 取[と]り 扱[あつか]い"""
    out = ""
    for t in reading.tokens(text):
        for seg, kana in t["ruby"]:
            if kana:
                out += (" " if out else "") + f"{seg}[{kana}]"
            else:
                out += seg
    return out


def mine(d):
    """Build a JP Mining note and hand it to anki-add. d: word, base?, sentence, translation?,
    picture?, source?, deck?, tags?"""
    import subprocess
    word = (d.get("word") or "").strip()
    base = (d.get("base") or "").strip()
    if not word:
        raise ValueError("word is required")
    toks = reading.tokens(word)
    if not base and len([t for t in toks if t["pos"] not in ("space", "newline")]) == 1:
        base = toks[0]["base"]
    entry = dictionary.lookup(base, word, "".join(t["reading"] for t in toks))
    expression = entry["word"] if entry else (base or word)
    meaning = ""
    if entry:
        meaning = "<br>".join(f"{i}. {s}" for i, s in enumerate(entry["en"][:3], 1))
        if entry["ru"]:
            meaning += "<br><span style=\"opacity:.7\">" + entry["ru"][0] + "</span>"
    sentence = (d.get("sentence") or "").strip()
    tr = (d.get("translation") or "").strip()
    if not tr and sentence and d.get("translate", True):
        try:
            if translate.status()["ok"]:
                tr = translate.translate(sentence, d.get("lang", "en"), timeout=25)["translation"]
        except Exception:  # noqa: BLE001 - optional
            tr = ""
    note = {"expression": expression, "word": word, "reading": anki_reading(expression), "meaning": meaning,
            "sentence": sentence, "sentence_translation": tr, "picture": d.get("picture") or "",
            "source": d.get("source") or "jocr", "tags": d.get("tags") or ["jocr", "mining"]}
    if d.get("deck"):
        note["deck"] = d["deck"]
    p = subprocess.run([os.path.expanduser("~/.local/bin/anki-add")], input=json.dumps(note, ensure_ascii=False),
                       capture_output=True, text=True, timeout=60)
    try:
        r = json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        r = {"status": "error", "message": (p.stderr or p.stdout).strip()[-300:]}
    r["note"] = {k: v for k, v in note.items() if k != "picture"}
    return r


class Handler(BaseHTTPRequestHandler):
    server_version = "jocr/" + VERSION
    protocol_version = "HTTP/1.1"
    S: State = None  # set in main()

    def log_message(self, fmt, *a):  # quiet access log
        pass

    # -- helpers ------------------------------------------------------------------------------
    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    # Local clients only (CLI, QML panels): browsers always send Origin on cross-site requests and
    # a DNS-rebinding page would carry a foreign Host, so both are refused. No CORS headers are sent,
    # so no web page can read a reply either.
    _LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")

    def _refuse_foreign(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if self.headers.get("Origin") is not None or host not in self._LOCAL_HOSTS:
            self._send(403, {"error": "forbidden: local clients only"})
            return True
        return False

    def do_OPTIONS(self):  # no CORS: refuse preflights
        self._send(403, {"error": "forbidden: local clients only"})

    # -- routes -------------------------------------------------------------------------------
    def do_GET(self):
        if self._refuse_foreign():
            return
        url = urllib.parse.urlparse(self.path)
        S = self.S
        if url.path == "/health":
            eng = S.engine
            busy = None
            try:
                busy = int(open("/sys/class/accel/accel0/device/npu_busy_time_us").read())
            except OSError:
                pass
            self._send(200, {"ok": S.state in ("ready", "unloaded"), "state": S.state, "error": S.error,
                             "device": eng.device if eng else None, "load_s": S.load_s,
                             "rss_mb": rss_mb(), "uptime_s": round(time.time() - S.started),
                             "idle_s": round(time.time() - S.last_used), "requests": S.requests,
                             "idle_unload_s": S.args.idle_unload, "npu_busy_time_us": busy,
                             "version": VERSION})
        elif url.path == "/llm":
            self._send(200, translate.status())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self._refuse_foreign():
            return
        url = urllib.parse.urlparse(self.path)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        S = self.S
        try:
            if url.path == "/ocr":
                return self._ocr(q)
            if url.path == "/furigana":
                d = json.loads(self._body() or b"{}")
                text = d.get("text", "")
                toks = reading.tokens(text)
                return self._send(200, {"tokens": toks, "hiragana": "".join(t["reading"] or t["surface"] for t in toks)})
            if url.path == "/lookup":
                d = json.loads(self._body() or b"{}")
                return self._send(200, {"entry": dictionary.lookup(*(d.get("forms") or [d.get("word", "")]))})
            if url.path == "/mine":
                return self._send(200, mine(json.loads(self._body() or b"{}")))
            if url.path == "/translate":
                return self._translate(json.loads(self._body() or b"{}"))
            if url.path == "/load":
                self._body()
                S.load()
                return self._send(200, {"state": S.state, "load_s": S.load_s, "rss_mb": rss_mb()})
            if url.path == "/unload":
                self._body()
                S.unload()
                return self._send(200, {"state": S.state, "rss_mb": rss_mb()})
            self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            log("error: " + traceback.format_exc())
            self._send(500, {"error": f"{type(e).__name__}: {e}"})

    def _ocr(self, q):
        S = self.S
        S.requests += 1
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        body = self._body()
        opts = dict(q)
        t0 = time.perf_counter()
        if ctype == "application/json":
            d = json.loads(body or b"{}")
            opts.update({k: v for k, v in d.items() if k not in ("path", "image_b64")})
            if d.get("path"):
                with open(os.path.expanduser(d["path"]), "rb") as f:
                    img = decode_image(f.read())
            elif d.get("image_b64"):
                img = decode_image(base64.b64decode(d["image_b64"]))
            else:
                return self._send(400, {"error": "need an image body, or JSON with path / image_b64"})
        else:
            if not body:
                return self._send(400, {"error": "empty body"})
            img = decode_image(body)
        crop = opts.get("crop")
        if crop:
            x, y, w, h = [int(float(v)) for v in (crop.split(",") if isinstance(crop, str) else crop)]
            img = np.ascontiguousarray(img[max(0, y):y + h, max(0, x):x + w])
        t1 = time.perf_counter()
        direction = opts.get("direction", "auto")
        mode = opts.get("mode", "auto")
        eng = S.get()
        res = eng.ocr(img, direction=direction, mode=mode)
        res["timings"]["decode_ms"] = round((t1 - t0) * 1000, 1)
        if str(opts.get("furigana", "0")).lower() in ("1", "true", "yes"):
            t2 = time.perf_counter()
            res["tokens"] = reading.tokens(res["text"])
            res["timings"]["furigana_ms"] = round((time.perf_counter() - t2) * 1000, 1)
        if str(opts.get("save", "0")).lower() in ("1", "true", "yes"):
            res["image_path"] = save_crop(img)
        S.last_used = time.time()
        log(f"ocr {res['size'][0]}x{res['size'][1]} {len(res['blocks'])} blocks "
            f"det {res['timings']['det_ms']} rec {res['timings']['rec_ms']} ms: {res['text'][:40]!r}")
        self._send(200, res)

    def _translate(self, d):
        text = (d.get("text") or "").strip()
        lang = d.get("lang", "en")
        if not text:
            return self._send(400, {"error": "empty text"})
        st = translate.status()
        if not st["ok"]:
            return self._send(503, {"error": "translator offline", "detail": st["error"], "url": st["url"]})
        if not d.get("stream"):
            return self._send(200, translate.translate(text, lang))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        t = time.time()
        acc = ""
        try:
            for delta in translate.translate_stream(text, lang):
                acc += delta
                self.wfile.write(b"data: " + json.dumps({"delta": delta}, ensure_ascii=False).encode() + b"\n\n")
                self.wfile.flush()
            done = {"done": True, "translation": translate._clean(acc), "lang": lang, "model": st["model"],
                    "ms": round((time.time() - t) * 1000)}
            self.wfile.write(b"data: " + json.dumps(done, ensure_ascii=False).encode() + b"\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def idle_watch(S):
    while True:
        time.sleep(15)
        if S.args.idle_unload > 0 and S.engine is not None and time.time() - S.last_used > S.args.idle_unload:
            S.unload()


def main():
    ap = argparse.ArgumentParser(description="jocr OCR daemon")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=int(os.environ.get("JOCR_PORT", 8766)))
    ap.add_argument("--device", default=os.environ.get("JOCR_DEVICE") or None, help="NPU, GPU or CPU (default: best)")
    ap.add_argument("--idle-unload", type=int, default=int(os.environ.get("JOCR_IDLE_UNLOAD", 0)),
                    help="free the models after this many idle seconds (0 = keep loaded)")
    args = ap.parse_args()
    S = State(args)
    Handler.S = S
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    log(f"jocr {VERSION} listening on http://{args.host}:{args.port}")
    threading.Thread(target=S.load, daemon=True).start()
    threading.Thread(target=idle_watch, args=(S,), daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
