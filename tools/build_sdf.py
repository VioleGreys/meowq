#!/usr/bin/env python3
"""Поле расстояний до границ провинций (SDF) для отрисовки линий границ:
data/world1936/sdf_w.png.bin, sdf_e.png.bin (L8, сетка карты провинций 2×,
половинами как ids2 — tools/build_ids2x.py). Значение — расстояние от центра
текселя до ближайшей границы провинций, в текселях сетки 2× (0…2 → 0…255).

Границы — по той же сглаженной карте, что рисует шейдер: в каждой точке
провинция с наибольшим весом кубического B-сплайна по окну 4×4 сетки 2× (+
перевес ближних 0.35, как в шейдере), посчитанная вчетверо подробнее сетки 2×.
Шейдер берёт поле билинейно — линии гладкие на любом приближении, а заливка
провинций с ними совпадает.

  python3 tools/build_sdf.py
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402
from build_ids2x import PAD, bspline  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")
SUB = 4          # точек на тексель сетки 2× по каждой оси
MAXD = 2.0       # предел расстояния, текселей сетки 2×


def load_ids2() -> np.ndarray:
    parts = []
    for k in ("w", "e"):
        a = np.asarray(Image.open(os.path.join(DATA, f"ids2_{k}.png.bin")).convert("RGB")).astype(np.int32)
        parts.append(a[..., 0] + a[..., 1] * 256)
    w, e = parts
    half = w.shape[1] - PAD
    return np.concatenate([w[:, :half], e[:, PAD:]], 1)


def smooth_labels(ids: np.ndarray, r0: int, r1: int) -> np.ndarray:
    """Сглаженные метки в точках SUB×SUB на тексель для строк сетки [r0, r1)."""
    H, W = ids.shape
    xs = (np.arange(W * SUB) + 0.5) / SUB - 0.5
    ix0 = np.floor(xs).astype(np.int64)
    wx = bspline((xs - ix0).astype(np.float32))
    ys = (np.arange(r0 * SUB, r1 * SUB) + 0.5) / SUB - 0.5
    iy0 = np.floor(ys).astype(np.int64)
    wy = bspline((ys - iy0).astype(np.float32))
    labs, wts = [], []
    for oy in range(4):
        yy = np.clip(iy0 + oy - 1, 0, H - 1)
        for ox in range(4):
            xx = np.clip(ix0 + ox - 1, 0, W - 1)
            labs.append(ids[yy][:, xx])
            wts.append(wy[oy][:, None] * wx[ox][None, :])
    L = np.stack(labs, -1)
    Wt = np.stack(wts, -1)
    tot = np.zeros_like(Wt)
    for i in range(16):
        tot[..., i] = (Wt * (L == L[..., i:i + 1])).sum(-1)
    k = np.argmax(tot, -1)
    return np.take_along_axis(L, k[..., None], -1)[..., 0]


def main():
    ids = load_ids2()
    H, W = ids.shape
    sdf = np.zeros((H, W), np.uint8)
    band = 12                        # строк сетки 2× в полосе
    ov = int(np.ceil(MAXD)) + 1      # перекрытие полос (строк сетки 2×)
    for r0 in range(0, H, band):
        r1 = min(H, r0 + band)
        a0, a1 = max(0, r0 - ov), min(H, r1 + ov)
        lab = smooth_labels(ids, a0, a1)
        edge = np.zeros(lab.shape, bool)
        edge[:, 1:] |= lab[:, 1:] != lab[:, :-1]
        edge[1:, :] |= lab[1:, :] != lab[:-1, :]
        d = ndimage.distance_transform_edt(~edge)
        # в центре текселя сетки 2×: точка (SUB/2, SUB/2) внутри него; граница —
        # между точками, поэтому −0.5 точки
        c = SUB // 2
        dc = d[(r0 - a0) * SUB + c:(r1 - a0) * SUB:SUB, c::SUB][: r1 - r0, :W]
        dt = np.clip((dc - 0.5) / SUB, 0, MAXD)
        sdf[r0:r1] = np.round(dt / MAXD * 255).astype(np.uint8)
        if r0 % 600 < band:
            print(f"  строки {r0}/{H}", flush=True)
    half = W // 2
    for nm, a in (("w", sdf[:, : half + PAD]), ("e", sdf[:, half - PAD:])):
        path = os.path.abspath(os.path.join(DATA, f"sdf_{nm}.png.bin"))
        Image.fromarray(a, "L").save(path, "PNG", optimize=True)
        print(f"sdf_{nm} {a.shape[1]}x{a.shape[0]}: {path} ({os.path.getsize(path) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
