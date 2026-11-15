#!/usr/bin/env python3
"""Графика карты «как в жанре» вдвое подробнее карты (11264×5250, половинами
запад/восток — *_w, *_e; импорт Godot со сжатием в видеопамяти, assets/map/):

  * colormap.jpg — цвет суши: природные зоны Natural Earth NE1_HR_LC (Tom
    Patterson, общественное достояние), сглаженные; под морем — цвет ближайшей
    суши (у берега выборка не смешивает сушу с водой — берег рисует шейдер);
  * normal.png — карта нормалей рельефа суши и дна по ETOPO1 (R, G — наклон,
    0.5 — ровно; B — 0): шейдер карты считает по ней свет (объём вблизи).
    Высота сглажена до размера пикселя карты — без зерна при увеличении;
  * глубина моря по ETOPO1 (NOAA, общественное достояние) — в канал r
    data/world1936/relief.png.bin (только море: 0.5 − 0.45·глубина; суша как
    была). Запускать после tools/build_map.py (он пишет relief заново).

  python3 tools/build_map_art.py --lc NE1_HR_LC.tif --etopo ETOPO1_Ice_g_geotiff.tif
"""
import argparse
import math
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "map")
def reproject(src: np.ndarray, w: int, h: int, scale: float) -> np.ndarray:
    """Равнопромежуточный растр (долгота −180..180, широта 90..−90) → проекция
    карты w×h (пиксель карты = scale пикселей полной карты), билинейно, по полосам."""
    sh, sw = src.shape[:2]
    chans = 1 if src.ndim == 2 else src.shape[2]
    out = np.zeros((h, w, chans), np.float32)
    band = 256
    for y0 in range(0, h, band):
        y1 = min(h, y0 + band)
        py, px = np.mgrid[y0:y1, 0:w].astype(np.float64)
        lon, lat = bm.unproject((px + 0.5) * scale, (py + 0.5) * scale)
        u = (np.asarray(lon) + 180.0) / 360.0 * sw - 0.5
        v = (90.0 - np.asarray(lat)) / 180.0 * sh - 0.5
        u0 = np.floor(u).astype(np.int64)
        v0 = np.clip(np.floor(v).astype(np.int64), 0, sh - 2)
        fu = (u - u0)[..., None].astype(np.float32)
        fv = np.clip(v - v0, 0, 1)[..., None].astype(np.float32)
        u0 %= sw
        u1 = (u0 + 1) % sw
        s = src if src.ndim == 3 else src[..., None]
        c = (s[v0, u0] * (1 - fu) * (1 - fv) + s[v0, u1] * fu * (1 - fv)
             + s[v0 + 1, u0] * (1 - fu) * fv + s[v0 + 1, u1] * fu * fv)
        out[y0:y1] = c
    return out if chans > 1 else out[..., 0]


EXAG_LAND = 9.0    # преувеличение рельефа суши для нормалей (вид карты, не физика)
EXAG_SEA = 2.5     # дна — слабее: хребты угадываются, не рябят


SCALE = 2          # подложка вдвое подробнее карты (11264×5250)
PAD = 32           # перекрытие половин (бикубическая выборка и mipmap не видят шва)


def save_halves(arr: np.ndarray, name: str, ext: str) -> None:
    """Половины запад/восток с перекрытием PAD: шире 8192 текстуры есть не на
    всех телефонах. Шейдер: запад — x < W2/2, восток — со сдвигом W2/2 − PAD."""
    w2 = arr.shape[1]
    half = w2 // 2
    parts = {"w": arr[:, : half + PAD], "e": arr[:, half - PAD:]}
    for k, a in parts.items():
        out = os.path.abspath(os.path.join(OUT_DIR, f"{name}_{k}.{ext}"))
        mode = "RGB"
        im = Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), mode)
        if ext == "jpg":
            im.save(out, "JPEG", quality=94, optimize=True)
        else:
            im.save(out, "PNG", optimize=True)
        print(f"{name}_{k} {a.shape[1]}x{a.shape[0]}: {out} ({os.path.getsize(out) // 1024} КБ)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lc", required=True, help="NE1_HR_LC.tif — цвет природных зон")
    ap.add_argument("--etopo", required=True, help="ETOPO1_Ice_g_geotiff.tif — высоты суши и глубины, м")
    args = ap.parse_args()
    import tifffile
    W, H = bm.WIDTH, bm.HEIGHT
    W2, H2 = W * SCALE, H * SCALE
    os.makedirs(OUT_DIR, exist_ok=True)
    # высоты: ETOPO1 (1′, 21600 по ширине — почти столько же, сколько подложка) → лёгкое сглаживание
    z = tifffile.imread(args.etopo).astype(np.float32)[:-1, :-1]   # grid-registered: лишний столбец и строка
    z2 = reproject(z, W2, H2, 1.0 / SCALE)
    del z
    z2 = ndimage.gaussian_filter(z2, 1.3)
    zm = z2.reshape(H, SCALE, W, SCALE).mean((1, 3))   # глубины моря — в разрешении карты
    # маска суши — по векторным контурам карты (relief.png.bin, канал b), вдвое подробнее
    relp = os.path.join(os.path.dirname(__file__), "..", "data", "world1936", "relief.png.bin")
    rel = np.asarray(Image.open(relp).convert("RGB"), np.float32) / 255.0
    cov = rel[..., 2]
    cov2 = np.asarray(Image.fromarray((cov * 255).astype(np.uint8)).resize((W2, H2), Image.BILINEAR), np.float32) / 255.0
    land2 = cov2 >= 0.5
    # нормали: наклон в метрах на метр (пиксель подложки — KM_PER_PX/SCALE на экваторе, × cos широты)
    _, lat = bm.unproject(np.zeros(H2) + 0.5, (np.arange(H2) + 0.5) / SCALE)
    px_m = (bm.KM_PER_PX * 1000.0 / SCALE * np.cos(np.radians(np.asarray(lat))))[:, None].astype(np.float32)
    zl = np.where(land2, np.maximum(z2, 0.0), z2)
    del z2
    gx = np.zeros_like(zl)
    gy = np.zeros_like(zl)
    gx[:, 1:-1] = (zl[:, 2:] - zl[:, :-2]) / (2.0 * px_m)
    gy[1:-1, :] = (zl[2:, :] - zl[:-2, :]) / (2.0 * px_m[1:-1])
    del zl
    ex = np.where(land2, EXAG_LAND, EXAG_SEA).astype(np.float32)
    nx, ny = -gx * ex, -gy * ex
    del gx, gy, ex
    ln = np.sqrt(nx * nx + ny * ny + 1.0)
    nrm = np.stack([nx / ln * 0.5 + 0.5, ny / ln * 0.5 + 0.5, np.zeros_like(nx)], -1)
    del nx, ny, ln
    save_halves(nrm, "normal", "png")
    del nrm
    # цвет: природные зоны (вода NE1 белая — заливаем ближайшей сушей)
    lc = np.asarray(Image.open(args.lc).convert("RGB"), np.float32) / 255.0
    water = lc.min(-1) > 0.96
    _, (iy, ix) = ndimage.distance_transform_edt(water, return_indices=True)
    lc = lc[iy, ix]
    del iy, ix, water
    lc = reproject(lc, W2, H2, 1.0 / SCALE)
    # природные зоны NE1 пёстрые (пятна лесов и полей) — при увеличении это
    # зерно; как цветовая карта в жанре — гладкие переходы: сглаживаем
    lc = ndimage.gaussian_filter(lc, (3.2, 3.2, 0)) * 0.78 + lc * 0.22
    lum = (lc * np.array([0.299, 0.587, 0.114], np.float32)).sum(-1, keepdims=True)
    lc = lum + (lc - lum) * 0.95
    # под морем — цвет ближайшей суши (берег рисует шейдер)
    _, (iy, ix) = ndimage.distance_transform_edt(~land2, return_indices=True)
    lc = lc[iy, ix]
    save_halves(lc, "colormap", "jpg")
    del lc
    # глубина моря (лог. шкала до 5500 м) — в канал r relief.png.bin
    t = np.clip(np.log1p(np.maximum(-zm, 0.0) / 60.0) / math.log1p(5500.0 / 60.0), 0, 1)
    r8 = np.asarray(Image.open(relp).convert("RGB")).copy()
    sea = cov < 0.5
    r8[..., 0] = np.where(sea, np.clip((0.5 - 0.45 * t) * 255 + 0.5, 0, 127), r8[..., 0]).astype(np.uint8)
    Image.fromarray(r8, "RGB").save(relp, "PNG", optimize=True)
    print(f"Глубины моря → {os.path.abspath(relp)}")

if __name__ == "__main__":
    sys.exit(main())
