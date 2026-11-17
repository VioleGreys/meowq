#!/usr/bin/env python3
"""Леса по сомкнутости крон (Hansen et al. 2013, Global Forest Change, University
of Maryland; CC BY 4.0; treecover2000 — доля крон в 2000 г., 0–100 %, 1″).

  python3 tools/forest.py --fetch ПАПКА   — скачать тайлы 10°×10° по одному,
      каждый сразу ужать блоками 125×125 (≈1,9′) и удалить; мозаика —
      ПАПКА/treecover_mosaic.npy (80° с. ш. … 60° ю. ш., float16 0…1).

load(папка, w, h) → доля леса 0…1 в разрешении карты (как aridity / wetlands).
Лес 2000 г., не 1936-го: вырубки в тропиках с тех пор — лес на карте гуще,
чем был в 2000-м; для Европы и России разница невелика.
"""
import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))

URL = "https://storage.googleapis.com/earthenginepartners-hansen/GFC-2023-v1.11/Hansen_GFC-2023-v1.11_treecover2000_{}_{}.tif"
BLK = 125                      # 40000 / 125 = 320 на тайл
TILE = 40000 // BLK
LAT_TOP, LAT_BOT = 80, -60
MOSAIC = "treecover_mosaic.npy"


def _name(lat, lon):
    return ("%02dN" % lat if lat >= 0 else "%02dS" % -lat), ("%03dE" % lon if lon >= 0 else "%03dW" % -lon)


def _one(job):
    import tifffile
    d, lat, lon = job
    a, b = _name(lat, lon)
    part = os.path.join(d, "t_%s_%s.npy" % (a, b))
    if os.path.exists(part):
        return part
    tmp = os.path.join(d, "t_%s_%s.tif" % (a, b))
    r = subprocess.run(["curl", "-sS", "-f", "--retry", "4", "-o", tmp, URL.format(a, b)])
    if r.returncode != 0:
        np.save(part, np.zeros((TILE, TILE), np.float16))
        return part
    t = tifffile.imread(tmp)
    os.remove(tmp)
    m = np.zeros((TILE, TILE), np.float16)
    for i in range(TILE):   # по полосам: тайл целиком во float — 6,4 ГБ
        s = t[i * BLK:(i + 1) * BLK].astype(np.float32)
        s[s > 100] = 0
        m[i] = s.reshape(BLK, TILE, BLK).mean((0, 2)) / 100.0
    del t
    np.save(part, m)
    return part


def fetch(d):
    os.makedirs(d, exist_ok=True)
    jobs = [(d, lat, lon) for lat in range(LAT_TOP, LAT_BOT, -10) for lon in range(-180, 180, 10)]
    done = 0
    with ThreadPoolExecutor(3) as ex:
        for _ in ex.map(_one, jobs):
            done += 1
            if done % 20 == 0:
                print("тайлов %d из %d" % (done, len(jobs)), flush=True)
    rows = []
    for lat in range(LAT_TOP, LAT_BOT, -10):
        rows.append(np.concatenate([np.load(os.path.join(d, "t_%s_%s.npy" % _name(lat, lon)))
                                    for lon in range(-180, 180, 10)], 1))
    np.save(os.path.join(d, MOSAIC), np.concatenate(rows, 0))
    print("мозаика готова")


def load(d: str, width: int, height: int):
    import build_map_art as ba
    m = np.load(os.path.join(d, MOSAIC)).astype(np.float32)
    res = 10.0 / TILE
    full = np.zeros((int(round(180.0 / res)), m.shape[1]), np.float32)
    top = int(round((90.0 - LAT_TOP) / res))
    full[top:top + m.shape[0]] = m
    r = ba.reproject(full, width * 2, height * 2, 0.5)
    return r.reshape(height, 2, width, 2).mean((1, 3)).astype(np.float32)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", required=True)
    fetch(ap.parse_args().fetch)
