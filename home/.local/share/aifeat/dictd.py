"""aidict daemon: push-to-toggle dictation with Whisper (OpenVINO GenAI) on the Intel NPU.

Socket: $XDG_RUNTIME_DIR/aifeat/dict.sock, one text command per connection, one JSON reply:
  toggle | start | stop | cancel | status | lang <auto|en|ru|ja> | unload
While recording, a glass pill (quickshell, ui/pill) shows the state from $RUN/pill.json.
The model is loaded on the first recording (≈1 s from the NPU blob cache) and freed after
AIDICT_IDLE_UNLOAD seconds without use (default 600).
"""
import gc
import json
import math
import os
import signal
import socket
import subprocess
import threading
import time
import wave

import numpy as np

HOME = os.path.expanduser("~")
RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "aifeat")
SOCK = os.path.join(RUN, "dict.sock")
PILL_STATE = os.path.join(RUN, "pill.json")
WAV = os.path.join(RUN, "dict.wav")
LANG_FILE = os.path.join(HOME, ".local/state/aifeat/dict-lang")
LOG = os.path.join(HOME, ".local/state/aifeat/dict.log")
MODEL = os.environ.get("AIDICT_MODEL", os.path.join(HOME, ".local/share/npu-ai/whisper/whisper-small-fp16-ov"))
DEVICE = os.environ.get("AIDICT_DEVICE", "NPU")
CACHE = os.path.join(HOME, ".cache/aifeat-whisper")
IDLE = int(os.environ.get("AIDICT_IDLE_UNLOAD", "600"))
PILL_UI = os.path.join(HOME, ".local/share/aifeat/ui/pill")
MAX_SEC = 300

lock = threading.RLock()
S = {"pipe": None, "load_s": None, "last_use": time.time(), "rec": None, "rec_t0": 0.0,
     "phase": "idle", "pill": None, "loading": None}


def log(*a):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(time.strftime("%F %T ") + " ".join(str(x) for x in a) + "\n")


def get_lang():
    try:
        v = open(LANG_FILE).read().strip()
        return v if v in ("en", "ru", "ja") else "auto"
    except OSError:
        return "auto"


def set_lang(v):
    os.makedirs(os.path.dirname(LANG_FILE), exist_ok=True)
    with open(LANG_FILE, "w") as f:
        f.write(v)


# ---------------------------------------------------------------- model
def load():
    with lock:
        if S["pipe"] is not None:
            return S["pipe"]
    import openvino_genai as og
    t = time.time()
    try:
        pipe = og.WhisperPipeline(MODEL, DEVICE, CACHE_DIR=CACHE)
    except Exception as e:  # noqa: BLE001
        log("NPU load failed, falling back to CPU:", e)
        pipe = og.WhisperPipeline(MODEL, "CPU")
    with lock:
        S["pipe"], S["load_s"] = pipe, round(time.time() - t, 2)
    log("loaded", MODEL, DEVICE, S["load_s"], "s")
    return pipe


def preload():
    th = threading.Thread(target=load, daemon=True)
    th.start()
    S["loading"] = th


def unload():
    with lock:
        S["pipe"] = None
    gc.collect()
    log("unloaded")


def idle_loop():
    while True:
        time.sleep(30)
        with lock:
            idle = S["pipe"] is not None and S["phase"] == "idle" and time.time() - S["last_use"] > IDLE
        if idle:
            unload()


# ---------------------------------------------------------------- pill
def pill(phase, **kw):
    S["phase"] = phase
    d = {"phase": phase, "lang": get_lang(), "t0": S["rec_t0"], **kw}
    tmp = PILL_STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, PILL_STATE)
    p = S["pill"]
    if phase != "idle" and (p is None or p.poll() is not None):
        env = dict(os.environ, AIDICT_STATE=PILL_STATE)
        S["pill"] = subprocess.Popen(["qs", "-p", PILL_UI], env=env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)


def level_loop():
    """Write the mic level (RMS of the last 100 ms of the growing WAV) for the pill's meter."""
    while S["phase"] == "recording":
        lvl = 0.0
        try:
            sz = os.path.getsize(WAV)
            if sz > 44 + 3200:
                with open(WAV, "rb") as f:
                    f.seek(sz - 3200 - (sz % 2))
                    a = np.frombuffer(f.read(3200), np.int16).astype(np.float32) / 32768
                rms = float(np.sqrt(np.mean(a * a)) + 1e-9)
                lvl = max(0.0, min(1.0, (20 * math.log10(rms) + 55) / 45))
        except OSError:
            pass
        if S["phase"] == "recording":
            pill("recording", level=round(lvl, 3))
        if time.time() - S["rec_t0"] > MAX_SEC:
            threading.Thread(target=stop, daemon=True).start()
            return
        time.sleep(0.08)


# ---------------------------------------------------------------- recording
def start():
    with lock:
        if S["rec"] is not None or S["phase"] == "transcribing":
            return {"ok": False, "state": S["phase"]}
        try:
            os.remove(WAV)
        except OSError:
            pass
        S["rec"] = subprocess.Popen(["pw-record", "--rate", "16000", "--channels", "1", "--format", "s16",
                                     "--media-role", "Communication", WAV],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        S["rec_t0"] = time.time()
        pill("recording", level=0)
    preload()
    threading.Thread(target=level_loop, daemon=True).start()
    log("recording")
    return {"ok": True, "state": "recording"}


def _stop_rec():
    r = S["rec"]
    S["rec"] = None
    if r is None:
        return False
    r.send_signal(signal.SIGINT)
    try:
        r.wait(2)
    except subprocess.TimeoutExpired:
        r.kill()
    return True


def read_wav():
    try:
        with wave.open(WAV) as w:
            return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
    except (OSError, EOFError, wave.Error):
        # pw-record may not have finalised the header: read raw PCM after the 44-byte header
        with open(WAV, "rb") as f:
            raw = f.read()[44:]
        return np.frombuffer(raw[: len(raw) // 2 * 2], np.int16).astype(np.float32) / 32768


HALLUCINATIONS = {"you", "thank you", "thanks for watching", "bye", "продолжение следует", "субтитры сделал dimatorzok",
                  "ご視聴ありがとうございました", "おやすみなさい", "редактор субтитров а.семкин корректор а.егорова"}


def has_speech(audio):
    """Energy VAD: >= 0.2 s of 30 ms frames clearly above the noise floor (and above -35 dBFS)."""
    f = audio[: len(audio) // 480 * 480].reshape(-1, 480)
    db = 20 * np.log10(np.sqrt((f * f).mean(1)) + 1e-9)
    thr = max(float(np.percentile(db, 20)) + 15, -35.0)
    return int((db > thr).sum()) >= 7


def type_text(text):
    """Type into the focused window; fall back to the clipboard + notification."""
    try:
        r = subprocess.run(["wtype", "--", text], capture_output=True, timeout=30)
        if r.returncode == 0:
            return "typed"
        log("wtype failed:", r.stderr.decode(errors="replace").strip())
    except (OSError, subprocess.TimeoutExpired) as e:
        log("wtype failed:", e)
    subprocess.run(["wl-copy", "--", text])
    subprocess.run(["notify-send", "-a", "Dictation", "-i", "audio-input-microphone",
                    "Dictation copied to clipboard", text[:300]])
    return "clipboard"


def stop():
    with lock:
        rec_len = time.time() - S["rec_t0"]
        if not _stop_rec():
            return {"ok": False, "state": S["phase"]}
        pill("transcribing")
    t_stop = time.time()
    try:
        audio = read_wav()
        if len(audio) < 16000 * 0.3 or not has_speech(audio):
            pill("error", text="Nothing heard")
            return {"ok": False, "error": "silence", "sec": round(rec_len, 2)}
        if S["loading"]:
            S["loading"].join()
        pipe = load()
        lang = get_lang()
        kw = {"task": "transcribe", "return_timestamps": False}
        if lang != "auto":
            kw["language"] = f"<|{lang}|>"
        t = time.time()
        with lock:
            res = pipe.generate(audio.tolist(), **kw)
        asr_ms = round((time.time() - t) * 1000)
        text = res.texts[0].strip()
        S["last_use"] = time.time()
        if text.strip(" .!?。！").lower() in HALLUCINATIONS:
            text = ""
        if not text:
            pill("error", text="Nothing recognised")
            return {"ok": False, "error": "empty"}
        how = type_text(text)
        total_ms = round((time.time() - t_stop) * 1000)
        pill("done", text=text, how=how, asr_ms=asr_ms, total_ms=total_ms)
        log(f"audio {len(audio)/16000:.1f}s asr {asr_ms} ms stop->typed {total_ms} ms via {how}: {text[:80]!r}")
        return {"ok": True, "text": text, "how": how, "audio_s": round(len(audio) / 16000, 2),
                "asr_ms": asr_ms, "total_ms": total_ms, "load_s": S["load_s"], "lang": lang}
    except Exception as e:  # noqa: BLE001
        log("error:", repr(e))
        pill("error", text=str(e)[:120])
        return {"ok": False, "error": str(e)}
    finally:
        threading.Timer(2.2, lambda: S["phase"] in ("done", "error") and pill("idle")).start()


def cancel():
    with lock:
        _stop_rec()
        pill("idle")
    return {"ok": True}


def transcribe_file(path, lang=None):
    """Test hook: transcribe a 16 kHz mono WAV without recording or typing."""
    with wave.open(path) as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
    t0 = time.time()
    pipe = load()
    kw = {"task": "transcribe", "return_timestamps": False}
    if lang and lang != "auto":
        kw["language"] = f"<|{lang}|>"
    t = time.time()
    with lock:
        text = pipe.generate(audio.tolist(), **kw).texts[0].strip()
    S["last_use"] = time.time()
    return {"ok": True, "text": text, "audio_s": round(len(audio) / 16000, 2),
            "asr_ms": round((time.time() - t) * 1000), "load_ms": round((t - t0) * 1000)}


def status():
    rss = 0
    try:
        for ln in open("/proc/self/status"):
            if ln.startswith("VmRSS"):
                rss = int(ln.split()[1]) // 1024
    except OSError:
        pass
    return {"ok": True, "state": S["phase"], "loaded": S["pipe"] is not None, "load_s": S["load_s"],
            "device": DEVICE, "model": os.path.basename(MODEL), "lang": get_lang(), "rss_mb": rss,
            "idle_unload_s": IDLE}


def handle(cmd):
    parts = cmd.strip().split(None, 1)
    c = parts[0] if parts else "status"
    arg = parts[1] if len(parts) > 1 else ""
    if c == "toggle":
        return stop() if S["rec"] is not None else start()
    if c == "start":
        return start()
    if c == "stop":
        return stop()
    if c == "cancel":
        return cancel()
    if c == "lang":
        if arg in ("auto", "en", "ru", "ja"):
            set_lang(arg)
        return {"ok": True, "lang": get_lang()}
    if c == "unload":
        unload()
        return status()
    if c == "load":
        load()
        return status()
    if c == "simulate":  # UI test: pill phases with a WAV instead of the mic; nothing is typed
        S["rec_t0"] = time.time()
        for i in range(30):
            pill("recording", level=round(0.5 + 0.4 * math.sin(i / 2), 3))
            time.sleep(0.08)
        pill("transcribing")
        r = transcribe_file(arg.split()[0])
        time.sleep(0.6)
        pill("done", text=r["text"], how="test", asr_ms=r["asr_ms"])
        threading.Timer(2.5, lambda: pill("idle")).start()
        return r
    if c == "file":
        a = arg.split()
        return transcribe_file(a[0], a[1] if len(a) > 1 else None)
    return status()


def main():
    os.makedirs(RUN, exist_ok=True)
    try:
        os.remove(SOCK)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    srv.listen(8)
    threading.Thread(target=idle_loop, daemon=True).start()
    log("daemon up")

    def serve(conn):
        with conn:
            try:
                cmd = conn.recv(4096).decode()
                conn.sendall(json.dumps(handle(cmd), ensure_ascii=False).encode())
            except Exception as e:  # noqa: BLE001
                log("handler error:", repr(e))

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
