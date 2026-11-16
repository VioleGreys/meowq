"""Рельеф ETOPO1 (NOAA, общественное достояние) в проекции карты: высота суши
и уклон — для местности провинций (горы, холмы) и высоты суши в relief.png.bin.

Одна геометрия с графикой карты (tools/build_map_art.py): та же перепроекция,
вдвое подробнее карты, затем среднее 2×2. Уклон — в метрах на километр
(пиксель карты по широте уже: × cos широты), поэтому пороги одинаковы на любой
широте.
"""
import os
import sys

import numpy as np
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))

# высота суши в канале r relief.png.bin: 0.5 + 0.5·sqrt(h / ELEV_MAX)
# (корень — подробнее в низинах и предгорьях; шейдер обращает так же)
ELEV_MAX = 6000.0


def load(path: str, width: int, height: int):
    """→ (высота м ≥ 0, уклон м/км) в разрешении карты width×height."""
    import tifffile
    import build_map as bm
    import build_map_art as ba
    z = tifffile.imread(path).astype(np.float32)[:-1, :-1]   # grid-registered: лишний столбец и строка
    z2 = ba.reproject(z, width * 2, height * 2, 0.5)
    del z
    zl = ndimage.gaussian_filter(np.maximum(z2, 0.0), 1.0)
    del z2
    h2 = zl.shape[0]
    _, lat = bm.unproject(np.zeros(h2) + 0.5, (np.arange(h2) + 0.5) / 2)
    px_km = (bm.KM_PER_PX / 2 * np.cos(np.radians(np.asarray(lat))))[:, None].astype(np.float32)
    gx = np.zeros_like(zl)
    gy = np.zeros_like(zl)
    gx[:, 1:-1] = (zl[:, 2:] - zl[:, :-2]) / (2 * px_km)
    gy[1:-1] = (zl[2:] - zl[:-2]) / (2 * px_km[1:-1])
    slope = np.sqrt(gx * gx + gy * gy)
    del gx, gy
    slope = slope.reshape(height, 2, width, 2).mean((1, 3))
    elev = zl.reshape(height, 2, width, 2).mean((1, 3))
    return elev.astype(np.float32), slope.astype(np.float32)


def height_channel(elev: np.ndarray) -> np.ndarray:
    """Высота суши → значение канала r (0.5…1)."""
    return 0.5 + 0.5 * np.sqrt(np.clip(elev / ELEV_MAX, 0.0, 1.0))
