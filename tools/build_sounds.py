#!/usr/bin/env python3
"""Звуки интерфейса — синтезируются (свои, без сторонних лицензий).

  python3 tools/build_sounds.py  →  assets/sounds/click.wav, toggle.wav
"""
import math
import os
import random
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sounds")


def write(name, samples):
    os.makedirs(OUT, exist_ok=True)
    peak = max(1e-9, max(abs(s) for s in samples))
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(s / peak * 0.8 * 32767)) for s in samples))


def click(base, dur, noise_amt, seed):
    rnd = random.Random(seed)
    n = int(RATE * dur)
    out = []
    lp = 0.0
    for i in range(n):
        t = i / RATE
        env = math.exp(-t * 90.0)
        # «латунный» щелчок: два затухающих тона + короткий шум удара
        tone = math.sin(2 * math.pi * base * t) * 0.6 + math.sin(2 * math.pi * base * 2.76 * t) * 0.25
        lp += (rnd.uniform(-1, 1) - lp) * 0.35
        hit = lp * math.exp(-t * 400.0) * noise_amt
        out.append((tone * env + hit))
    # мягкая атака без щелчка цифрового обрыва
    for i in range(min(40, n)):
        out[i] *= i / 40.0
    return out


write("click.wav", click(1450.0, 0.07, 1.2, 1))
write("toggle.wav", click(980.0, 0.09, 0.8, 2))
print("готово:", os.path.abspath(OUT))
