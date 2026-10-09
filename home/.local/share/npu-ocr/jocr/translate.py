"""Translation through the local OpenAI-compatible LLM server (llama-server, npu-llm.service).

URL: $JOCR_LLM_URL (default http://127.0.0.1:8765). Only the standard
/v1/chat/completions, /v1/models and /health endpoints are used.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

LLM_URL = os.environ.get("JOCR_LLM_URL", "http://127.0.0.1:8765").rstrip("/")
LANGS = {"en": "English", "ru": "Russian", "ja": "Japanese"}

SYSTEM = ("You are an expert Japanese-to-{lang} translator helping a Japanese learner. "
          "The text comes from OCR of manga, games, subtitles or web pages, so it may be a fragment "
          "or casual dialogue. Translate it faithfully and naturally into {lang}, keeping the tone and "
          "the line breaks. Output only the translation: no notes, no romaji, no quotes around it.")


def status(timeout=0.6):
    """-> {"ok": bool, "model": str|None, "url": str, "error": str|None}"""
    out = {"ok": False, "model": None, "url": LLM_URL, "error": None}
    try:
        with urllib.request.urlopen(LLM_URL + "/v1/models", timeout=timeout) as r:
            d = json.load(r)
        models = [m.get("id") for m in d.get("data", [])] or [m.get("name") for m in d.get("models", [])]
        out["ok"] = True
        out["model"] = models[0] if models else None
    except TimeoutError:
        # battery worker: npu-llm is socket-activated; a connection that is accepted but not answered yet means
        # the model is loading (~40 s after an idle stop). Report it as available so callers send the request.
        out["ok"] = True
        out["model"] = "loading"
    except Exception as e:  # noqa: BLE001 - report any failure as "translator offline"
        out["error"] = f"{type(e).__name__}: {e}"
    return out


def _request(text, lang, stream):
    name = LANGS.get(lang, lang)
    body = {
        "messages": [
            {"role": "system", "content": SYSTEM.format(lang=name)},
            {"role": "user", "content": text},
        ],
        "temperature": 0.2,
        "max_tokens": min(1024, 64 + 3 * len(text)),
        "stream": stream,
    }
    st = status()
    if st["model"]:
        body["model"] = st["model"]
    return urllib.request.Request(LLM_URL + "/v1/chat/completions", data=json.dumps(body).encode(),
                                  headers={"Content-Type": "application/json"})


def _clean(s):
    s = s.strip()
    # drop a stray <think></think> block if a reasoning model is behind the endpoint
    if "</think>" in s:
        s = s.split("</think>", 1)[1].strip()
    return s


def translate(text, lang="en", timeout=120):
    """Blocking translation -> {"translation", "lang", "model", "ms"}; raises on failure."""
    t = time.time()
    with urllib.request.urlopen(_request(text, lang, False), timeout=timeout) as r:
        d = json.load(r)
    msg = d["choices"][0]["message"]
    return {"translation": _clean(msg.get("content") or ""), "lang": lang, "model": d.get("model"),
            "ms": round((time.time() - t) * 1000)}


def translate_stream(text, lang="en", timeout=120):
    """Yields text deltas as they arrive from the LLM (SSE)."""
    with urllib.request.urlopen(_request(text, lang, True), timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                delta = json.loads(data)["choices"][0].get("delta", {}).get("content")
            except (ValueError, KeyError, IndexError):
                continue
            if delta:
                yield delta
