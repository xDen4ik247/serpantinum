"""Japanese OCR engine on OpenVINO (Intel NPU first, then GPU, then CPU).

Pipeline
  1. PP-OCRv6 text detection (DBNet) -> text line quads (static NPU shape buckets).
  2. Layout: each line is horizontal or vertical; neighbouring lines are grouped into blocks
     (paragraphs / speech bubbles), blocks are put in reading order
     (horizontal: top->bottom; vertical: right->left columns).
  3. Recognition
       * vertical blocks (manga bubbles, vertical novels) and short horizontal lines:
         manga-ocr (ViT encoder + 2-layer BERT decoder, static KV cache, greedy)
       * long horizontal lines: PP-OCRv6 CTC line recognizer (no aspect-ratio squeeze)
  4. If detection finds nothing, the whole image goes to manga-ocr (the user picked a region
     on purpose, so there is probably stylised text the detector missed).
"""
from __future__ import annotations

import json
import math
import os
import threading
import time

import cv2
import numpy as np
import openvino as ov
import pyclipper

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".local/share/npu-ocr")
MODELS = os.path.join(BASE, "models")
CACHE = os.path.join(BASE, "cache")

# (H, W), multiples of 32: lines/subtitles, columns, bubbles, half screen, full screen at 2/3
DET_BUCKETS = [(256, 1280), (1280, 256), (640, 640), (800, 1280), (1280, 800), (1216, 1920)]
REC_BUCKETS = [320, 640, 1280, 2560]  # widths at height 48


def pick_device(pref=("NPU", "GPU", "CPU"), core=None):
    core = core or ov.Core()
    avail = core.available_devices
    for d in pref:
        if any(a == d or a.startswith(d + ".") for a in avail):
            return d
    return "CPU"


# --------------------------------------------------------------------------- helpers
def _mini_box(contour):
    rect = cv2.minAreaRect(contour)
    pts = sorted(list(cv2.boxPoints(rect)), key=lambda p: p[0])
    i1, i4 = (0, 1) if pts[1][1] > pts[0][1] else (1, 0)
    i2, i3 = (2, 3) if pts[3][1] > pts[2][1] else (3, 2)
    return np.array([pts[i1], pts[i2], pts[i3], pts[i4]], dtype=np.float32), min(rect[1])


def _box_score(prob, box):
    h, w = prob.shape
    xmin = int(np.clip(np.floor(box[:, 0].min()), 0, w - 1))
    xmax = int(np.clip(np.ceil(box[:, 0].max()), 0, w - 1))
    ymin = int(np.clip(np.floor(box[:, 1].min()), 0, h - 1))
    ymax = int(np.clip(np.ceil(box[:, 1].max()), 0, h - 1))
    mask = np.zeros((ymax - ymin + 1, xmax - xmin + 1), dtype=np.uint8)
    b = box.copy()
    b[:, 0] -= xmin
    b[:, 1] -= ymin
    cv2.fillPoly(mask, b.reshape(1, -1, 2).astype(np.int32), 1)
    return cv2.mean(prob[ymin:ymax + 1, xmin:xmax + 1], mask)[0]


def _unclip(box, ratio):
    area = cv2.contourArea(box)
    length = cv2.arcLength(box.reshape(-1, 1, 2), True)
    if length <= 0:
        return None
    dist = area * ratio / length
    off = pyclipper.PyclipperOffset()
    off.AddPath([tuple(p) for p in box.astype(np.int64).tolist()], pyclipper.JT_ROUND, pyclipper.ET_CLOSEDPOLYGON)
    out = off.Execute(dist)
    if not out:
        return None
    return np.array(out[0], dtype=np.float32)


def crop_quad(img, quad):
    """Perspective-crop a quad (tl, tr, br, bl) from an RGB image."""
    q = quad.astype(np.float32)
    w = int(round(max(np.linalg.norm(q[0] - q[1]), np.linalg.norm(q[2] - q[3]))))
    h = int(round(max(np.linalg.norm(q[0] - q[3]), np.linalg.norm(q[1] - q[2]))))
    w, h = max(w, 2), max(h, 2)
    dst = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    M = cv2.getPerspectiveTransform(q, dst)
    return cv2.warpPerspective(img, M, (w, h), borderMode=cv2.BORDER_REPLICATE, flags=cv2.INTER_CUBIC)


def crop_rect(img, x0, y0, x1, y1, pad=0):
    H, W = img.shape[:2]
    x0, y0 = max(0, int(x0 - pad)), max(0, int(y0 - pad))
    x1, y1 = min(W, int(math.ceil(x1 + pad))), min(H, int(math.ceil(y1 + pad)))
    return img[y0:y1, x0:x1]


def border_color(img):
    edge = np.concatenate([img[0], img[-1], img[:, 0], img[:, -1]], axis=0)
    return np.median(edge, axis=0)


# --------------------------------------------------------------------------- models
def with_u8_input(model, mean, scale, bgr=True):
    """Fold uint8 NHWC RGB -> float NCHW (optionally BGR) normalisation into the graph, so the
    NPU does it and Python only hands over a uint8 image."""
    from openvino.preprocess import ColorFormat, PrePostProcessor
    ppp = PrePostProcessor(model)
    ppp.input().tensor().set_element_type(ov.Type.u8).set_layout(ov.Layout("NHWC")).set_color_format(ColorFormat.RGB)
    ppp.input().model().set_layout(ov.Layout("NCHW"))
    pre = ppp.input().preprocess().convert_element_type(ov.Type.f32)
    if bgr:
        pre.convert_color(ColorFormat.BGR)
    pre.mean(mean).scale(scale)
    return ppp.build()


class _Compiled:
    """A compiled model + its infer request, guarded by the engine lock."""

    def __init__(self, cm):
        self.cm = cm
        self.req = cm.create_infer_request()


class Detector:
    MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

    def __init__(self, core, path, device, buckets=DET_BUCKETS, thresh=0.2, box_thresh=0.45, unclip=1.4,
                 max_upscale=1.5):
        self.core, self.path, self.device = core, path, device
        self.buckets = buckets
        self.thresh, self.box_thresh, self.unclip_ratio = thresh, box_thresh, unclip
        self.max_upscale = max_upscale
        self.models = {}

    def _get(self, hw):
        if hw not in self.models:
            m = self.core.read_model(self.path)
            if self.device == "CPU":
                m.reshape({m.inputs[0].any_name: ov.PartialShape([1, 3, -1, -1])})
            else:
                m.reshape({m.inputs[0].any_name: [1, 3, hw[0], hw[1]]})
            m = with_u8_input(m, [255 * v for v in self.MEAN], [255 * v for v in self.STD])
            self.models[hw] = _Compiled(self.core.compile_model(m, self.device, {"PERFORMANCE_HINT": "LATENCY"}))
        return self.models[hw]

    def warmup(self):
        if self.device != "CPU":
            for b in self.buckets:
                self._get(b)

    def choose(self, h, w):
        """Smallest bucket that holds the image at the desired scale (1.0, or up to 1.5x for small
        images); if none does, the bucket that needs the least downscaling."""
        want = min(self.max_upscale, 640 / max(h, w)) if max(h, w) <= 640 else 1.0
        fits = [(bh * bw, (bh, bw)) for bh, bw in self.buckets if bh >= h * want and bw >= w * want]
        if fits:
            return min(fits)[1], want
        best = max(((min(bh / h, bw / w), -(bh * bw)), (bh, bw)) for bh, bw in self.buckets)
        return best[1], best[0][0]

    def __call__(self, img):
        """img: RGB uint8 HxWx3 -> list of (quad float32[4,2] in image coords, score)."""
        H, W = img.shape[:2]
        if self.device == "CPU":
            s = min(self.max_upscale, 1920 / max(H, W)) if max(H, W) > 1920 else min(self.max_upscale, max(1.0, 640 / max(H, W)))
            nh, nw = max(32, int(round(H * s / 32)) * 32), max(32, int(round(W * s / 32)) * 32)
            canvas = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR if s < 1 else cv2.INTER_CUBIC)
            sx, sy = nw / W, nh / H
            bh, bw, rh, rw = nh, nw, nh, nw
            key = (0, 0)
        else:
            (bh, bw), s = self.choose(H, W)
            rh, rw = max(1, int(round(H * s))), max(1, int(round(W * s)))
            resized = img if (rh, rw) == (H, W) else cv2.resize(
                img, (rw, rh), interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_CUBIC)
            canvas = np.empty((bh, bw, 3), dtype=np.uint8)
            fill = border_color(img).astype(np.uint8)
            canvas[:rh, :rw] = resized
            canvas[rh:, :] = fill
            canvas[:rh, rw:] = fill
            sx, sy = rw / W, rh / H
            key = (bh, bw)
        cm = self._get(key)
        cm.req.infer({0: canvas[None]})
        prob = cm.req.get_output_tensor(0).data[0, 0]
        prob = prob[:rh, :rw]
        bitmap = (prob > self.thresh).astype(np.uint8)
        contours, _ = cv2.findContours(bitmap * 255, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        out = []
        for c in contours[:1000]:
            box, sside = _mini_box(c)
            if sside < 3:
                continue
            score = _box_score(prob, box)
            if score < self.box_thresh:
                continue
            exp = _unclip(box, self.unclip_ratio)
            if exp is None:
                continue
            box, sside = _mini_box(exp.reshape(-1, 1, 2))
            if sside < 5:
                continue
            box[:, 0] = np.clip(box[:, 0] / sx, 0, W)
            box[:, 1] = np.clip(box[:, 1] / sy, 0, H)
            out.append((box, float(score)))
        return out


class LineRecognizer:
    """PP-OCRv6 CTC text-line recognizer (horizontal lines, height 48)."""

    def __init__(self, core, path, dict_yml, device, buckets=REC_BUCKETS):
        import yaml
        self.core, self.path, self.device, self.buckets = core, path, device, buckets
        d = yaml.safe_load(open(dict_yml, encoding="utf-8"))
        self.chars = ["<blank>"] + [str(c) for c in d["PostProcess"]["character_dict"]] + [" "]
        self.models = {}

    def _get(self, w):
        if w not in self.models:
            m = self.core.read_model(self.path)
            if self.device == "CPU":
                m.reshape({m.inputs[0].any_name: ov.PartialShape([1, 3, 48, -1])})
            else:
                m.reshape({m.inputs[0].any_name: [1, 3, 48, w]})
            m = with_u8_input(m, [127.5] * 3, [127.5] * 3)
            self.models[w] = _Compiled(self.core.compile_model(m, self.device, {"PERFORMANCE_HINT": "LATENCY"}))
        return self.models[w]

    def warmup(self):
        if self.device != "CPU":
            for w in self.buckets:
                self._get(w)

    def __call__(self, crop):
        """crop: RGB uint8 horizontal line image -> (text, mean confidence)."""
        h, w = crop.shape[:2]
        rw = max(8, int(math.ceil(48 * w / h)))
        if self.device == "CPU":
            bw = max(320, rw)
            key = 0
        else:
            fits = [b for b in self.buckets if b >= rw]
            bw = fits[0] if fits else self.buckets[-1]
            key = bw
        rw = min(rw, bw)
        img = cv2.resize(crop, (rw, 48), interpolation=cv2.INTER_AREA if h > 48 else cv2.INTER_CUBIC)
        x = np.full((1, 48, bw, 3), 128, dtype=np.uint8)  # ~0 after normalisation, like Paddle's zero pad
        x[0, :, :rw] = img
        cm = self._get(key)
        cm.req.infer({0: x})
        y = cm.req.get_output_tensor(0).data[0]  # [T, C] (softmaxed)
        # only the time steps that cover real pixels (the model downsamples width by 8)
        tmax = max(1, int(math.ceil(y.shape[0] * rw / bw)) + 1)
        y = y[:tmax]
        ids = y.argmax(-1)
        probs = y.max(-1)
        text, confs, prev = [], [], -1
        for i, p in zip(ids, probs):
            if i != prev and i != 0:
                text.append(self.chars[i] if i < len(self.chars) else "")
                confs.append(float(p))
            prev = i
        return "".join(text).strip(), (float(np.mean(confs)) if confs else 0.0)


class MangaOCR:
    """manga-ocr (kha-white) exported as encoder->cross-KV and a one-token decoder step with a
    static self-attention KV cache, so both parts compile for the NPU."""

    def __init__(self, core, ovdir, device, dec_device=None):
        self.core, self.dir, self.device = core, ovdir, device
        self.dec_device = dec_device or device
        meta = json.load(open(os.path.join(ovdir, "meta.json")))
        self.T = meta["cache_T"]
        self.vocab = [l.rstrip("\n") for l in open(os.path.join(ovdir, "vocab.txt"), encoding="utf-8")]
        cfg = {"PERFORMANCE_HINT": "LATENCY"}
        self.enc = _Compiled(core.compile_model(os.path.join(ovdir, "encoder.xml"), device, cfg))
        self.dec = _Compiled(core.compile_model(os.path.join(ovdir, f"decoder_step_b1_t{self.T}.xml"), self.dec_device, cfg))
        r = self.dec.req
        self._t = {n: r.get_tensor(n).data for n in ("input_ids", "pos", "mask", "self_k", "self_v", "cross_k", "cross_v")}

    @staticmethod
    def preprocess(crop):
        g = cv2.cvtColor(crop, cv2.COLOR_RGB2GRAY)
        g = cv2.resize(g, (224, 224), interpolation=cv2.INTER_LINEAR if min(crop.shape[:2]) < 224 else cv2.INTER_AREA)
        x = g.astype(np.float32) / 127.5 - 1.0
        return np.repeat(x[None, None], 3, axis=1)

    def __call__(self, crop, max_tokens=None):
        """crop: RGB uint8 -> (text, mean token probability)."""
        max_tokens = min(max_tokens or self.T, self.T)
        self.enc.req.infer({"pixel_values": self.preprocess(crop)})
        t = self._t
        t["cross_k"][...] = self.enc.req.get_tensor("cross_k").data
        t["cross_v"][...] = self.enc.req.get_tensor("cross_v").data
        t["self_k"][...] = 0
        t["self_v"][...] = 0
        t["mask"][...] = -1e4
        req = self.dec.req
        tok, out, probs = 2, [], []
        run = 0
        for i in range(max_tokens):
            t["input_ids"][0, 0] = tok
            t["pos"][0, 0] = i
            req.infer()
            t["self_k"][:, :, :, i] = req.get_tensor("k_new").data[:, :, :, 0]
            t["self_v"][:, :, :, i] = req.get_tensor("v_new").data[:, :, :, 0]
            t["mask"][0, i] = 0
            logits = req.get_tensor("logits").data[0]
            nxt = int(logits.argmax())
            if nxt == 3:
                break
            # guard against degenerate loops ("おおおおお…"): stop after 16 repeats of one token
            run = run + 1 if nxt == tok else 0
            if run >= 16:
                break
            e = np.exp(logits - logits.max())
            probs.append(float(e[nxt] / e.sum()))
            out.append(nxt)
            tok = nxt
        text = "".join(self.vocab[i] for i in out if i > 4 and not self.vocab[i].startswith("<unused"))
        return postprocess_mocr(text), (float(np.mean(probs)) if probs else 0.0)


def postprocess_mocr(text):
    return "".join(text.split())


_FW_ALNUM = {c: chr(ord(c) - 0xFEE0) for c in
             "０１２３４５６７８９ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ"}


def _is_jp(ch):
    o = ord(ch)
    return 0x3000 <= o <= 0x30FF or 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xFF01 <= o <= 0xFF60


def normalize_jp(text):
    """Uniform output for both recognisers: half-width letters/digits, full-width ！？ next to
    Japanese, runs of dots / middle dots / ellipses -> … or ……"""
    import re
    text = "".join(_FW_ALNUM.get(c, c) for c in text)
    def _dots(m):
        n = sum(3 if c == "…" else 2 if c == "‥" else 1 for c in m.group(0))
        return "…" if n <= 3 else "……"
    text = re.sub(r"[.・…．‥]{2,}|…", _dots, text)
    out = []
    for i, c in enumerate(text):
        if c in "!?":
            prev = out[-1] if out else ""
            nxt = text[i + 1] if i + 1 < len(text) else ""
            if (prev and _is_jp(prev)) or (nxt and _is_jp(nxt)):
                c = "！" if c == "!" else "？"
        out.append(c)
    return "".join(out)


def split_long(crop, vertical, max_chars=10):
    """Split a long single text line into chunks of <= max_chars character cells, cutting at the
    least-inked row/column near each target position (i.e. in the gap between two characters)."""
    a = crop if vertical else crop.transpose(1, 0, 2)
    L, T = a.shape[0], max(1, a.shape[1])
    n = int(math.ceil(L / (max_chars * T)))
    if n <= 1:
        return [crop]
    g = cv2.cvtColor(np.ascontiguousarray(a), cv2.COLOR_RGB2GRAY).astype(np.float32)
    ink = np.abs(g - np.median(g)).sum(axis=1)
    ink = np.convolve(ink, np.ones(3) / 3, mode="same")
    cuts = [0]
    for k in range(1, n):
        target = k * L / n
        lo = max(int(target - 0.6 * T), cuts[-1] + T // 2)
        hi = min(int(target + 0.6 * T), L - 1)
        if lo >= hi:
            cuts.append(int(target))
            continue
        seg = ink[lo:hi]
        m = int(np.argmin(seg))
        # cut in the middle of the low-ink run (the gap between two characters)
        thr = seg[m] + 0.05 * (seg.max() - seg[m] + 1e-6)
        g0 = g1 = m
        while g0 > 0 and seg[g0 - 1] <= thr:
            g0 -= 1
        while g1 < len(seg) - 1 and seg[g1 + 1] <= thr:
            g1 += 1
        cuts.append(lo + (g0 + g1) // 2)
    cuts.append(L)
    pieces = [a[cuts[i]:cuts[i + 1]] for i in range(n) if cuts[i + 1] - cuts[i] > 2]
    return [np.ascontiguousarray(p if vertical else p.transpose(1, 0, 2)) for p in pieces]


# --------------------------------------------------------------------------- layout
class Line:
    __slots__ = ("quad", "score", "x0", "y0", "x1", "y1", "vertical", "text", "conf", "engine", "block", "free")

    def __init__(self, quad, score):
        self.quad = quad
        self.score = score
        self.x0, self.y0 = float(quad[:, 0].min()), float(quad[:, 1].min())
        self.x1, self.y1 = float(quad[:, 0].max()), float(quad[:, 1].max())
        w = max(np.linalg.norm(quad[0] - quad[1]), np.linalg.norm(quad[2] - quad[3]))
        h = max(np.linalg.norm(quad[0] - quad[3]), np.linalg.norm(quad[1] - quad[2]))
        self.vertical = bool(h >= 1.5 * w)
        self.text, self.conf, self.engine, self.block = "", 0.0, "", -1
        self.free = [1e9, 1e9]  # free space before/after the line across the reading direction

    @property
    def w(self):
        return self.x1 - self.x0

    @property
    def h(self):
        return self.y1 - self.y0

    @property
    def thick(self):  # line thickness ~ character size
        return self.w if self.vertical else self.h

    @property
    def length(self):
        return self.h if self.vertical else self.w


def _overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def compute_free_space(lines):
    """For each line, the gap to the nearest other line on either side across the line direction
    (above/below for horizontal lines, left/right for vertical columns)."""
    for a in lines:
        lo = hi = 1e9
        for b in lines:
            if b is a:
                continue
            if a.vertical:
                if _overlap(a.y0, a.y1, b.y0, b.y1) <= 0:
                    continue
                if b.x1 <= a.x0 + 0.5 * a.w:
                    lo = min(lo, max(0.0, a.x0 - b.x1))
                elif b.x0 >= a.x1 - 0.5 * a.w:
                    hi = min(hi, max(0.0, b.x0 - a.x1))
            else:
                if _overlap(a.x0, a.x1, b.x0, b.x1) <= 0:
                    continue
                if b.y1 <= a.y0 + 0.5 * a.h:
                    lo = min(lo, max(0.0, a.y0 - b.y1))
                elif b.y0 >= a.y1 - 0.5 * a.h:
                    hi = min(hi, max(0.0, b.y0 - a.y1))
        a.free = [lo, hi]


def line_crop(img, l, along, across):
    """Crop around a line with `along` padding in the reading direction and `across` padding
    perpendicular to it, never reaching more than 45% into the gap to a neighbouring line."""
    lo = min(across, 0.45 * l.free[0])
    hi = min(across, 0.45 * l.free[1])
    H, W = img.shape[:2]
    if l.vertical:
        x0, x1, y0, y1 = l.x0 - lo, l.x1 + hi, l.y0 - along, l.y1 + along
    else:
        x0, x1, y0, y1 = l.x0 - along, l.x1 + along, l.y0 - lo, l.y1 + hi
    x0, y0 = max(0, int(x0)), max(0, int(y0))
    x1, y1 = min(W, int(math.ceil(x1))), min(H, int(math.ceil(y1)))
    return img[y0:y1, x0:x1]


def drop_ruby(lines):
    """Remove furigana: a line much thinner than a neighbour that hugs it (above a horizontal
    line, right of a vertical column) is a reading aid, not text."""
    keep = []
    for a in lines:
        ruby = False
        for b in lines:
            if b is a or b.vertical != a.vertical or a.thick >= 0.75 * b.thick:
                continue
            if a.vertical:   # reading column hugging the right side of a column
                cx = (a.x0 + a.x1) / 2
                ruby = (cx > b.x1 - 0.25 * b.w and a.x0 < b.x1 + 0.6 * b.thick
                        and _overlap(a.y0, a.y1, b.y0, b.y1) > 0.5 * a.h)
            else:            # reading line sitting on top of a line
                cy = (a.y0 + a.y1) / 2
                ruby = (cy < b.y0 + 0.25 * b.h and a.y1 > b.y0 - 0.6 * b.thick
                        and _overlap(a.x0, a.x1, b.x0, b.x1) > 0.5 * a.w)
            if ruby:
                break
        if not ruby:
            keep.append(a)
    return keep


def group_blocks(lines):
    """Union-find grouping of lines into blocks (paragraphs / bubbles)."""
    n = len(lines)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        a = lines[i]
        for j in range(i + 1, n):
            b = lines[j]
            if a.vertical != b.vertical:
                continue
            ta, tb = a.thick, b.thick
            big = max(ta, tb)
            if a.vertical:
                gap = max(a.x0, b.x0) - min(a.x1, b.x1)  # horizontal gap between columns
                ov = _overlap(a.y0, a.y1, b.y0, b.y1) / max(1.0, min(a.h, b.h))
                tops_close = abs(a.y0 - b.y0) < 2.5 * big
                ok = gap < 1.2 * big and (ov > 0.3 or tops_close) and min(ta, tb) > 0.3 * big
            else:
                gap = max(a.y0, b.y0) - min(a.y1, b.y1)  # vertical gap between lines
                ov = _overlap(a.x0, a.x1, b.x0, b.x1) / max(1.0, min(a.w, b.w))
                lefts_close = abs(a.x0 - b.x0) < 1.5 * big
                ok = gap < 1.0 * big and (ov > 0.3 or lefts_close) and min(ta, tb) > 0.55 * big
            if ok:
                parent[find(i)] = find(j)
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(lines[i])
    blocks = []
    for g in groups.values():
        if g[0].vertical:
            g.sort(key=lambda l: -l.x1)  # columns right -> left
        else:
            g.sort(key=lambda l: l.y0)  # lines top -> bottom
        blocks.append(g)
    return blocks


def order_blocks(blocks):
    """Reading order: vertical-majority pages go right->left then top->bottom; else top->bottom, left->right."""
    if not blocks:
        return blocks
    nv = sum(len(b) for b in blocks if b[0].vertical)
    nh = sum(len(b) for b in blocks if not b[0].vertical)

    def box(b):
        return min(l.x0 for l in b), min(l.y0 for l in b), max(l.x1 for l in b), max(l.y1 for l in b)

    if nv > nh:
        # manga order: a block comes first if it is above (no vertical overlap) or to the right
        def key(b):
            x0, y0, x1, y1 = box(b)
            return (-x1, y0)
        rows = []
        for b in sorted(blocks, key=lambda b: box(b)[1]):
            x0, y0, x1, y1 = box(b)
            for r in rows:
                if _overlap(r[0], r[1], y0, y1) > 0.3 * min(r[1] - r[0], y1 - y0):
                    r[2].append(b)
                    r[0], r[1] = min(r[0], y0), max(r[1], y1)
                    break
            else:
                rows.append([y0, y1, [b]])
        return [b for r in sorted(rows, key=lambda r: r[0]) for b in sorted(r[2], key=key)]
    rows = []
    for b in sorted(blocks, key=lambda b: box(b)[1]):
        x0, y0, x1, y1 = box(b)
        for r in rows:
            if _overlap(r[0], r[1], y0, y1) > 0.5 * min(r[1] - r[0], y1 - y0):
                r[2].append(b)
                r[0], r[1] = min(r[0], y0), max(r[1], y1)
                break
        else:
            rows.append([y0, y1, [b]])
    return [b for r in sorted(rows, key=lambda r: r[0]) for b in sorted(r[2], key=lambda b: box(b)[0])]


def _join(parts):
    out = ""
    for p in parts:
        if out and p and out[-1].isascii() and out[-1].isalnum() and p[0].isascii() and p[0].isalnum():
            out += " "
        out += p
    return out


# --------------------------------------------------------------------------- engine
class Engine:
    def __init__(self, device=None, det="ppocrv6_det_small", rec="ppocrv6_rec_small", mocr="manga_ocr_base",
                 strategy="auto", mocr_max_aspect=8.0):
        os.makedirs(CACHE, exist_ok=True)
        self.core = ov.Core()
        self.core.set_property({"CACHE_DIR": CACHE})
        self.device = device or pick_device(core=self.core)
        self.lock = threading.Lock()
        self.strategy = strategy
        self.mocr_max_aspect = mocr_max_aspect
        t = time.time()
        self.det = Detector(self.core, os.path.join(MODELS, det, "inference.onnx"), self.device)
        self.rec = LineRecognizer(self.core, os.path.join(MODELS, rec, "inference.onnx"),
                                  os.path.join(MODELS, rec, "inference.yml"), self.device)
        self.mocr = MangaOCR(self.core, os.path.join(MODELS, mocr, "ov"), self.device)
        self.det.warmup()
        self.rec.warmup()
        self.load_seconds = time.time() - t

    def warm_all(self):
        """Run every compiled shape once: the first NPU inference of a blob is several times slower."""
        with self.lock:
            for cm in list(self.det.models.values()) + list(self.rec.models.values()):
                inp = cm.cm.inputs[0]
                shape = list(inp.get_partial_shape().get_min_shape()) if inp.get_partial_shape().is_dynamic else list(inp.shape)
                shape = [max(1, int(v)) if v else 32 for v in shape]
                if inp.get_partial_shape().is_dynamic:
                    shape = [1, 64, 320, 3]
                cm.req.infer({0: np.zeros(shape, dtype=np.uint8)})
            self.mocr(np.full((64, 64, 3), 255, np.uint8), max_tokens=2)

    # -- recognition of one block --------------------------------------------------------
    def _mocr_crop(self, img, x0, y0, x1, y1, thick):
        """Crop for manga-ocr with a generous margin (it was trained on loosely framed bubbles)."""
        return crop_rect(img, x0, y0, x1, y1, pad=max(4.0, 0.5 * thick))

    def _rec_block(self, img, block):
        vertical = block[0].vertical
        thick = float(np.median([l.thick for l in block]))
        # furigana / ruby: much thinner lines inside a block are readings, not text
        main = [l for l in block if l.thick >= 0.6 * thick] or block
        x0 = min(l.x0 for l in block)
        y0 = min(l.y0 for l in block)
        x1 = max(l.x1 for l in block)
        y1 = max(l.y1 for l in block)
        if vertical:
            maxchars = max(l.length / max(1.0, l.thick) for l in main)
            if self.strategy != "rec" and maxchars <= 16 and len(main) <= 8:
                txt, conf = self.mocr(self._mocr_crop(img, x0, y0, x1, y1, thick))
                for l in block:
                    l.engine = "manga-ocr(block)"
                return normalize_jp(txt), conf
            parts, confs = [], []
            for l in main:
                parts.append(self._rec_vertical_line(img, l))
                confs.append(l.conf)
            return normalize_jp("".join(parts)), float(np.mean(confs))
        parts, confs = [], []
        for l in main:
            parts.append(self._rec_horizontal_line(img, l))
            confs.append(l.conf)
        return normalize_jp(_join(parts)), float(np.mean(confs))

    def _rec_vertical_line(self, img, l):
        if self.strategy == "rec":
            crop = crop_rect(img, l.x0, l.y0, l.x1, l.y1, pad=0.1 * l.thick)
            l.text, l.conf = self.rec(np.ascontiguousarray(np.rot90(crop)))
            l.engine = "ppocr"
            return l.text
        crop = line_crop(img, l, along=max(3.0, 0.3 * l.thick), across=max(2.0, 0.2 * l.thick))
        pieces = split_long(crop, True, max_chars=10) if l.length / max(1.0, l.thick) > 14 else [crop]
        texts, confs = [], []
        for p in pieces:
            t, c = self.mocr(p)
            texts.append(t)
            confs.append(c)
        l.text, l.conf = normalize_jp("".join(texts)), float(np.mean(confs))
        l.engine = "manga-ocr" if len(pieces) == 1 else f"manga-ocr(x{len(pieces)})"
        return l.text

    def _rec_horizontal_line(self, img, l):
        if self.strategy == "mocr" or (self.strategy == "auto-mocr" and l.w / max(1.0, l.h) <= self.mocr_max_aspect):
            l.text, l.conf = self.mocr(line_crop(img, l, along=max(4.0, 0.5 * l.h), across=max(2.0, 0.2 * l.h)))
            l.engine = "manga-ocr"
        else:
            crop = crop_quad(img, l.quad) if abs(l.quad[0, 1] - l.quad[1, 1]) > 2 else crop_rect(img, l.x0, l.y0, l.x1, l.y1)
            l.text, l.conf = self.rec(crop)
            l.engine = "ppocr"
        l.text = normalize_jp(l.text)
        return l.text

    # -- public API ---------------------------------------------------------------------------
    def ocr(self, img, direction="auto", mode="auto"):
        """img: RGB uint8 array. direction: auto|horizontal|vertical. mode: auto|block|lines.
        Returns dict(text, blocks=[{text, vertical, box, lines=[{text, box, conf, engine}]}], timings)."""
        with self.lock:
            return self._ocr(img, direction, mode)

    def _ocr(self, img, direction, mode):
        t0 = time.perf_counter()
        H, W = img.shape[:2]
        if mode == "block":
            txt, conf = self.mocr(img)
            txt = normalize_jp(txt)
            t1 = time.perf_counter()
            box = [0, 0, W, H]
            return {"text": txt, "blocks": [{"text": txt, "vertical": direction == "vertical", "box": box, "conf": conf,
                                              "lines": [{"text": txt, "box": box, "conf": conf, "engine": "manga-ocr(block)"}]}],
                    "timings": {"det_ms": 0.0, "rec_ms": round((t1 - t0) * 1000, 1), "total_ms": round((t1 - t0) * 1000, 1)},
                    "size": [W, H], "device": self.device}
        dets = self.det(img)
        t1 = time.perf_counter()
        lines = [Line(q, s) for q, s in dets]
        if direction in ("vertical", "horizontal"):
            for l in lines:
                l.vertical = direction == "vertical"
        elif lines:
            # near-square boxes (1-3 characters) follow the majority orientation
            nv = sum(1 for l in lines if l.vertical)
            nh = sum(1 for l in lines if not l.vertical and l.w > 1.5 * l.h)
            for l in lines:
                if not l.vertical and l.w <= 1.5 * l.h and nv > nh:
                    l.vertical = True
        lines = drop_ruby(lines)
        compute_free_space(lines)
        blocks = order_blocks(group_blocks(lines))
        out_blocks = []
        if not blocks:
            # nothing detected: stylised text? let manga-ocr try the whole region
            txt, conf = self.mocr(img)
            txt = normalize_jp(txt)
            if txt and conf > 0.5:
                out_blocks.append({"text": txt, "vertical": H > W, "box": [0, 0, W, H], "conf": round(conf, 3),
                                   "lines": [{"text": txt, "box": [0, 0, W, H], "conf": round(conf, 3), "engine": "manga-ocr(fallback)"}]})
        for b in blocks:
            txt, conf = self._rec_block(img, b)
            x0, y0 = min(l.x0 for l in b), min(l.y0 for l in b)
            x1, y1 = max(l.x1 for l in b), max(l.y1 for l in b)
            out_blocks.append({
                "text": txt, "vertical": bool(b[0].vertical), "conf": round(conf, 3),
                "box": [round(x0), round(y0), round(x1), round(y1)],
                "lines": [{"text": l.text, "conf": round(l.conf, 3), "engine": l.engine,
                           "box": [round(l.x0), round(l.y0), round(l.x1), round(l.y1)],
                           "quad": [[round(float(p[0]), 1), round(float(p[1]), 1)] for p in l.quad]} for l in b],
            })
        t2 = time.perf_counter()
        return {"text": "\n".join(b["text"] for b in out_blocks if b["text"]),
                "blocks": out_blocks,
                "timings": {"det_ms": round((t1 - t0) * 1000, 1), "rec_ms": round((t2 - t1) * 1000, 1),
                            "total_ms": round((t2 - t0) * 1000, 1)},
                "size": [W, H], "device": self.device}
