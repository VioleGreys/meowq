#!/usr/bin/env python3
"""Подложка карты в духе карт жанра — из растров Natural Earth (Tom Patterson,
общественное достояние, naturalearthdata.com):

  * NE1_HR_LC — цвет природных зон без светотени (леса, степи, пустыни,
    тундра, ледники) → data/world1936/terrain.jpg.bin (цвет суши);
  * SR_HR — отмывка рельефа (shaded relief, свет с северо-запада) и OB_LR —
    рельеф морского дна → data/world1936/shade.jpg.bin (серый: суша — отмывка,
    море — яркость дна; шейдер карты кладёт её поверх цветов).

Всё в проекции карты игры (Миллер, tools/build_map.py), сглаженно (билинейно).

  python3 tools/build_terrain_ne.py --lc NE1_HR_LC.tif --sr SR_HR.tif --ob OB_LR.tif
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")


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


def load(path: str, width: int, mode: str) -> np.ndarray:
    """Растр, уменьшенный до width по ширине (меньше памяти; вдвое подробнее карты)."""
    im = Image.open(path).convert(mode)
    if im.size[0] > width:
        im = im.resize((width, width // 2), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lc", required=True, help="NE1_HR_LC.tif — цвет природных зон")
    ap.add_argument("--sr", required=True, help="SR_HR.tif — отмывка рельефа суши")
    ap.add_argument("--ob", required=True, help="OB_LR.tif — рельеф морского дна")
    ap.add_argument("--color-scale", type=int, default=2, help="цвет: во сколько раз меньше карты")
    ap.add_argument("--shade-scale", type=int, default=1, help="отмывка: во сколько раз меньше карты")
    args = ap.parse_args()
    W, H = bm.WIDTH, bm.HEIGHT
    # цвет суши: природные зоны, чуть приглушённые под «бумажную» карту
    cw, ch = W // args.color_scale, int(round(H / args.color_scale))
    src = load(args.lc, cw * 2, "RGB")
    # вода в NE1 белая: заливаем её цветом ближайшей суши, чтобы у берегов
    # (билинейная выборка в шейдере) не просвечивала белая кайма
    from scipy import ndimage
    water = src.min(-1) > 0.96
    _, (iy, ix) = ndimage.distance_transform_edt(water, return_indices=True)
    src = src[iy, ix]
    lc = reproject(src, cw, ch, args.color_scale)
    lum = (lc * np.array([0.299, 0.587, 0.114], np.float32)).sum(-1, keepdims=True)
    lc = lum + (lc - lum) * 0.92
    out = os.path.abspath(os.path.join(OUT_DIR, "terrain.jpg.bin"))
    Image.fromarray((np.clip(lc, 0, 1) * 255).astype(np.uint8), "RGB").save(out, "JPEG", quality=90, optimize=True)
    print(f"Цвет местности {cw}x{ch}: {out} ({os.path.getsize(out) // 1024} КБ)")
    # отмывка: суша — SR_HR, море — яркость рельефа дна (OB_LR), по маске суши карты
    sw_, sh_ = W // args.shade_scale, int(round(H / args.shade_scale))
    sr = reproject(load(args.sr, sw_ * 2, "L"), sw_, sh_, args.shade_scale)
    ob = reproject(load(args.ob, sw_ * 2, "L"), sw_, sh_, args.shade_scale)
    rel = np.asarray(Image.open(os.path.join(OUT_DIR, "relief.png.bin")).convert("RGB"), np.float32) / 255.0
    cov = rel[..., 2]   # доля суши по векторным контурам
    if cov.shape != sr.shape:
        cov = np.asarray(Image.fromarray((cov * 255).astype(np.uint8)).resize((sw_, sh_), Image.BILINEAR), np.float32) / 255.0
    # дно: нормируем, чтобы мелководье было светлым, глубины — тёмными
    ob = np.clip((ob - 0.05) / 0.75, 0, 1)
    shade = sr * cov + ob * (1.0 - cov)
    out = os.path.abspath(os.path.join(OUT_DIR, "shade.jpg.bin"))
    Image.fromarray((np.clip(shade, 0, 1) * 255).astype(np.uint8), "L").save(out, "JPEG", quality=88, optimize=True)
    print(f"Отмывка {sw_}x{sh_}: {out} ({os.path.getsize(out) // 1024} КБ)")


if __name__ == "__main__":
    sys.exit(main())
