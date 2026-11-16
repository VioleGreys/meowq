#!/usr/bin/env python3
"""Поле рек для отрисовки: data/world1936/rivers.png.bin — RGBA8 в сетке карты
1× (5632×2625), по осевым линиям рек Natural Earth
(ne_10m_rivers_lake_centerlines, общественное достояние).

Расстояния — «приведённые»: пиксели карты, делённые на относительную ширину
реки (крупная 1, средняя 0,76, малая 0,57). Тогда лента «приведённое
расстояние < полуширина крупной» — точное объединение лент всех рек с их
шириной: на слиянии широкая река не обрывается зубцом («клювом») о узкую.
  r, g — приведённый вектор до ближайшей (в приведённой мере) точки реки,
      −RMAX…RMAX → 0…255 (128 — ноль; дальше RMAX — (RMAX, RMAX));
  b — расстояние для крупного плана: гладкий минимум (SMIN_K) с ближайшей
      рекой «с другой стороны» — другой линией в направлении больше ~100° от
      первой (плавный штраф ближе к ней): второе русло, другой берег узкой
      полоски суши, угол слияния. Узкая полоска суши между руслами и острый
      клин у развилки заливаются водой;
  a — приведённое расстояние до ближайшей реки (0…RMAX).
Линии сглажены по длине (σ 0,8 пикс.: изломы мельче пикселя давали зубцы),
концы, не дошедшие до русла (≤ 1,5 пикс.), дотянуты до него.
Сила реки (255 — крупная, scalerank ≤ 3; 170 — средняя, ≤ 4; 100 — малая,
≤ 6; 0 — рядом нет) пишется в канал g relief.png.bin (там был старый растр
рек 1×) — поэтому запускать после tools/build_map.py.
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
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")
RMAX = 4.0


WIDTH_OF = {255: 1.0, 170: 0.32 / 0.42, 100: 0.24 / 0.42}   # как прежние base в шейдере


@numba.njit(cache=True)
def _splat(segs, strength, wk, lid, W, H, rmax, dist, stg, vec, own, second, dist2):
    """second=False: ближайшая река (dist, stg, vec); second=True: ближайшая
    среди точек, направление на которые расходится с vec больше чем на 90°
    (dist2). Расстояния приведённые (делённые на ширину wk)."""
    for i in range(segs.shape[0]):
        ax, ay, bx, by = segs[i, 0], segs[i, 1], segs[i, 2], segs[i, 3]
        s = strength[i]
        k = wk[i]
        r = rmax * k
        x0 = max(0, int(np.floor(min(ax, bx) - r)))
        x1 = min(W - 1, int(np.ceil(max(ax, bx) + r)))
        y0 = max(0, int(np.floor(min(ay, by) - r)))
        y1 = min(H - 1, int(np.ceil(max(ay, by) + r)))
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
                d = np.sqrt(qx * qx + qy * qy) / k
                if second:
                    if lid[i] == own[y, x]:
                        continue   # та же линия — не «другое русло»
                    # «с другой стороны»: штраф плавно растёт, когда направление
                    # сходится с первым (cos > −0,3), — без скачков между текселями
                    vx, vy = vec[y, x, 0], vec[y, x, 1]
                    nn = np.sqrt((qx * qx + qy * qy) * (vx * vx + vy * vy))
                    c = 1.0 if nn < 1e-9 else (qx * vx + qy * vy) / nn
                    t = min(1.0, max(0.0, (c + 0.3) / 0.6))
                    d += rmax * t * t * (3.0 - 2.0 * t)
                    if d < dist2[y, x]:
                        dist2[y, x] = d
                    continue
                # ближе — эта река; на равных (слияние) — сильнейшая
                if d < dist[y, x] - 0.05 or (d < dist[y, x] + 0.05 and s > stg[y, x]):
                    dist[y, x] = d
                    stg[y, x] = s
                    vec[y, x, 0] = qx / k
                    vec[y, x, 1] = qy / k
                    own[y, x] = lid[i]


SMOOTH_STEP = 0.25   # шаг передискретизации линии, пикс. карты
SMOOTH_SIGMA = 0.8   # сглаживание по длине линии, пикс. карты


def smooth_line(x, y):
    """Изломы и петельки исходных линий мельче пикселя карты вблизи (пиксель
    карты — 10–25 пикс. экрана) дают зубцы и клинья ленты: передискретизация
    по длине и гауссово сглаживание. Концы на месте (слияния не рвутся):
    сдвиг у концов плавно гасится на длине 2σ."""
    seg = np.hypot(np.diff(x), np.diff(y))
    s = np.concatenate([[0.0], np.cumsum(seg)])
    L = s[-1]
    if L < 4 * SMOOTH_STEP:
        return x, y
    n = int(np.ceil(L / SMOOTH_STEP)) + 1
    t = np.linspace(0.0, L, n)
    rx = np.interp(t, s, x)
    ry = np.interp(t, s, y)
    r = int(np.ceil(3 * SMOOTH_SIGMA / SMOOTH_STEP))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) * SMOOTH_STEP / SMOOTH_SIGMA) ** 2)
    ones = ndimage.convolve1d(np.ones(n), k, mode="constant")
    sx = ndimage.convolve1d(rx, k, mode="constant") / ones
    sy = ndimage.convolve1d(ry, k, mode="constant") / ones
    w = np.clip(np.minimum(t, L - t) / (2 * SMOOTH_SIGMA), 0.0, 1.0)
    w = w * w * (3 - 2 * w)
    return rx + (sx - rx) * w, ry + (sy - ry) * w


HW_NEAR = 1.22   # полуширина крупной реки у максимального приближения, пикс. карты
SMIN_K = 3.0 * HW_NEAR   # гладкий минимум: суша уже ~3/4 ширины ленты заливается
SNAP_END = 1.5   # конец линии ближе стольких пикс. карты к другой — дотянуть


def snap_ends(lines):
    """В данных притоки и рукава местами обрываются, не дойдя до реки, в
    которую впадают (Недеррейн у Рейна): между концом и руслом остаётся клин
    суши с берегом. Конец, лежащий ближе SNAP_END к другой линии, дотягиваем
    до ближайшей точки на ней."""
    segs = []
    owner = []
    for n, (x, y, _) in enumerate(lines):
        for k in range(len(x) - 1):
            segs.append((x[k], y[k], x[k + 1], y[k + 1]))
            owner.append(n)
    segs = np.array(segs)
    owner = np.array(owner)
    ax, ay, bx, by = segs.T
    dx, dy = bx - ax, by - ay
    ll = np.maximum(dx * dx + dy * dy, 1e-12)
    snapped = 0
    for n, ln in enumerate(lines):
        x, y = ln[0], ln[1]
        for end in (0, -1):
            px, py = x[end], y[end]
            near = (np.minimum(ax, bx) < px + SNAP_END) & (np.maximum(ax, bx) > px - SNAP_END) \
                & (np.minimum(ay, by) < py + SNAP_END) & (np.maximum(ay, by) > py - SNAP_END) & (owner != n)
            if not near.any():
                continue
            idx = np.nonzero(near)[0]
            t = np.clip(((px - ax[idx]) * dx[idx] + (py - ay[idx]) * dy[idx]) / ll[idx], 0, 1)
            qx = ax[idx] + dx[idx] * t
            qy = ay[idx] + dy[idx] * t
            d = np.hypot(qx - px, qy - py)
            j = int(d.argmin())
            if d[j] < 0.02 or d[j] > SNAP_END:
                continue
            if end == 0:
                ln[0] = np.concatenate([[qx[j]], x])
                ln[1] = np.concatenate([[qy[j]], y])
            else:
                ln[0] = np.concatenate([x, [qx[j]]])
                ln[1] = np.concatenate([y, [qy[j]]])
            x, y = ln[0], ln[1]
            snapped += 1
    print(f"Концов рек дотянуто до русла: {snapped}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ne", required=True)
    args = ap.parse_args()
    W, H = bm.WIDTH, bm.HEIGHT
    lines = []
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
            lines.append([np.asarray(x, np.float64), np.asarray(y, np.float64), s])
    snap_ends(lines)
    segs = []
    strength = []
    lid = []
    for nline, (x, y, s) in enumerate(lines):
        if np.abs(np.diff(x)).max() < W * 0.5:
            x, y = smooth_line(x, y)
        for k in range(len(x) - 1):
            if abs(x[k + 1] - x[k]) > W * 0.5:
                continue   # переход через линию перемены дат
            segs.append((x[k], y[k], x[k + 1], y[k + 1]))
            strength.append(s)
            lid.append(nline)
    segs = np.array(segs, np.float64)
    strength = np.array(strength, np.int32)
    lid = np.array(lid, np.int32)
    own = np.full((H, W), -1, np.int32)
    wk = np.array([WIDTH_OF[int(v)] for v in strength], np.float64)
    print(f"Отрезков рек: {len(segs)}", flush=True)
    dist = np.full((H, W), RMAX, np.float64)
    dist2 = np.full((H, W), RMAX, np.float64)
    stg = np.zeros((H, W), np.int32)
    vec = np.full((H, W, 2), RMAX, np.float64)
    _splat(segs, strength, wk, lid, W, H, RMAX, dist, stg, vec, own, False, dist2)
    _splat(segs, strength, wk, lid, W, H, RMAX, dist, stg, vec, own, True, dist2)
    img = np.zeros((H, W, 4), np.uint8)
    img[..., :2] = np.clip(128.0 + vec / RMAX * 127.0 + 0.5, 0, 255).astype(np.uint8)
    # b — гладкое слияние с «другим руслом» для крупного плана (полуширина
    # крупной реки там ≈ HW_NEAR): гладкий минимум, перемычка с шириной SMIN_K
    h = np.maximum(SMIN_K - np.abs(dist - dist2), 0.0) / SMIN_K
    sm = np.minimum(dist, dist2) - h * h * SMIN_K * 0.25
    img[..., 2] = np.clip(sm / RMAX * 255.0 + 0.5, 0, 255).astype(np.uint8)
    # a — само расстояние: между двумя реками билинейный вектор гасится
    # (смотрят в разные стороны) и «находит» ложную реку — расстояние нет
    img[..., 3] = np.clip(dist / RMAX * 255.0 + 0.5, 0, 255).astype(np.uint8)
    path = os.path.abspath(os.path.join(DATA, "rivers.png.bin"))
    Image.fromarray(img, "RGBA").save(path, "PNG", optimize=True)
    print(f"rivers {W}x{H}: {path} ({os.path.getsize(path) // 1024} КБ)")
    rpath = os.path.abspath(os.path.join(DATA, "relief.png.bin"))
    im = Image.open(rpath)
    mode = "RGBA" if im.mode == "RGBA" else "RGB"   # a — сухость (build_map --kg), сохраняем
    rel = np.asarray(im.convert(mode)).copy()
    rel[..., 1] = np.where(dist < RMAX, stg, 0).astype(np.uint8)
    Image.fromarray(rel, mode).save(rpath, "PNG", optimize=True)
    print(f"сила рек — в канал g {rpath}")


if __name__ == "__main__":
    sys.exit(main())
