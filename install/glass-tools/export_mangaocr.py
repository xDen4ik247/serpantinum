"""Export manga-ocr (kha-white/manga-ocr-base) to the static-shape OpenVINO IR that jocr runs on the NPU.

    python export_mangaocr.py <hf model dir> <output dir> [--T 128]

Writes <output dir>/encoder.xml (pixel_values [1,3,224,224] -> cross_k, cross_v), decoder_step_b1_t<T>.xml
(one token per call with a static self-attention KV cache of T slots), meta.json and vocab.txt.
Needs torch (CPU), transformers, pillow and openvino; the glass installer runs it once in a throwaway venv.
A parity check compares the static greedy loop with transformers' own greedy generate first.
"""
import json
import os
import shutil
import sys

import numpy as np
import torch
import torch.nn as nn
from PIL import Image, ImageDraw
from transformers import VisionEncoderDecoderModel

torch.set_grad_enabled(False)
MODEL, OUT = sys.argv[1], sys.argv[2]
T = int(sys.argv[sys.argv.index("--T") + 1]) if "--T" in sys.argv else 128
START, EOS = 2, 3

model = VisionEncoderDecoderModel.from_pretrained(MODEL).eval()


def preprocess(img):
    img = img.convert("L").convert("RGB").resize((224, 224), Image.BILINEAR)
    x = np.asarray(img, dtype=np.float32) / 255.0
    x = (x - 0.5) / 0.5
    return torch.from_numpy(x.transpose(2, 0, 1)[None].copy())


class EncoderKV(nn.Module):
    """pixel_values -> per-layer cross-attention K and V, shape [L, 1, H, S, Dh]."""

    def __init__(self, m):
        super().__init__()
        self.enc = m.encoder
        self.proj = m.enc_to_dec_proj if getattr(m, "enc_to_dec_proj", None) is not None else None
        self.layers = m.decoder.bert.encoder.layer
        c = m.decoder.config
        self.H = c.num_attention_heads
        self.Dh = c.hidden_size // c.num_attention_heads

    def forward(self, pixel_values):
        h = self.enc(pixel_values=pixel_values).last_hidden_state
        if self.proj is not None:
            h = self.proj(h)
        B, S, _ = h.shape
        ks, vs = [], []
        for layer in self.layers:
            a = layer.crossattention.self
            ks.append(a.key(h).view(B, S, self.H, self.Dh).transpose(1, 2))
            vs.append(a.value(h).view(B, S, self.H, self.Dh).transpose(1, 2))
        return torch.stack(ks), torch.stack(vs)


class Step(nn.Module):
    """One decoder step with a static self-attention KV cache of T slots.

    input_ids [B,1] int64, pos [B,1] int64, mask [B,T] float (0 valid / -1e4 empty),
    self_k/self_v [L,B,H,T,Dh], cross_k/cross_v [L,B,H,S,Dh] -> logits [B,V], k_new/v_new [L,B,H,1,Dh]
    """

    def __init__(self, m):
        super().__init__()
        d = m.decoder
        self.emb = d.bert.embeddings
        self.layers = d.bert.encoder.layer
        self.head = d.cls
        c = d.config
        self.H = c.num_attention_heads
        self.Dh = c.hidden_size // c.num_attention_heads
        self.scale = 1.0 / (self.Dh ** 0.5)

    def heads(self, x):
        B, S, _ = x.shape
        return x.view(B, S, self.H, self.Dh).transpose(1, 2)

    def forward(self, input_ids, pos, mask, self_k, self_v, cross_k, cross_v):
        e = self.emb
        x = e.word_embeddings(input_ids) + e.position_embeddings(pos) + e.token_type_embeddings.weight[0]
        x = e.LayerNorm(x)
        B = x.shape[0]
        m = torch.cat([mask, torch.zeros(B, 1, dtype=mask.dtype)], dim=1)[:, None, None, :]  # [B,1,1,T+1]
        ks, vs = [], []
        for i, layer in enumerate(self.layers):
            sa = layer.attention.self
            q = self.heads(sa.query(x))
            k = self.heads(sa.key(x))
            v = self.heads(sa.value(x))
            K = torch.cat([self_k[i], k], dim=2)
            V = torch.cat([self_v[i], v], dim=2)
            p = torch.softmax(q @ K.transpose(-1, -2) * self.scale + m, dim=-1)
            ctx = (p @ V).transpose(1, 2).reshape(B, 1, -1)
            x = layer.attention.output.LayerNorm(layer.attention.output.dense(ctx) + x)
            ca = layer.crossattention.self
            q = self.heads(ca.query(x))
            p = torch.softmax(q @ cross_k[i].transpose(-1, -2) * self.scale, dim=-1)
            ctx = (p @ cross_v[i]).transpose(1, 2).reshape(B, 1, -1)
            x = layer.crossattention.output.LayerNorm(layer.crossattention.output.dense(ctx) + x)
            h = layer.output.dense(layer.intermediate.intermediate_act_fn(layer.intermediate.dense(x)))
            x = layer.output.LayerNorm(h + x)
            ks.append(k)
            vs.append(v)
        logits = self.head(x)[:, 0]
        return logits, torch.stack(ks), torch.stack(vs)


def greedy_static(enc, step, px, maxlen=T):
    ck, cv = enc(px)
    L, B, H, S, Dh = ck.shape
    sk = torch.zeros(L, 1, H, T, Dh)
    sv = torch.zeros(L, 1, H, T, Dh)
    mask = torch.full((1, T), -1e4)
    tok, out = START, []
    for t in range(maxlen):
        logits, k, v = step(torch.tensor([[tok]]), torch.tensor([[t]]), mask, sk, sv, ck, cv)
        sk[:, :, :, t] = k[:, :, :, 0]
        sv[:, :, :, t] = v[:, :, :, 0]
        mask[0, t] = 0
        tok = int(logits[0].argmax())
        if tok == EOS:
            break
        out.append(tok)
    return out


def test_images():
    """A few synthetic text-like images (no fonts needed): strokes, boxes, a vertical column."""
    rng = np.random.default_rng(7)
    imgs = []
    for k in range(3):
        im = Image.new("L", (160 + 80 * k, 64 if k != 2 else 300), 255)
        d = ImageDraw.Draw(im)
        for _ in range(12 + 6 * k):
            x, y = rng.integers(0, im.width - 20), rng.integers(0, im.height - 20)
            d.line([(x, y), (x + rng.integers(4, 20), y + rng.integers(-8, 20))], fill=0, width=3)
        imgs.append(im.convert("RGB"))
    return imgs


enc = EncoderKV(model).eval()
step = Step(model).eval()
ok = 0
imgs = test_images()
for i, img in enumerate(imgs):
    px = preprocess(img)
    a = greedy_static(enc, step, px)
    b = model.generate(px, max_length=T, num_beams=1, no_repeat_ngram_size=0)[0].tolist()[1:]   # drop the start token
    if b and b[-1] == EOS:
        b = b[:-1]
    n = min(len(a), len(b))
    same = a[:n] == b[:n] and (len(a) == len(b) or n >= T - 2)   # equal, or both cut off by the length limit
    ok += same
    print(f"parity image {i}: {'ok' if same else 'DIFFERENT'} ({len(a)} tokens)", flush=True)
if ok != len(imgs):
    raise SystemExit("parity check failed: the static decoder does not match transformers' greedy output")

import openvino as ov  # noqa: E402  (after torch: keeps the import order the export was tested with)

os.makedirs(OUT, exist_ok=True)
px = torch.zeros(1, 3, 224, 224)
ck, cv = enc(px)
L, B, H, S, Dh = ck.shape
ov_enc = ov.convert_model(enc, example_input=(px,), input=[("pixel_values", [1, 3, 224, 224], ov.Type.f32)])
ov_enc.outputs[0].get_tensor().set_names({"cross_k"})
ov_enc.outputs[1].get_tensor().set_names({"cross_v"})
ov.save_model(ov_enc, os.path.join(OUT, "encoder.xml"), compress_to_fp16=True)
ex = (torch.tensor([[START]]), torch.tensor([[0]]), torch.full((1, T), -1e4),
      torch.zeros(L, 1, H, T, Dh), torch.zeros(L, 1, H, T, Dh), torch.zeros(L, 1, H, S, Dh), torch.zeros(L, 1, H, S, Dh))
names = ["input_ids", "pos", "mask", "self_k", "self_v", "cross_k", "cross_v"]
shapes = [[1, 1], [1, 1], [1, T], [L, 1, H, T, Dh], [L, 1, H, T, Dh], [L, 1, H, S, Dh], [L, 1, H, S, Dh]]
types = [ov.Type.i64, ov.Type.i64] + [ov.Type.f32] * 5
ov_step = ov.convert_model(step, example_input=ex, input=list(zip(names, shapes, types)))
for o, n in zip(ov_step.outputs, ["logits", "k_new", "v_new"]):
    o.get_tensor().set_names({n})
ov.save_model(ov_step, os.path.join(OUT, f"decoder_step_b1_t{T}.xml"), compress_to_fp16=True)
vocab = [line.rstrip("\n") for line in open(os.path.join(MODEL, "vocab.txt"), encoding="utf-8")]
meta = {"layers": L, "heads": H, "head_dim": Dh, "enc_seq": S, "cache_T": T, "vocab": len(vocab),
        "start": START, "eos": EOS, "special": [0, 1, 2, 3, 4]}
json.dump(meta, open(os.path.join(OUT, "meta.json"), "w"), indent=1)
shutil.copy(os.path.join(MODEL, "vocab.txt"), os.path.join(OUT, "vocab.txt"))
print("exported", OUT, meta)
