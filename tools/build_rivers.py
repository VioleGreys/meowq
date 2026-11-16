#!/usr/bin/env python3
"""Поле рек для отрисовки: data/world1936/rivers.png.bin — RGBA8 в сетке карты
1× (5632×2625), по осевым линиям рек Natural Earth
(ne_10m_rivers_lake_centerlines, общественное достояние):
  r, g — вектор от центра пикселя до ближайшей точки реки, пикселей карты,
      −RMAX…RMAX → 0…255 (128 — ноль; дальше RMAX — (RMAX, RMAX));
  b — сила этой реки: 255 — крупная (scalerank ≤ 3), 170 — средняя (≤ 4),
      100 — малая (≤ 6), 0 — реки рядом нет.
Шейдер берёт вектор билинейно и рисует реку по его длине. Проекция точки на
прямую — аффинна, поэтому интерполяция векторов даёт точное расстояние до
участка реки даже между текселями (поле одних расстояний между текселями до
нуля не доходит — тонкая река шла пунктиром), а линия гладкая на любом
приближении (растр рек 1× в relief.png.bin, канал g, вблизи шёл лесенкой).

  python3 tools/build_rivers.py --ne папка_с_GeoJSON_Natural_Earth
"""
import argparse
import os
import sys

import numba
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")
RMAX = 4.0


@numba.njit(cache=True)
def _splat(segs, strength, W, H, rmax, dist, stg, vec):
    for i in range(segs.shape[0]):
        ax, ay, bx, by = segs[i, 0], segs[i, 1], segs[i, 2], segs[i, 3]
        s = strength[i]
        x0 = max(0, int(np.floor(min(ax, bx) - rmax)))
        x1 = min(W - 1, int(np.ceil(max(ax, bx) + rmax)))
        y0 = max(0, int(np.floor(min(ay, by) - rmax)))
        y1 = min(H - 1, int(np.ceil(max(ay, by) + rmax)))
        dx, dy = bx - ax, by - ay
        ll = dx * dx + dy * dy
        for y in range(y0, y1 + 1):
            py = y + 0.5
            for x in range(x0, x1 + 1):
                px = x + 0.5
                t = 0.0
                if ll > 0.0:
                    t = ((px - ax) * dx + (py - ay) * dy) / ll
                    t = min(1.0, max(0.0, t))
                qx = ax + dx * t - px
                qy = ay + dy * t - py
                d = np.sqrt(qx * qx + qy * qy)
                # ближе — эта река; на равных (слияние) — сильнейшая
                if d < dist[y, x] - 0.05 or (d < dist[y, x] + 0.05 and s > stg[y, x]):
                    dist[y, x] = d
                    stg[y, x] = s
                    vec[y, x, 0] = qx
                    vec[y, x, 1] = qy


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ne", required=True)
    args = ap.parse_args()
    W, H = bm.WIDTH, bm.HEIGHT
    segs = []
    strength = []
    for f in bm.load(os.path.join(args.ne, "ne_10m_rivers_lake_centerlines.geojson"))["features"]:
        sr = bm._rank(f["properties"].get("scalerank"))
        if sr > 6:
            continue
        s = 255 if sr <= 3 else (170 if sr <= 4 else 100)
        for line in bm.lines_of(f["geometry"]):
            arr = np.asarray(line, np.float64)
            if len(arr) < 2:
                continue
            x, y = bm.project(arr[:, 0], arr[:, 1])
            x = np.asarray(x)
            y = np.asarray(y)
            for k in range(len(x) - 1):
                if abs(x[k + 1] - x[k]) > W * 0.5:
                    continue   # переход через линию перемены дат
                segs.append((x[k], y[k], x[k + 1], y[k + 1]))
                strength.append(s)
    segs = np.array(segs, np.float64)
    strength = np.array(strength, np.int32)
    print(f"Отрезков рек: {len(segs)}", flush=True)
    dist = np.full((H, W), RMAX, np.float64)
    stg = np.zeros((H, W), np.int32)
    vec = np.full((H, W, 2), RMAX, np.float64)
    _splat(segs, strength, W, H, RMAX, dist, stg, vec)
    img = np.zeros((H, W, 4), np.uint8)
    img[..., :2] = np.clip(128.0 + vec / RMAX * 127.0 + 0.5, 0, 255).astype(np.uint8)
    img[..., 2] = np.where(dist < RMAX, stg, 0).astype(np.uint8)
    # a — само расстояние (0…RMAX): между двумя реками билинейный вектор
    # гасится (смотрят в разные стороны) и «находит» ложную реку — расстояние нет
    img[..., 3] = np.clip(dist / RMAX * 255.0 + 0.5, 0, 255).astype(np.uint8)
    path = os.path.abspath(os.path.join(DATA, "rivers.png.bin"))
    Image.fromarray(img, "RGBA").save(path, "PNG", optimize=True)
    print(f"rivers {W}x{H}: {path} ({os.path.getsize(path) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
