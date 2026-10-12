"""Whisper helper for Glass Music lyrics: runs in a venv with openvino_genai + numpy (not the app's).

Auto-sync only: it times KNOWN plain lyrics against the audio; it never makes lyrics up.
Usage: python -I whisperlrc.py < request.json > result.json
request: {"audio": path, "lang": "ru" | null, "lyrics": [line, ...],
          "model": dir, "device": "NPU" | "CPU" | "GPU", "cache": dir, "max_s": 720}
result:  {"ok": true, "lang": .., "dur": seconds, "nwords": n, "secs": compute time,
          "times": [...], "quality": q}   a start time per lyric line
         {"ok": false, "error": "..."}

The audio is decoded with ffmpeg to 16 kHz mono. Whisper runs with word timestamps; the first
word of each segment carries the segment start (often seconds early), so it is moved to just
before the next word when there is a long gap. Alignment: lyricsalign.py (stdlib)."""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lyricsalign  # noqa: E402


def decode(path, max_s):
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-nostdin", "-i", path, "-t", str(max_s),
                          "-ac", "1", "-ar", "16000", "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32)


def pipeline(model, device, cache):
    import openvino_genai as og
    kw = {"word_timestamps": True}
    if device == "NPU" and cache:
        os.makedirs(cache, exist_ok=True)
        kw["CACHE_DIR"] = cache
    try:
        return og.WhisperPipeline(model, device, **kw), device
    except Exception:
        if device == "CPU":
            raise
        return og.WhisperPipeline(model, "CPU", word_timestamps=True), "CPU"


def transcribe(pipe, audio, lang):
    cfg = pipe.get_generation_config()
    cfg.return_timestamps = True
    cfg.word_timestamps = True
    cfg.task = "transcribe"
    if lang:
        tok = "<|%s|>" % lang
        if tok in (cfg.lang_to_id or {}):
            cfg.language = tok
    r = pipe.generate(audio.tolist(), cfg)
    seg_starts = {round(c.start_ts, 2) for c in (r.chunks or [])}
    words = []
    for w in (r.words or []):
        t, e, text = float(w.start_ts), float(w.end_ts), w.word
        words.append([t, e, text, round(t, 2) in seg_starts])
    # a segment's first word starts at the segment start: pull it to just before the next word
    for i, w in enumerate(words):
        if w[3] and i + 1 < len(words) and words[i + 1][0] - w[0] > 1.0:
            w[0] = max(w[0], words[i + 1][0] - 0.45)
    return words


def main():
    req = json.load(sys.stdin)
    t0 = time.time()
    try:
        if not req.get("lyrics"):
            raise ValueError("no lyrics to align")
        audio = decode(req["audio"], int(req.get("max_s") or 720))
        dur = len(audio) / 16000.0
        if dur < 5:
            raise ValueError("audio too short or unreadable")
        pipe, dev = pipeline(req["model"], req.get("device") or "NPU", req.get("cache"))
        try:
            words = transcribe(pipe, audio, req.get("lang"))
        except RuntimeError:
            # the NPU's static shapes can overflow on dense segments (many tokens): redo on the CPU
            if dev == "CPU":
                raise
            del pipe
            pipe, dev = pipeline(req["model"], "CPU", None)
            words = transcribe(pipe, audio, req.get("lang"))
        out = {"ok": True, "lang": req.get("lang"), "dur": round(dur, 2), "nwords": len(words), "device": dev}
        times, q = lyricsalign.align(req["lyrics"], words, dur)
        out.update(times=times, quality=q)
        if req.get("debug"):
            out["words"] = words
        out["secs"] = round(time.time() - t0, 1)
    except Exception as ex:          # reported to the app, which falls back gracefully
        out = {"ok": False, "error": "%s: %s" % (type(ex).__name__, ex)}
    json.dump(out, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
