#!/usr/bin/env python3
"""Покров суши для отрисовки карты: data/world1936/cover.png.bin — RGBA8 в сетке
карты (5632×2625, третий слой base_tex):

  r — лес: доля крон (Hansen/UMD 2000, CC BY 4.0, tools/forest.py);
  g — болото: доля топей, пойм, торфяников (GLWD v2, CC BY 4.0, tools/wetlands.py);
  b — застройка 1936 г.: пятна городов GeoNames cities1000 (CC BY 4.0), население
      сведено к 1936 г. множителем по стране (CITY_1936_K), площадь — население /
      плотность (URBAN_DENS); деревни — слабые точки, вблизи шейдер рисует кварталы;
  a — холмистость: разброс высот суши (ETOPO1, relief.png.bin r) в окне Гаусса
      σ = 3 пикс. (~60 км) / HILL_SD м: Арденны ~85 м, Богемия ~65, Парижский
      бассейн и Украина ~30, Альпы ~280 (шейдер: холмы — 40…90 м, выше — горы
      по уклону). По перепаду на ±3 пикс. выходили полосы вдоль уступов.

С --terrain переписывает местность провинций в map.json тем же правилом, что
build_map.py (--glwd/--forest): лес и болото — только там, где не горы, не холмы,
не пустыня и не город (они важнее), см. cover_terrain().

  python3 tools/build_cover.py --glwd GLWD_v2_0_combined_classes --forest ПАПКА_ЛЕСА \
      --geonames cities1000.txt [--cache ПАПКА] [--terrain]
"""
import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")

# местность провинции по покрову (решение пользователя, ноябрь 2026: болота и лес —
# там, где они на карте): средняя доля по пикселям провинции не меньше
MARSH_FRAC = 0.33
FOREST_FRAC = 0.45
# Полесье (Пинские болота) в 1936 г. ещё не осушено — GLWD (наши дни) его почти не видит
POLESIE = (23.5, 51.3, 30.5, 52.5)

# население города в 1936 г. ≈ нынешнее × множитель страны (грубо, по переписям
# 1930-х: Европа выросла в 1,5–2 раза, Азия, Африка, Латинская Америка — в 5–15)
CITY_1936_K = {
    "GB": 0.75, "IE": 0.6, "FR": 0.6, "BE": 0.7, "NL": 0.5, "LU": 0.5, "DE": 0.7, "AT": 0.7,
    "CH": 0.55, "IT": 0.6, "ES": 0.45, "PT": 0.45, "DK": 0.6, "NO": 0.55, "SE": 0.55,
    "FI": 0.4, "IS": 0.3, "PL": 0.45, "CZ": 0.6, "SK": 0.4, "HU": 0.6, "SI": 0.45,
    "HR": 0.4, "BA": 0.3, "RS": 0.3, "ME": 0.25, "MK": 0.3, "AL": 0.2, "GR": 0.35,
    "BG": 0.3, "RO": 0.35, "MD": 0.3, "UA": 0.35, "BY": 0.3, "LT": 0.4, "LV": 0.45,
    "EE": 0.45, "RU": 0.3, "GE": 0.3, "AM": 0.2, "AZ": 0.25, "KZ": 0.15, "UZ": 0.15,
    "TM": 0.15, "KG": 0.15, "TJ": 0.15, "TR": 0.12, "US": 0.4, "CA": 0.35, "AU": 0.35,
    "NZ": 0.35, "JP": 0.45, "KR": 0.12, "KP": 0.15, "TW": 0.15, "CN": 0.12, "HK": 0.15,
    "MN": 0.1, "IN": 0.12, "PK": 0.1, "BD": 0.08, "LK": 0.2, "NP": 0.1, "MM": 0.15,
    "TH": 0.1, "VN": 0.1, "LA": 0.1, "KH": 0.1, "MY": 0.12, "SG": 0.15, "ID": 0.1,
    "PH": 0.1, "IR": 0.1, "IQ": 0.08, "SY": 0.1, "LB": 0.15, "IL": 0.1, "PS": 0.1,
    "JO": 0.05, "SA": 0.03, "YE": 0.05, "AE": 0.01, "KW": 0.02, "QA": 0.01, "OM": 0.05,
    "AF": 0.08, "EG": 0.15, "LY": 0.1, "TN": 0.15, "DZ": 0.12, "MA": 0.1, "ZA": 0.2,
    "AR": 0.25, "UY": 0.35, "CL": 0.2, "BR": 0.1, "MX": 0.1, "CU": 0.25,
}
K_DEFAULT = 0.08          # остальные страны (Африка, Латинская Америка, Океания)
HILL_SD = 200.0           # м разброса высот на 1,0 канала a
URBAN_DENS = 6000.0       # человек на км² застройки в 1936 г.
PPL_SKIP = {"PPLX", "PPLH", "PPLQ", "PPLW", "PPLCH"}   # районы городов, исторические, заброшенные


def cover_terrain(cur: int, forest: float, marsh: float, lon: float, lat: float) -> int:
    """Местность провинции с покровом: горы (3), холмы (2), город (4), пустыня (6),
    море (5) важнее; иначе болото (7), лес (1) или равнина (0)."""
    if cur in (2, 3, 4, 5, 6):
        return cur
    x0, y0, x1, y1 = POLESIE
    if marsh >= MARSH_FRAC or (x0 < lon < x1 and y0 < lat < y1):
        return 7
    if forest >= FOREST_FRAC:
        return 1
    return 0


def polesie(marsh: np.ndarray, el: np.ndarray) -> np.ndarray:
    """Пинские болота 1936 г.: низины бассейна Припяти (ниже 175 м) в рамке POLESIE
    с мягким краем — до осушения 1960-х; GLWD (наши дни) их почти не видит."""
    h, w = marsh.shape
    yy, xx = np.mgrid[0:h, 0:w]
    x0, y0, x1, y1 = POLESIE
    px0, py1 = bm.project(x0 - 1.0, y0 - 0.4)
    px1, py0 = bm.project(x1 + 1.0, y1 + 0.4)
    sub = (slice(int(py0), int(py1) + 1), slice(int(px0), int(px1) + 1))
    lon, lat = bm.unproject(xx[sub] + 0.5, yy[sub] + 0.5)
    inside = (np.clip((lon - x0 + 1.0) / 1.0, 0, 1) * np.clip((x1 + 1.0 - lon) / 1.0, 0, 1)
              * np.clip((lat - y0 + 0.4) / 0.4, 0, 1) * np.clip((y1 + 0.4 - lat) / 0.4, 0, 1))
    low = np.clip((185.0 - el[sub]) / 25.0, 0, 1)
    m = marsh.copy()
    m[sub] = np.maximum(m[sub], (0.65 * inside * low).astype(np.float32))
    return m


def urban(path: str, w: int, h: int) -> np.ndarray:
    """Пятна застройки 1936 г.: доля пикселя карты под городом."""
    out = np.zeros((h, w), np.float64)
    small_x, small_y, small_a = [], [], []
    big = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) < 15 or c[6] != "P" or c[7] in PPL_SKIP:
                continue
            pop = float(c[14] or 0) * CITY_1936_K.get(c[8], K_DEFAULT)
            if pop < 800:
                continue
            lat, lon = float(c[4]), float(c[5])
            x, y = bm.project(lon, lat)
            x, y = float(x), float(y)
            if not (0 <= x < w and 0 <= y < h):
                continue
            km = bm.KM_PER_PX * math.cos(math.radians(lat)) * math.cos(0.8 * math.radians(lat))
            area = pop / URBAN_DENS / max(km * km, 1e-3)    # в пикселях карты
            r = math.sqrt(area / math.pi)
            if r < 0.6:
                small_x.append(x); small_y.append(y); small_a.append(area)
            else:
                big.append((x, y, r, area))
    # мелкие — билинейно в 4 соседних пикселя
    xs, ys, ar = np.array(small_x) - 0.5, np.array(small_y) - 0.5, np.array(small_a)
    x0, y0 = np.floor(xs).astype(int), np.floor(ys).astype(int)
    fx, fy = xs - x0, ys - y0
    for dx, dy, wt in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        xx, yy = np.clip(x0 + dx, 0, w - 1), np.clip(y0 + dy, 0, h - 1)
        np.add.at(out, (yy, xx), ar * wt)
    # крупные — диск с мягким краем (площадь сохраняется), неровный по шуму
    rng = np.random.default_rng(1936)
    for x, y, r, area in big:
        R = int(math.ceil(r + 2))
        cx, cy = int(x), int(y)
        yy, xx = np.mgrid[cy - R:cy + R + 1, cx - R:cx + R + 1]
        d = np.hypot(xx + 0.5 - x, yy + 0.5 - y)
        ang = np.arctan2(yy + 0.5 - y, xx + 0.5 - x)
        ph = rng.uniform(0, 6.28, 3)
        rr = r * (1 + 0.18 * np.sin(3 * ang + ph[0]) + 0.12 * np.sin(5 * ang + ph[1]) + 0.08 * np.sin(2 * ang + ph[2]))
        k = np.clip(rr + 0.5 - d, 0, 1)
        k *= area / max(k.sum(), 1e-6)
        ok = (yy >= 0) & (yy < h)
        out[yy[ok], xx[ok] % w] += k[ok]
    out = ndimage.gaussian_filter(out, 0.45)
    return np.clip(out, 0, 1).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--glwd", required=True)
    ap.add_argument("--forest", required=True)
    ap.add_argument("--geonames", required=True)
    ap.add_argument("--cache", default="")
    ap.add_argument("--terrain", action="store_true")
    args = ap.parse_args()
    W, H = bm.WIDTH, bm.HEIGHT

    def cached(name, fn):
        p = os.path.join(args.cache, name + ".npy") if args.cache else ""
        if p and os.path.exists(p):
            return np.load(p)
        v = fn()
        if p:
            np.save(p, v)
        return v

    import forest
    import wetlands
    wl = cached("wetlands", lambda: np.stack(wetlands.load(args.glwd, W, H)))
    marsh = wl[0]   # wl[1] — рис (GLWD 33): не используем, рисовые чеки шейдер рисует по широте
    fr = cached("forest", lambda: forest.load(args.forest, W, H))
    urb = urban(args.geonames, W, H)
    rgb = np.asarray(Image.open(os.path.join(DATA, "provinces.png.bin")).convert("RGB")).astype(np.int32)
    prov = rgb[..., 0] + rgb[..., 1] * 256
    meta = json.load(open(os.path.join(DATA, "map.json"), encoding="utf-8"))
    land = np.array([p["land"] for p in meta["provinces"]], bool)[prov]
    rel = np.asarray(Image.open(os.path.join(DATA, "relief.png.bin")))[..., 0].astype(np.float64) / 255.0
    el = (np.clip(rel - 0.5, 0, None) * 2.0) ** 2 * 6000.0
    m1 = ndimage.gaussian_filter(el, 3.0)
    m2 = ndimage.gaussian_filter(el * el, 3.0)
    hil = (np.sqrt(np.clip(m2 - m1 * m1, 0, None)) / HILL_SD).astype(np.float32)
    marsh = polesie(marsh, el)
    out = np.stack([fr, marsh, urb, hil], 2) * land[..., None]
    Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(
        os.path.join(DATA, "cover.png.bin"), "PNG", optimize=True)
    print("cover.png.bin: лес %.3f, болото %.3f, застройка %.4f, холмистость %.3f (средние по суше)" % tuple(
        float(out[..., i][land].mean()) for i in range(4)))
    if not args.terrain:
        return
    n = len(meta["provinces"])
    fm = ndimage.mean(fr, labels=prov, index=np.arange(n))
    mm = ndimage.mean(marsh, labels=prov, index=np.arange(n))
    before = {}
    after = {}
    for i, p in enumerate(meta["provinces"]):
        if p["land"] != 1:
            continue
        t0 = int(p["terrain"])
        t1 = cover_terrain(t0, float(fm[i]), float(mm[i]), float(p["lon"]), float(p["lat"]))
        before[t0] = before.get(t0, 0) + 1
        after[t1] = after.get(t1, 0) + 1
        p["terrain"] = t1
    print("местность было:", dict(sorted(before.items())), "стало:", dict(sorted(after.items())))
    with open(os.path.join(DATA, "map.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
