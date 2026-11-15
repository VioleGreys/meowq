#!/usr/bin/env python3
"""Детальные текстуры местности для близкого масштаба карты (как набор
текстур местности в картах жанра): четыре бесшовных тайла ambientCG (CC0) —
трава Grass004, скалы Rock030, песок Ground054, снег Snow006 — в одну RGBA
текстуру, по каналу на тайл (яркость, высокие частоты, среднее 0.5).
Шейдер карты смешивает каналы по цвету местности и крутизне рельефа и
кладёт деталь поверх цвета. Результат — data/world1936/detail.png.bin.

  python3 tools/build_detail.py --dir папка_с_распакованными_архивами
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

TILES = ["Grass004", "Rock030", "Ground054", "Snow006"]   # R, G, B, A
SIZE = 512


def channel(path: str) -> np.ndarray:
    im = Image.open(path).convert("L").resize((SIZE, SIZE), Image.LANCZOS)
    a = np.asarray(im, np.float32) / 255.0
    # высокие частоты: минус размытая копия (крупные пятна тайла дают повторы)
    low = np.asarray(im.filter(ImageFilter.GaussianBlur(24)), np.float32) / 255.0
    d = a - low
    d = d / max(1e-6, np.percentile(np.abs(d), 98)) * 0.42
    return np.clip(0.5 + d, 0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "world1936", "detail.png.bin"))
    args = ap.parse_args()
    chans = [channel(os.path.join(args.dir, t, f"{t}_1K-JPG_Color.jpg")) for t in TILES]
    rgba = (np.stack(chans, -1) * 255).astype(np.uint8)
    out = os.path.abspath(args.out)
    Image.fromarray(rgba, "RGBA").save(out, "PNG", optimize=True)
    print(f"Детальные текстуры {SIZE}x{SIZE}: {out} ({os.path.getsize(out) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
