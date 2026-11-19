#!/usr/bin/env python3
"""Дороги и железные дороги для отрисовки карты вблизи: data/world1936/roads.json.

Как в жанре — от провинции к провинции: линия идёт из центра провинции к точке W
на общей границе с соседом и дальше в центр соседа. Каждая провинция хранит
только свои «половины» (центр → K → W): шейдер считает расстояние до половин
своей провинции и соседней по окну сглаживания (палитра, разделы 4…21), текстуры
не нужны. В точке W обе половины идут по одной прямой (направление центр → центр):
линия через границу без излома; K — на этой прямой внутри провинции.

Проверка половины по карте провинций 2× (ids2): все точки линии — в своей
провинции (у W — и в соседней), до третьих провинций не ближе CLEAR пикс.,
не по воде (доля суши, relief.png.bin b). Не прошла ни одна точка W — ребра нет.

Сеть:
  дороги — жадный остов (spanner) по рёбрам соседства: ребро берётся, если путь
      по уже взятым длиннее ROAD_T × его длины; в глуши (застройка cover.b мала
      у обеих провинций) — нет;
  железные дороги — между городами (очки победы ≥ RAIL_VP): пары по расстоянию,
      путь — кратчайший по провинциям с ценой местности (горы, болота, пустыни
      дороже); путь берётся, если по уже проложенным путям дороже RAIL_T × его
      цены; не дороже RAIL_MAX (через Сахару и тайгу без городов — нет).

  godot --headless --path . --script res://tools/dump_supply.gd -- --out=supply.json
  python3 tools/build_roads.py [--ne-rail ne_10m_railroads] [--supply supply.json] [--preview out.png] [--cache файл]

С --ne-rail жд-рёбра — только вдоль реальных линий Natural Earth (общественное
достояние; сеть современная, но так видно, где пути шли и где их не было).
"""
import argparse
import heapq
import json
import math
import os

import sys

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra

sys.path.insert(0, os.path.dirname(__file__))
DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")

Q = 8.0            # координаты в данных — кратны 1/8 пикс. карты (16 бит)
CLEAR = 0.45       # до третьих провинций, пикс. карты 1×
MAX_H = 8          # половин на провинцию (больше — дороги отбрасываются)
ROAD_T = 1.7
ROAD_DEV = 0.004   # застройка округи (cover.b, размытая σ DEV_SIGMA) — ниже глушь
DEV_SIGMA = 10.0
RAIL_VP = 4
RAIL_T = 1.6       # в обжитых краях; в глуши — до RAIL_T + RAIL_T_WILD
RAIL_T_WILD = 1.6
RAIL_DEV = 0.03    # застройка округи, с которой сеть жд густая
RAIL_R = 160.0     # пары городов не дальше, пикс.
RAIL_MAX = 230.0   # цена пути не больше
SUP_R = 280.0      # пары пунктов снабжения — не дальше, пикс.
SUP_MAX = 420.0    # и цена пути не больше
SUP_NEAR = 12.0    # реальная линия у пункта ближе — подключить и без цепочки вдоль неё
# переходы железных дорог через границу — только исторические (решение пользователя:
# «между странами жд пути, только если так было исторически»), около 1936 г.:
# страны (теги 1936 г.) и точка перехода (долгота, широта); без перехода в списке
# поезда через границу не идут
CROSS = [
    ("GER", "FRA", 6.90, 49.19), ("GER", "FRA", 7.78, 48.57), ("GER", "FRA", 7.55, 47.81),
    ("GER", "BEL", 6.10, 50.67), ("GER", "HOL", 6.20, 51.85), ("GER", "HOL", 7.00, 52.32),
    ("GER", "HOL", 6.20, 51.35), ("GER", "LUX", 6.50, 49.71), ("GER", "DEN", 9.37, 54.83),
    ("GER", "POL", 15.75, 52.23), ("GER", "POL", 17.40, 53.75), ("GER", "POL", 18.95, 50.33),
    ("GER", "DNZ", 19.00, 54.10), ("DNZ", "POL", 18.70, 54.15), ("DNZ", "POL", 18.55, 54.45),
    ("GER", "LIT", 22.80, 54.63), ("GER", "LIT", 21.90, 55.08),
    ("GER", "CZE", 14.20, 50.88), ("GER", "CZE", 12.23, 50.07), ("GER", "CZE", 12.85, 49.30),
    ("GER", "CZE", 18.30, 49.95),
    ("GER", "AUS", 12.98, 47.82), ("GER", "AUS", 13.45, 48.55), ("GER", "AUS", 12.17, 47.60),
    ("GER", "SWI", 7.62, 47.57), ("GER", "SWI", 8.70, 47.75),
    ("FRA", "BEL", 3.93, 50.33), ("FRA", "BEL", 3.25, 50.60), ("FRA", "BEL", 5.80, 49.55),
    ("FRA", "LUX", 6.10, 49.47), ("FRA", "SWI", 5.98, 46.18), ("FRA", "SWI", 6.37, 46.71),
    ("FRA", "SWI", 7.00, 47.50), ("FRA", "SWI", 7.56, 47.59),
    ("FRA", "ITA", 6.70, 45.13), ("FRA", "ITA", 7.53, 43.78),
    ("FRA", "SPR", -1.78, 43.35), ("FRA", "SPR", 3.15, 42.43), ("FRA", "SPR", -0.52, 42.75),
    ("FRA", "SPR", -5.95, 34.98),
    ("BEL", "HOL", 4.45, 51.47), ("BEL", "HOL", 5.68, 50.75), ("BEL", "LUX", 5.88, 49.65),
    ("BEL", "LUX", 6.00, 50.18),
    ("SWI", "ITA", 8.20, 46.20), ("SWI", "ITA", 9.03, 45.83), ("SWI", "AUS", 9.53, 47.17),
    ("SWI", "AUS", 9.64, 47.45),
    ("AUS", "ITA", 11.50, 47.00), ("AUS", "ITA", 13.60, 46.50),
    ("AUS", "CZE", 16.90, 48.63), ("AUS", "CZE", 14.45, 48.60), ("AUS", "CZE", 15.00, 48.77),
    ("AUS", "HUN", 17.15, 47.90), ("AUS", "HUN", 16.60, 47.68), ("AUS", "YUG", 15.63, 46.70),
    ("ITA", "YUG", 14.30, 45.82), ("ITA", "YUG", 14.45, 45.33),
    ("CZE", "POL", 18.60, 49.88), ("CZE", "POL", 18.97, 49.50),
    ("CZE", "HUN", 18.10, 47.75), ("CZE", "HUN", 21.23, 48.50), ("CZE", "HUN", 17.20, 48.00),
    ("CZE", "HUN", 22.20, 48.43),
    ("HUN", "YUG", 19.60, 46.20), ("HUN", "YUG", 17.00, 46.25),
    ("HUN", "ROM", 21.75, 47.13), ("HUN", "ROM", 21.25, 46.40),
    ("YUG", "ROM", 21.40, 45.25), ("YUG", "ROM", 20.75, 45.80),
    ("YUG", "BUL", 22.78, 43.00), ("YUG", "GRE", 22.52, 41.13),
    ("BUL", "TUR", 26.30, 41.75), ("GRE", "TUR", 26.60, 41.37), ("BUL", "GRE", 26.45, 41.60),
    ("POL", "LAT", 26.20, 55.70), ("POL", "SOV", 26.95, 53.60), ("POL", "SOV", 26.90, 50.25),
    ("POL", "ROM", 25.60, 48.50),
    ("LIT", "LAT", 23.80, 56.35), ("LAT", "EST", 26.05, 57.78), ("EST", "SOV", 28.20, 59.37),
    ("EST", "SOV", 27.90, 57.75), ("LAT", "SOV", 28.20, 56.40),
    ("FIN", "SOV", 29.90, 60.15), ("FIN", "SWE", 24.15, 65.83),
    ("SWE", "NOR", 12.30, 59.88), ("SWE", "NOR", 18.12, 68.42), ("SWE", "NOR", 12.10, 63.32),
    ("SWE", "NOR", 11.50, 58.95),
    ("SOV", "TUR", 43.50, 40.90), ("SOV", "PER", 45.60, 38.95),
    ("SOV", "MAN", 117.50, 49.60), ("SOV", "MAN", 131.15, 44.40),
    ("MAN", "CHN", 119.75, 40.00), ("MAN", "JAP", 124.40, 40.10), ("MAN", "JAP", 129.85, 42.97),
    ("CHN", "FRA", 103.95, 22.50), ("CHN", "ENG", 114.10, 22.53),
    ("TUR", "FRA", 36.80, 36.83), ("TUR", "FRA", 41.20, 37.05),
    ("FRA", "ENG", 35.67, 32.70), ("FRA", "ENG", 36.20, 32.55), ("EGY", "ENG", 34.25, 31.28),
    ("RAJ", "PER", 61.40, 29.00), ("RAJ", "NEP", 84.86, 27.00),
    ("SIA", "ENG", 100.30, 6.67), ("SIA", "ENG", 101.98, 6.03),
    ("SAF", "ENG", 25.60, -25.85), ("SAF", "ENG", 30.00, -22.22), ("SAF", "POR", 31.98, -25.43),
    ("ENG", "POR", 32.70, -18.97), ("ENG", "BEL", 28.55, -12.75), ("BEL", "POR", 22.33, -10.70),
    ("FRA", "ETH", 42.55, 11.30),
    ("USA", "CAN", -83.05, 42.32), ("USA", "CAN", -79.05, 43.10), ("USA", "CAN", -73.37, 45.00),
    ("USA", "CAN", -122.75, 49.00), ("USA", "CAN", -84.35, 46.50), ("USA", "CAN", -82.42, 42.97),
    ("USA", "CAN", -97.20, 49.00), ("USA", "CAN", -102.55, 49.00), ("USA", "CAN", -67.43, 45.57),
    ("USA", "CAN", -111.95, 49.00),
    ("USA", "MEX", -106.45, 31.75), ("USA", "MEX", -99.50, 27.50), ("USA", "MEX", -110.94, 31.33),
    ("USA", "MEX", -100.50, 28.70), ("USA", "MEX", -97.50, 25.90), ("USA", "MEX", -115.50, 32.67),
    ("MEX", "GUA", -92.20, 14.68),
    ("ARG", "CHL", -70.05, -32.83), ("ARG", "BOL", -65.60, -22.10), ("BOL", "CHL", -69.45, -17.60),
    ("BOL", "CHL", -68.25, -21.23), ("BRA", "URU", -55.55, -30.90),
    ("SPR", "POR", -7.03, 38.88), ("SPR", "POR", -8.64, 42.03), ("SPR", "POR", -6.82, 40.60),
    ("SPR", "POR", -6.93, 41.03),
]
# развитость дорог и жд страны около 1936 г. (решение пользователя: где снабжение было
# плохим или страна бедная — дорог и жд меньше); 1 — густая сеть Западной Европы и США.
# Колонии — COLONY_K (у Японии — Корея, Тайвань: сеть строилась — выше)
DEV_K = {
    "GER": 1.0, "ENG": 1.0, "FRA": 1.0, "BEL": 1.0, "HOL": 1.0, "LUX": 1.0, "SWI": 1.0,
    "DEN": 1.0, "USA": 1.0, "CZE": 0.95, "AUS": 0.95, "SWE": 0.9, "DNZ": 0.9,
    "ITA": 0.85, "NOR": 0.8, "CAN": 0.8, "AST": 0.75, "NZL": 0.75, "JAP": 0.85, "FIN": 0.75,
    "HUN": 0.8, "IRE": 0.7, "ARG": 0.7, "SAF": 0.65, "URU": 0.6, "EST": 0.6, "LAT": 0.6,
    "LIT": 0.55, "POL": 0.6, "SPR": 0.6, "CHL": 0.55, "MAN": 0.6, "SOV": 0.5, "POR": 0.5,
    "ROM": 0.5, "CUB": 0.5, "YUG": 0.45, "BUL": 0.45, "GRE": 0.45, "RAJ": 0.45, "MEX": 0.45,
    "EGY": 0.45, "BRA": 0.4, "ICE": 0.3, "TUR": 0.35, "CHN": 0.3, "SIA": 0.35, "PHI": 0.35,
    "COL": 0.3, "VEN": 0.3, "PRU": 0.3, "ECU": 0.25, "BOL": 0.25, "PAR": 0.25, "COS": 0.3,
    "PAN": 0.3, "GUA": 0.25, "ELS": 0.25, "HON": 0.2, "NIC": 0.2, "DOM": 0.25, "HAI": 0.15,
    "PER": 0.25, "IRQ": 0.25, "ALB": 0.15, "LIB": 0.15, "ETH": 0.08, "AFG": 0.06,
    "SAU": 0.06, "YEM": 0.05, "OMA": 0.05, "MON": 0.06, "TIB": 0.03, "NEP": 0.1, "BHU": 0.03,
    "TAN": 0.03, "PRC": 0.1,
}
DEV_DEFAULT = 0.3
COLONY_K = {"JAP": 0.6}
COLONY_DEFAULT = 0.25
ROAD_T_POOR = 1.4      # прибавка к ROAD_T у самой бедной страны
RAIL_T_POOR = 2.0      # прибавка к t жд-остовов у самой бедной страны

# одна страна для железных дорог: Китай 1936 г. раздроблен (дороги строились до раскола)
GROUP = {"GXC": "CHN", "YUN": "CHN", "SHX": "CHN", "XSM": "CHN", "SIK": "CHN", "CHI": "CHN",
         "NSP": "SPR"}

NE_NEAR = 4.0      # жд-ребро — вдоль реальной линии: точек ближе NE_NEAR пикс.
NE_FRAC = 0.6      # не меньше этой доли
NE_FRAC_MNT = 0.8  # ребро с горной провинцией — строже (допуск NE_NEAR без прибавки)
RAIL_T_SPAN = 2.6
RAIL_DEV_WILD = 0.01   # застройка округи ниже — все рёбра вдоль реальных линий

# цена местности для железной дороги (World.T_*: равнина, лес, холмы, горы, город, —, пустыня, болото)
T_COST = [1.0, 1.35, 1.7, 3.2, 1.0, 9.0, 2.6, 2.4]


def load_ids2():
    w = np.asarray(Image.open(os.path.join(DATA, "ids2_w.png.bin")).convert("RGB")).astype(np.int32)
    e = np.asarray(Image.open(os.path.join(DATA, "ids2_e.png.bin")).convert("RGB")).astype(np.int32)
    w = w[..., 0] + w[..., 1] * 256
    e = e[..., 0] + e[..., 1] * 256
    pad = (w.shape[1] + e.shape[1] - 11264) // 2
    return np.concatenate([w[:, : w.shape[1] - pad], e[:, pad:]], 1)


def border_points(ids, land):
    """Точки общих границ пар провинций суши (пикс. 1×): {(a, b): array N×2}, a < b."""
    pts = {}
    for axis in (0, 1):
        if axis == 1:
            a, b = ids[:, :-1], ids[:, 1:]
        else:
            a, b = ids[:-1, :], ids[1:, :]
        m = (a != b) & land[a] & land[b]
        yy, xx = np.nonzero(m)
        pa, pb = a[m], b[m]
        if axis == 1:
            x, y = (xx + 1) / 2.0, (yy + 0.5) / 2.0
        else:
            x, y = (xx + 0.5) / 2.0, (yy + 1) / 2.0
        lo, hi = np.minimum(pa, pb), np.maximum(pa, pb)
        key = lo.astype(np.int64) * 100000 + hi
        order = np.argsort(key, kind="stable")
        key, x, y = key[order], x[order], y[order]
        starts = np.flatnonzero(np.r_[True, key[1:] != key[:-1]])
        ends = np.r_[starts[1:], len(key)]
        for s, t in zip(starts, ends):
            k = (int(key[s] // 100000), int(key[s] % 100000))
            p = np.stack([x[s:t], y[s:t]], 1)
            pts[k] = p if k not in pts else np.concatenate([pts[k], p])
    return pts


def centers(ids, provs, land):
    """Центр провинции (пикс. 1×): её точка (x, y), если она внутри и не у края;
    иначе — самая «глубокая» точка поблизости (по расстоянию до края)."""
    out = {}
    H2, W2 = ids.shape
    for i, p in enumerate(provs):
        if not land[i]:
            continue
        x0, y0, x1, y1 = p["bb"]
        X0, Y0 = max(0, x0 * 2 - 2), max(0, y0 * 2 - 2)
        X1, Y1 = min(W2, x1 * 2 + 4), min(H2, y1 * 2 + 4)
        m = ids[Y0:Y1, X0:X1] == i
        if not m.any():
            continue
        d = ndimage.distance_transform_edt(np.pad(m, 1))[1:-1, 1:-1] / 2.0   # пикс. 1×
        cx, cy = p["x"], p["y"]
        gi, gj = int(cy * 2) - Y0, int(cx * 2) - X0
        if 0 <= gi < m.shape[0] and 0 <= gj < m.shape[1] and d[gi, gj] >= 1.5:
            c = (cx, cy)
        else:
            yy, xx = np.mgrid[0:m.shape[0], 0:m.shape[1]]
            dist = np.hypot((xx + X0 + 0.5) / 2.0 - cx, (yy + Y0 + 0.5) / 2.0 - cy)
            sc = np.minimum(d, 2.5) - 0.04 * dist
            sc[~m] = -1e9
            k = np.unravel_index(np.argmax(sc), sc.shape)
            c = ((k[1] + X0 + 0.5) / 2.0, (k[0] + Y0 + 0.5) / 2.0)
        out[i] = (round(c[0] * Q) / Q, round(c[1] * Q) / Q)
    return out


class Checker:
    def __init__(self, ids, landf):
        self.ids = ids
        self.landf = landf
        self.H2, self.W2 = ids.shape
        r = int(math.ceil(CLEAR * 2))
        self.off = [(dy, dx) for dy in range(-r, r + 1) for dx in range(-r, r + 1) if dx * dx + dy * dy <= (CLEAR * 2) ** 2 + 0.5]

    def ok(self, poly, a, b, w):
        """Линия poly (точки 1×) лежит в провинции a (у w — ещё в b), без воды и
        без третьих провинций ближе CLEAR."""
        return self.ok_ends(poly, a, {b}, [w])

    def ok_ends(self, poly, a, allow, ends):
        """То же для линии с концами ends на границах с провинциями allow."""
        for p0, p1 in zip(poly[:-1], poly[1:]):
            L = math.dist(p0, p1)
            n = max(2, int(L / 0.15) + 1)
            for t in np.linspace(0.0, 1.0, n):
                x = p0[0] + (p1[0] - p0[0]) * t
                y = p0[1] + (p1[1] - p0[1]) * t
                gx, gy = int(x * 2), int(y * 2)
                if not (0 <= gx < self.W2 and 0 <= gy < self.H2):
                    return False
                near_w = min(math.dist((x, y), w) for w in ends) < 0.6
                c = self.ids[gy, gx]
                if c != a and not (near_w and c in allow):
                    return False
                if self.landf[min(int(y), self.landf.shape[0] - 1), min(int(x), self.landf.shape[1] - 1)] < 0.5:
                    return False
                for dy, dx in self.off:
                    yy, xx = gy + dy, gx + dx
                    if 0 <= yy < self.H2 and 0 <= xx < self.W2:
                        q = self.ids[yy, xx]
                        if q != a and q not in allow:
                            return False
        return True


def thr_ctrl(w0, k0, k1, w1):
    """Опоры кривой насквозь (как в шейдере road_prov): не длиннее 0,4 расстояния
    W0–W1; None — выходы почти в одну сторону (была бы петля)."""
    L = math.dist(w0, w1)
    d0 = (k0[0] - w0[0], k0[1] - w0[1])
    d1 = (k1[0] - w1[0], k1[1] - w1[1])
    l0, l1 = math.hypot(*d0), math.hypot(*d1)
    if l0 < 1e-3 or l1 < 1e-3 or (d0[0] * d1[0] + d1[1] * d0[1]) / (l0 * l1) > -0.2:
        return None
    s0, s1 = min(1.0, 0.4 * L / l0), min(1.0, 0.4 * L / l1)
    return (w0[0] + d0[0] * s0, w0[1] + d0[1] * s0), (w1[0] + d1[0] * s1, w1[1] + d1[1] * s1)


def bezier(w0, k0, k1, w1, n=24):
    """Кубическая кривая W0 → W1 (опоры K0, K1)."""
    out = []
    for t in np.linspace(0.0, 1.0, n + 1):
        u = 1.0 - t
        out.append((u * u * u * w0[0] + 3 * u * u * t * k0[0] + 3 * u * t * t * k1[0] + t * t * t * w1[0],
                    u * u * u * w0[1] + 3 * u * u * t * k0[1] + 3 * u * t * t * k1[1] + t * t * t * w1[1]))
    return out


def half(c, w, u, k_frac):
    """Половина центр c → K → W: K на прямой через W по направлению u (центр → центр)."""
    L = math.dist(c, w)
    kk = (w[0] - u[0] * L * k_frac, w[1] - u[1] * L * k_frac)
    return [c, (round(kk[0] * Q) / Q, round(kk[1] * Q) / Q), w]


def edge_geom(a, b, ca, cb, pts, chk):
    """Точка W на границе a–b и половины обеих провинций; None — не провести."""
    dx, dy = cb[0] - ca[0], cb[1] - ca[1]
    L = math.hypot(dx, dy)
    if L < 1e-3 or L > 400:
        return None
    u = (dx / L, dy / L)
    # кандидаты: ближе к прямой центр — центр и между центрами
    rel = pts - np.array(ca)
    along = rel @ np.array(u)
    perp = np.abs(rel @ np.array([-u[1], u[0]]))
    sc = perp + np.maximum(0.0, -along) * 2 + np.maximum(0.0, along - L) * 2
    order = np.argsort(sc)
    tried = 0
    seen = set()
    for k in order:
        if tried >= 24:
            break
        w = (round(pts[k, 0] * Q) / Q, round(pts[k, 1] * Q) / Q)
        key = (round(w[0] * 2), round(w[1] * 2))
        if key in seen:
            continue
        seen.add(key)
        tried += 1
        # направление у W — между «центр → центр» и «центр a → W → центр b»
        va = (w[0] - ca[0], w[1] - ca[1])
        vb = (cb[0] - w[0], cb[1] - w[1])
        la, lb = math.hypot(*va), math.hypot(*vb)
        if la < 0.8 or lb < 0.8:
            continue
        v = (va[0] / la + vb[0] / lb, va[1] / la + vb[1] / lb)
        lv = math.hypot(*v)
        if lv < 0.5:
            continue
        uw = (v[0] / lv, v[1] / lv)
        for kf in (0.4, 0.25, 0.55):
            ha = half(ca, w, uw, kf)
            hb = half(cb, w, (-uw[0], -uw[1]), kf)
            if _bend(ha) and _bend(hb) and chk.ok(ha, a, b, w) and chk.ok(hb, b, a, w):
                return ha, hb, la + lb
    return None


def _bend(h):
    """Излом в K не круче ~55°."""
    c, k, w = h
    v1 = (k[0] - c[0], k[1] - c[1])
    v2 = (w[0] - k[0], w[1] - k[1])
    l1, l2 = math.hypot(*v1), math.hypot(*v2)
    if l1 < 1e-3 or l2 < 1e-3:
        return True
    return (v1[0] * v2[0] + v1[1] * v2[1]) / (l1 * l2) > 0.57


def spanner(n, edges, t, length, adj=None):
    """Жадный остов: рёбра (a, b) по возрастанию длины; берём, если путь по взятым > t·длины
    (t — число или словарь по рёбрам; adj — уже проложенные: дополняются)."""
    if adj is None:
        adj = [[] for _ in range(n)]
    out = []
    for e in sorted(edges, key=lambda e: length[e]):
        a, b = e
        lim = (t[e] if isinstance(t, dict) else t) * length[e]
        if _dist(adj, a, b, lim) > lim:
            adj[a].append((b, length[e]))
            adj[b].append((a, length[e]))
            out.append(e)
    return out


def _dist(adj, s, g, lim):
    d = {s: 0.0}
    h = [(0.0, s)]
    while h:
        du, u = heapq.heappop(h)
        if u == g:
            return du
        if du > d.get(u, 1e18) or du > lim:
            continue
        for v, w in adj[u]:
            nd = du + w
            if nd < d.get(v, 1e18) and nd <= lim:
                d[v] = nd
                heapq.heappush(h, (nd, v))
    return 1e18


def build_geom(ids, provs, land, landf, W1):
    print("границы...", flush=True)
    pts = border_points(ids, land)
    print("центры...", flush=True)
    cen = centers(ids, provs, land)
    chk = Checker(ids, landf)
    print("рёбра...", flush=True)
    geom = {}
    fail = 0
    for (a, b), p in pts.items():
        if a not in cen or b not in cen or len(p) < 2:
            continue
        if abs(cen[a][0] - cen[b][0]) > W1 / 2:
            continue
        g = edge_geom(a, b, cen[a], cen[b], p, chk)
        if g is None:
            fail += 1
            continue
        geom[(a, b)] = g
    print(f"рёбер {len(geom)}, не провести {fail}")
    return cen, geom


def ne_rail_dist(path, w, h):
    """Расстояние (пикс. карты) до железных дорог Natural Earth 10m (ne_10m_railroads,
    общественное достояние; сеть современная — для 1936 г. как подсказка, где линии
    шли: Транссиб, колониальные линии от портов вглубь). Shapefile читается сам
    (тип 3 — ломаные)."""
    import struct
    import build_map as bm
    from PIL import ImageDraw
    b = open(path + ".shp", "rb").read()
    img = Image.new("L", (w, h), 0)
    dr = ImageDraw.Draw(img)
    o = 100
    while o < len(b):
        clen = struct.unpack(">i", b[o + 4:o + 8])[0] * 2
        rec = b[o + 8:o + 8 + clen]
        o += 8 + clen
        if struct.unpack("<i", rec[:4])[0] != 3:
            continue
        nparts, npts = struct.unpack("<ii", rec[36:44])
        parts = list(struct.unpack("<%di" % nparts, rec[44:44 + 4 * nparts])) + [npts]
        xy = np.frombuffer(rec[44 + 4 * nparts:44 + 4 * nparts + 16 * npts], "<f8").reshape(-1, 2)
        x, y = bm.project(xy[:, 0], xy[:, 1])
        for k in range(nparts):
            seg = list(zip(np.asarray(x)[parts[k]:parts[k + 1]], np.asarray(y)[parts[k]:parts[k + 1]]))
            if len(seg) >= 2 and max(abs(seg[i][0] - seg[i + 1][0]) for i in range(len(seg) - 1)) < w / 2:
                dr.line(seg, fill=255, width=1)
    m = np.asarray(img) > 0
    return ndimage.distance_transform_edt(~m)


def on_rail(geom_e, dist, near):
    """Доля точек ребра (обе половины) не дальше near от реальной линии."""
    ha, hb, _ = geom_e
    tot = hit = 0
    for h in (ha, hb):
        for p0, p1 in zip(h[:-1], h[1:]):
            n = max(2, int(math.dist(p0, p1) / 0.5) + 1)
            for t in np.linspace(0.0, 1.0, n):
                x = p0[0] + (p1[0] - p0[0]) * t
                y = p0[1] + (p1[1] - p0[1]) * t
                tot += 1
                hit += dist[min(int(y), dist.shape[0] - 1), min(int(x), dist.shape[1] - 1)] <= near
    return hit / max(tot, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview")
    ap.add_argument("--ne-rail", help="ne_10m_railroads (путь без .shp): жд только вдоль реальных линий")
    ap.add_argument("--supply", help="JSON пунктов снабжения (tools/dump_supply.gd): жд к ним — первыми")
    ap.add_argument("--cache", help="файл: геометрия рёбер (для подбора сети без пересчёта)")
    args = ap.parse_args()
    meta = json.load(open(os.path.join(DATA, "map.json"), encoding="utf-8"))
    provs = meta["provinces"]
    n = len(provs)
    W1 = meta["width"]
    land = np.array([bool(p["land"]) for p in provs] + [False] * (65536 - n))
    ids = load_ids2()
    rel = np.asarray(Image.open(os.path.join(DATA, "relief.png.bin")))
    landf = rel[..., 2].astype(np.float32) / 255.0
    cov = np.asarray(Image.open(os.path.join(DATA, "cover.png.bin")))[..., 2].astype(np.float32) / 255.0
    covb = ndimage.gaussian_filter(cov, DEV_SIGMA)
    import pickle
    if args.cache and os.path.exists(args.cache):
        cen, geom = pickle.load(open(args.cache, "rb"))
    else:
        cen, geom = build_geom(ids, provs, land, landf, W1)
        if args.cache:
            pickle.dump((cen, geom), open(args.cache, "wb"))
    rdev = np.zeros(n)  # застройка округи
    for i, c in cen.items():
        rdev[i] = covb[min(int(c[1]), covb.shape[0] - 1), min(int(c[0]), covb.shape[1] - 1)]
    length = {e: g[2] for e, g in geom.items()}
    # дороги: в глуши (обе провинции почти без застройки) — нет
    # развитость страны: бедные — реже (порог застройки выше, остов реже)
    grp0 = [GROUP.get(p["owner"], p["owner"]) for p in provs]
    kdev = np.array([(COLONY_K.get(grp0[i], COLONY_DEFAULT) if p.get("colony") else DEV_K.get(grp0[i], DEV_DEFAULT))
                     for i, p in enumerate(provs)])
    ke = {e: 0.5 * (kdev[e[0]] + kdev[e[1]]) for e in geom}
    redges = [e for e in geom if max(rdev[e[0]], rdev[e[1]]) * ke[e] >= ROAD_DEV]
    roads = set(spanner(n, redges, {e: ROAD_T + ROAD_T_POOR * (1.0 - ke[e]) for e in redges}, length))
    # железные дороги: через границу стран — только исторические переходы (CROSS)
    grp = [GROUP.get(p["owner"], p["owner"]) for p in provs]
    cost = {e: length[e] * 0.5 * (T_COST[provs[e[0]]["terrain"]] + T_COST[provs[e[1]]["terrain"]]) for e in geom}
    import build_map as bm
    cross = set()
    for ta, tb, lon, lat in CROSS:
        x, y = bm.project(lon, lat)
        x, y = float(x), float(y)
        best, bd = None, 1e9
        for e, g in geom.items():
            if {grp[e[0]], grp[e[1]]} != {ta, tb}:
                continue
            w = g[0][2]
            d = math.hypot(w[0] - x, w[1] - y)
            if d < bd:
                best, bd = e, d
        if best is None or bd > 30:
            print(f"переход {ta}–{tb} ({lon}, {lat}): ребра нет (ближайшее {bd:.0f} пикс.)")
            continue
        cross.add(best)
    print(f"переходов через границу {len(cross)} из {len(CROSS)}")
    redges_ok = [e for e in geom if grp[e[0]] == grp[e[1]] or e in cross]
    # запасной граф для пунктов снабжения — без гор (через хребты пути не шли)
    flat = [e for e in redges_ok if provs[e[0]]["terrain"] != 3 and provs[e[1]]["terrain"] != 3]
    G2 = csr_matrix((np.array([cost[e] for e in flat] * 2),
                     (np.array([e[0] for e in flat] + [e[1] for e in flat]),
                      np.array([e[1] for e in flat] + [e[0] for e in flat]))), shape=(n, n))
    nd = None
    if args.ne_rail:
        nd = ne_rail_dist(args.ne_rail, W1, meta["height"])
        def real(e):
            if e in cross:
                return True
            if provs[e[0]]["terrain"] == 3 or provs[e[1]]["terrain"] == 3:
                # в горах — строго (иначе длинное ребро напрямую через хребет)
                return on_rail(geom[e], nd, NE_NEAR) >= NE_FRAC_MNT
            return on_rail(geom[e], nd, max(NE_NEAR, 0.12 * length[e])) >= NE_FRAC
        redges_ok = [e for e in redges_ok if real(e)]
        print(f"рёбер вдоль реальных линий {len(redges_ok)}")
    ea = np.array([e[0] for e in redges_ok] + [e[1] for e in redges_ok])
    eb = np.array([e[1] for e in redges_ok] + [e[0] for e in redges_ok])
    ew = np.array([cost[e] for e in redges_ok] * 2)
    G = csr_matrix((ew, (ea, eb)), shape=(n, n))
    cities = [i for i, p in enumerate(provs) if p["land"] and p["vp"] >= RAIL_VP and i in cen]
    # концы переходов — тоже узлы: к ним ведут пути от ближних городов
    cities = set(cities) | {v for e in cross for v in e}
    # пункты снабжения (решение пользователя: для жд приоритет — точки снабжения)
    sup = set()
    if args.supply:
        sd = json.load(open(args.supply, encoding="utf-8"))
        sup = {int(p) for p in sd["hubs"] + sd["caps"] if int(p) in cen}
        print(f"пунктов снабжения {len(sup)}")
    cities = sorted(cities | sup)
    print(f"городов {len(cities)}, пути...", flush=True)
    D, pred = dijkstra(G, indices=cities, limit=max(RAIL_MAX, SUP_MAX), return_predecessors=True)
    ci = {c: k for k, c in enumerate(cities)}
    pairs = []
    for x in range(len(cities)):
        a = cities[x]
        for y in range(x + 1, len(cities)):
            b = cities[y]
            # пары пунктов снабжения — первыми, дальше и без скидки на бедность
            tier = 0 if (a in sup and b in sup) else 1
            if tier == 0 and math.dist(cen[a], cen[b]) <= SUP_R and D[x, b] < SUP_MAX:
                pairs.append((0, D[x, b], a, b))
            elif math.dist(cen[a], cen[b]) <= RAIL_R and D[x, b] < RAIL_MAX:
                pairs.append((1, D[x, b], a, b))
    pairs.sort()
    radj = [[] for _ in range(n)]
    rails = set()
    for e in cross:
        rails.add(e)
        radj[e[0]].append((e[1], cost[e]))
        radj[e[1]].append((e[0], cost[e]))
    def lay(a, b):
        v = b
        row = ci[a]
        while v != a:
            u = int(pred[row, v])
            e = (min(u, v), max(u, v))
            if e not in rails:
                rails.add(e)
                radj[u].append((v, cost[e]))
                radj[v].append((u, cost[e]))
            v = u

    for tier, c, a, b in pairs:
        if tier == 0:
            t = RAIL_T
        else:
            t = RAIL_T + RAIL_T_WILD * (1.0 - min(1.0, 0.5 * (rdev[a] + rdev[b]) / RAIL_DEV)) \
                + RAIL_T_POOR * (1.0 - 0.5 * (kdev[a] + kdev[b]))
        if _dist(radj, a, b, t * c) <= t * c:
            continue
        lay(a, b)
    # пункт снабжения без жд — к ближайшему узлу с жд (если путь вдоль реальных линий есть)
    lone = 0
    for s_ in sorted(sup):
        if radj[s_]:
            continue
        row = D[ci[s_]]
        cand = [v for v in range(n) if radj[v] and row[v] < SUP_MAX]
        if cand:
            lay(s_, min(cand, key=lambda v: row[v]))
        elif nd is not None and nd[min(int(cen[s_][1]), nd.shape[0] - 1), min(int(cen[s_][0]), nd.shape[1] - 1)] < SUP_NEAR:
            # реальная линия у самого пункта, но цепочка рёбер вдоль неё рвётся —
            # кратчайшим путём по провинциям своей страны
            d2, p2 = dijkstra(G2, indices=[s_], limit=SUP_MAX * 2, return_predecessors=True)
            cand = [v for v in range(n) if radj[v] and d2[0, v] < SUP_MAX * 2]
            if not cand:
                lone += 1
                continue
            v = min(cand, key=lambda v: d2[0, v])
            while v != s_:
                u = int(p2[0, v])
                e = (min(u, v), max(u, v))
                if e not in rails:
                    rails.add(e)
                    radj[u].append((v, cost[e]))
                    radj[v].append((u, cost[e]))
                v = u
        else:
            lone += 1
    print(f"пунктов снабжения без жд (нет реальных линий рядом): {lone}")
    if args.ne_rail:
        # в глуши реальная сеть и так редкая — все её линии (Транссиб, линии от портов
        # вглубь), а не только пути между городами
        # (прореженные остовом: связность та же, лишних параллелей нет)
        wild = [e for e in redges_ok if max(rdev[e[0]], rdev[e[1]]) < RAIL_DEV_WILD]
        wild = [e for e in wild if e not in rails]
        rails |= set(spanner(n, wild, {e: RAIL_T_SPAN + RAIL_T_POOR * (1.0 - ke[e]) for e in wild}, cost, radj))
    print(f"дорог {len(roads)}, жд {len(rails)} рёбер")
    # половины по провинциям
    per = {}
    for e in sorted(roads | rails):
        a, b = e
        ha, hb, _ = geom[e]
        tp = (1 if e in roads else 0) | (2 if e in rails else 0)
        per.setdefault(a, []).append((tp, 0, ha, b))
        per.setdefault(b, []).append((tp, 1, hb, a))
    cut = 0
    out = {}
    chk = Checker(ids, landf)
    thr_n = [0, 0]
    for p, hs in per.items():
        hs.sort(key=lambda h: -(h[0] & 2))
        if len(hs) > MAX_H:
            cut += len(hs) - MAX_H
            hs = hs[:MAX_H]
        # насквозь: два самых противоположных выхода вида — плавная кривая от границы
        # до границы мимо центра, остальные выходы — ответвления к её середине (не
        # «звезда» в каждом центре — сеть не «шестигранная», решение пользователя)
        thr = 0
        pair = [0, 0]
        for bit, kind, slot in ((16, 2, 0), (32, 1, 1)):
            idx = [i for i, h in enumerate(hs) if h[0] & kind]
            if len(idx) < 2:
                continue
            best = None
            for x in range(len(idx)):
                for y in range(x + 1, len(idx)):
                    h0, h1 = hs[idx[x]][2], hs[idx[y]][2]
                    kk = thr_ctrl(h0[2], h0[1], h1[1], h1[2])
                    if kk is None:
                        continue
                    d0 = (h0[1][0] - h0[2][0], h0[1][1] - h0[2][1])
                    d1 = (h1[1][0] - h1[2][0], h1[1][1] - h1[2][1])
                    dt = (d0[0] * d1[0] + d0[1] * d1[1]) / max(1e-6, math.hypot(*d0) * math.hypot(*d1))
                    if best is None or dt < best[0]:
                        best = (dt, idx[x], idx[y], kk)
            if best is None:
                continue
            _, i0, i1, kk = best
            h0, h1 = hs[i0][2], hs[i1][2]
            cv = bezier(h0[2], kk[0], kk[1], h1[2])
            mid = cv[len(cv) // 2]
            ends = [h0[2], h1[2]]
            allow = {hs[i0][3], hs[i1][3]}
            ok = chk.ok_ends(cv, p, allow, ends)
            for i in idx:
                if ok and i not in (i0, i1):
                    hw = hs[i][2]
                    k2 = ((hw[1][0] + mid[0]) / 2, (hw[1][1] + mid[1]) / 2)
                    ok = chk.ok_ends(bezier(hw[2], hw[1], k2, mid), p, {hs[i][3]}, [hw[2]])
            if ok:
                thr |= bit
                pair[slot] = i0 | (i1 << 3)
                thr_n[kind - 1] += 1
        out[str(p)] = {"c": list(cen[p]), "t": thr, "p": pair,
                       "h": [[tp, fl, h[1][0], h[1][1], h[2][0], h[2][1]] for tp, fl, h, _ in hs]}
    print(f"насквозь кривой: дорог {thr_n[0]}, жд {thr_n[1]}")
    print(f"провинций с дорогами {len(out)}, отброшено половин {cut}")
    path = os.path.abspath(os.path.join(DATA, "roads.json"))
    json.dump({"q": Q, "prov": out}, open(path, "w"), separators=(",", ":"))
    print(f"{path} ({os.path.getsize(path) // 1024} КБ)")
    if args.preview:
        rgb = np.asarray(Image.open(os.path.join(DATA, "provinces.png.bin")).convert("RGB")).astype(np.int32)
        own = np.array([hash(g) % 100000 for g in grp] + [0] * (65536 - n))[rgb[..., 0] + rgb[..., 1] * 256]
        for k, box, sc in ((".png", (2450, 560, 3400, 1000), 3), ("_w.png", (0, 0, W1, meta["height"]), 0.5)):
            preview(args.preview.replace(".png", k), out, rel, own, box, sc)


def preview(path, out, rel, own, box, S):
    from PIL import ImageDraw
    x0, y0, x1, y1 = box
    bd = np.zeros(own.shape, bool)
    bd[:, 1:] |= own[:, 1:] != own[:, :-1]
    bd[1:, :] |= own[1:, :] != own[:-1, :]
    img = np.repeat(rel[..., 2:3], 3, 2).copy()
    img[bd & (rel[..., 2] > 128)] = (150, 150, 150)
    base = Image.fromarray(img[y0:y1, x0:x1]).resize((int((x1 - x0) * S), int((y1 - y0) * S)))
    d = ImageDraw.Draw(base)
    def tr(pt):
        return ((pt[0] - x0) * S, (pt[1] - y0) * S)
    for p, v in out.items():
        c = v["c"]
        for bit, kind, col in ((16, 2, (200, 30, 30)), (32, 1, (60, 120, 220))):
            hs = [h for h in v["h"] if h[0] & kind]
            wd = 2 if (kind == 2 and S > 1) else 1
            if v.get("t", 0) & bit:
                pc = v["p"][0 if kind == 2 else 1]
                i0, i1 = pc & 7, pc >> 3
                h0, h1 = v["h"][i0], v["h"][i1]
                w0, w1 = (h0[4], h0[5]), (h1[4], h1[5])
                kk = thr_ctrl(w0, (h0[2], h0[3]), (h1[2], h1[3]), w1)
                cv = bezier(w0, kk[0], kk[1], w1)
                mid = cv[len(cv) // 2]
                d.line([tr(q) for q in cv], fill=col, width=wd)
                for i, h in enumerate(v["h"]):
                    if h[0] & kind and i not in (i0, i1):
                        k2 = ((h[2] + mid[0]) / 2, (h[3] + mid[1]) / 2)
                        d.line([tr(q) for q in bezier((h[4], h[5]), (h[2], h[3]), k2, mid)], fill=col, width=wd)
            else:
                for tp, fl, kx, ky, wx, wy in hs:
                    d.line([tr(c), tr((kx, ky)), tr((wx, wy))], fill=col, width=wd)
    base.save(path)


if __name__ == "__main__":
    main()
