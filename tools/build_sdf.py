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

  python3 tools/build_sdf.py      (нужен numba: pip install numba; ~минуты)
"""
import os
import sys

import numba
import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402
from build_ids2x import PAD  # noqa: E402

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


@numba.njit(cache=True)
def _wts(f):
    f2 = f * f
    f3 = f2 * f
    w0 = (1 - f) ** 3 / 6
    w1 = (3 * f3 - 6 * f2 + 4) / 6 + (1 - f) * 0.35
    w2 = (-3 * f3 + 3 * f2 + 3 * f + 1) / 6 + f * 0.35
    w3 = f3 / 6
    return w0, w1, w2, w3


@numba.njit(parallel=True, cache=True)
def _labels4(ids, near):
    """Сглаженные метки SUB×SUB на тексель (только у границ; вдали — как есть)."""
    H, W = ids.shape
    out = np.empty((H * SUB, W * SUB), np.int16)
    lab = np.empty(16, np.int32)
    for y in numba.prange(H * SUB):
        lab = np.empty(16, np.int32)
        wt = np.empty(16, np.float32)
        ty = y // SUB
        qy = (y + 0.5) / SUB - 0.5
        iy = int(np.floor(qy))
        wy = _wts(qy - iy)
        for x in range(W * SUB):
            tx = x // SUB
            if not near[ty, tx]:
                out[y, x] = ids[ty, tx]
                continue
            qx = (x + 0.5) / SUB - 0.5
            ix = int(np.floor(qx))
            wx = _wts(qx - ix)
            n = 0
            for oy in range(4):
                yy = min(max(iy + oy - 1, 0), H - 1)
                for ox in range(4):
                    xx = min(max(ix + ox - 1, 0), W - 1)
                    lab[n] = ids[yy, xx]
                    wt[n] = wy[oy] * wx[ox]
                    n += 1
            best = -1.0
            bl = lab[0]
            for a in range(16):
                t = 0.0
                for b in range(16):
                    if lab[b] == lab[a]:
                        t += wt[b]
                if t > best:
                    best = t
                    bl = lab[a]
            out[y, x] = bl
    return out


@numba.njit(parallel=True, cache=True)
def _dist(l4, near, maxd):
    """Расстояние от центра текселя до ближайшей границы сглаженных меток (текселей)."""
    H, W = near.shape
    out = np.empty((H, W), np.uint8)
    R = int(maxd * SUB) + 1
    H4, W4 = l4.shape
    for ty in numba.prange(H):
        for tx in range(W):
            if not near[ty, tx]:
                out[ty, tx] = 255
                continue
            cy = ty * SUB + SUB / 2.0   # центр текселя в координатах точек
            cx = tx * SUB + SUB / 2.0
            best = maxd * SUB
            y0 = max(0, ty * SUB + SUB // 2 - R)
            y1 = min(H4 - 1, ty * SUB + SUB // 2 + R)
            x0 = max(0, tx * SUB + SUB // 2 - R)
            x1 = min(W4 - 1, tx * SUB + SUB // 2 + R)
            for y in range(y0, y1):
                for x in range(x0, x1):
                    a = l4[y, x]
                    # граница между точкой и соседом справа / снизу — в середине
                    if l4[y, x + 1] != a:
                        dx = x + 1.0 - cx
                        dy = y + 0.5 - cy
                        d = np.sqrt(dx * dx + dy * dy)
                        if d < best:
                            best = d
                    if l4[y + 1, x] != a:
                        dx = x + 0.5 - cx
                        dy = y + 1.0 - cy
                        d = np.sqrt(dx * dx + dy * dy)
                        if d < best:
                            best = d
            out[ty, tx] = int(min(best / SUB, maxd) / maxd * 255.0 + 0.5)
    return out


def main():
    ids = load_ids2()
    H, W = ids.shape
    # у границ: в окне ±3 текселя есть другая провинция
    diff = np.zeros((H, W), bool)
    diff[:, 1:] |= ids[:, 1:] != ids[:, :-1]
    diff[:, :-1] |= ids[:, 1:] != ids[:, :-1]
    diff[1:, :] |= ids[1:, :] != ids[:-1, :]
    diff[:-1, :] |= ids[1:, :] != ids[:-1, :]
    near = ndimage.binary_dilation(diff, iterations=3)
    print(f"Текселей у границ: {near.mean():.3f}", flush=True)
    l4 = _labels4(ids, near)
    print("Сглаженные метки готовы", flush=True)
    sdf = _dist(l4, near, MAXD)
    half = W // 2
    for nm, a in (("w", sdf[:, : half + PAD]), ("e", sdf[:, half - PAD:])):
        path = os.path.abspath(os.path.join(DATA, f"sdf_{nm}.png.bin"))
        Image.fromarray(a, "L").save(path, "PNG", optimize=True)
        print(f"sdf_{nm} {a.shape[1]}x{a.shape[0]}: {path} ({os.path.getsize(path) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
