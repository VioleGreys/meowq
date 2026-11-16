#!/usr/bin/env python3
"""Нормали волн для воды на карте — свои, процедурные (лицензия не нужна):
бесшовный периодический шум (спектр ~1/f² в кольце частот, через БПФ — тайл
повторяется без шва), лёгкая вытянутость по ветру. R, G — наклон (0.5 — ровно).
Результат — data/world1936/water.png.bin (512×512).

  python3 tools/build_water.py
"""
import os
import sys

import numpy as np
from PIL import Image

N = 512


def main():
    rng = np.random.default_rng(1936)
    fy = np.fft.fftfreq(N)[:, None]
    fx = np.fft.fftfreq(N)[None, :]
    # ветер с запада: волны длиннее поперёк, короче вдоль
    f = np.sqrt((fx * 0.9) ** 2 + (fy * 1.1) ** 2)
    amp = np.where((f > 4.0 / N) & (f < 90.0 / N), 1.0 / np.maximum(f, 1e-6) ** 1.6, 0.0)
    spec = amp * np.exp(2j * np.pi * rng.random((N, N)))
    h = np.real(np.fft.ifft2(spec))
    h = (h - h.mean()) / h.std()
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    gy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    k = 0.6 / np.percentile(np.abs(np.concatenate([gx.ravel(), gy.ravel()])), 98)
    nx, ny = -gx * k, -gy * k
    ln = np.sqrt(nx * nx + ny * ny + 1.0)
    img = np.zeros((N, N, 3), np.uint8)
    img[..., 0] = np.clip((nx / ln * 0.5 + 0.5) * 255 + 0.5, 0, 255)
    img[..., 1] = np.clip((ny / ln * 0.5 + 0.5) * 255 + 0.5, 0, 255)
    out = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "world1936", "water.png.bin"))
    Image.fromarray(img, "RGB").save(out, "PNG", optimize=True)
    print(f"Нормали волн {N}x{N}: {out} ({os.path.getsize(out) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
