#!/usr/bin/env python3
"""Подложка рельефа для карты: спутниковый снимок NASA Blue Marble
(«Whole world — land and oceans», общественное достояние, Викисклад) в проекции
карты игры (Миллер, как tools/build_map.py), в половинном разрешении.

Берём только сушу: цвет снимка чуть приглушаем под «бумажную» карту; океан игра
рисует сама. Результат — data/world1936/terrain.jpg.bin (JPEG).

  python3 tools/build_terrain.py --src путь/к/снимку.jpg
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

Image.MAX_IMAGE_PIXELS = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="снимок в равнопромежуточной проекции (долгота -180..180)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "world1936", "terrain.jpg.bin"))
    ap.add_argument("--scale", type=int, default=2, help="во сколько раз меньше карты")
    args = ap.parse_args()
    src = np.asarray(Image.open(args.src).convert("RGB"), dtype=np.float32) / 255.0
    sh, sw = src.shape[:2]
    w, h = bm.WIDTH // args.scale, int(round(bm.HEIGHT / args.scale))
    py, px = np.mgrid[0:h, 0:w].astype(np.float64)
    lon, lat = bm.unproject((px + 0.5) * args.scale, (py + 0.5) * args.scale)
    u = (np.asarray(lon) + 180.0) / 360.0 * sw - 0.5
    v = (90.0 - np.asarray(lat)) / 180.0 * sh - 0.5
    u0 = np.floor(u).astype(np.int64)
    v0 = np.clip(np.floor(v).astype(np.int64), 0, sh - 2)
    fu = (u - u0)[..., None]
    fv = np.clip(v - v0, 0, 1)[..., None]
    u0 %= sw
    u1 = (u0 + 1) % sw
    c = (src[v0, u0] * (1 - fu) * (1 - fv) + src[v0, u1] * fu * (1 - fv)
         + src[v0 + 1, u0] * (1 - fu) * fv + src[v0 + 1, u1] * fu * fv)
    # под карту: немного приглушить насыщенность и поднять тени
    lum = (c * np.array([0.299, 0.587, 0.114])).sum(-1, keepdims=True)
    c = lum + (c - lum) * 0.8
    c = np.clip(0.08 + c * 1.05, 0, 1) ** 0.9
    img = Image.fromarray((c * 255).astype(np.uint8), "RGB")
    out = os.path.abspath(args.out)
    img.save(out, "JPEG", quality=88, optimize=True)
    print(f"Подложка {w}x{h}: {out} ({os.path.getsize(out) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
