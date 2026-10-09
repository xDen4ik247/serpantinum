"""Synthesize the little UI sounds (stdlib only): soft chime, low thud, level-up arpeggio."""

import math
import struct
import sys
import wave
from pathlib import Path

RATE = 44100


def tone(freqs, dur, vol=0.35, attack=0.005, decay=6.0, shimmer=0.0):
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack) * math.exp(-decay * t)
        s = sum(math.sin(2 * math.pi * f * t) + shimmer * math.sin(4 * math.pi * f * t) for f in freqs) / len(freqs)
        out.append(vol * env * s)
    return out


def seq(parts, gap=0.0):
    out = []
    for p in parts:
        out += p + [0.0] * int(RATE * gap)
    return out


def write(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in samples))


def main(out_dir):
    d = Path(out_dir)
    d.mkdir(parents=True, exist_ok=True)
    # correct: two quick bright notes (E6 -> A6), bell-like
    a = tone([1318.5], 0.09, 0.30, decay=18, shimmer=0.25)
    b = tone([1760.0], 0.28, 0.32, decay=9, shimmer=0.25)
    write(d / "correct.wav", seq([a, b]))
    # wrong: soft low two-step down, muted
    write(d / "wrong.wav", seq([tone([233.1, 220.0], 0.12, 0.30, decay=14), tone([196.0, 185.0], 0.22, 0.30, decay=10)]))
    # level up: rising arpeggio C6 E6 G6 C7
    notes = [1046.5, 1318.5, 1568.0, 2093.0]
    write(d / "levelup.wav", seq([tone([f], 0.11 if i < 3 else 0.45, 0.28, decay=8 if i < 3 else 5, shimmer=0.3)
                                  for i, f in enumerate(notes)]))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets")
