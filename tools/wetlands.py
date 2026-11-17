"""Болота по данным GLWD v2 (Global Lakes and Wetlands Database 2.0, Lehner et al.
2025, ESSD; CC BY 4.0; figshare 10.6084/m9.figshare.28519994,
GLWD_v2_0_combined_classes_tif.zip: GLWD_v2_0_area_pct.tif — доля водно-болотных
угодий в ячейке 15″, GLWD_v2_0_main_class.tif — главный класс ячейки).

load(dir, w, h) → (болото, рис) 0…1 в разрешении карты:
  болото — затопляемые поймы и топи (10–13, 16, 17), торфяники (22–27), мангры,
  марши, дельты (28–30); «сезонно сырые» (14, 15, 18, 19) — нет: так GLWD метит
  и осушенные польдеры (Нидерланды, Фландрия, долина По);
  озёра и реки (1–7), пересыхающие (20, 21), солончаки (32) — не болото;
  рис — рисовые поля (33): на карте — пашня, не болото.
Растр 15″ усредняется блоками 8×8 (2′) и перепроецируется в карту (как aridity).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))

MARSH = [10, 11, 12, 13, 16, 17] + list(range(22, 31))
RICE = [33]
LAT_TOP = 84.0       # GLWD: 84° с. ш. … 56° ю. ш.
BLK = 8


def _blocks(a: np.ndarray) -> np.ndarray:
    hh, ww = a.shape[0] // BLK * BLK, a.shape[1] // BLK * BLK
    return a[:hh, :ww].reshape(hh // BLK, BLK, ww // BLK, BLK).mean((1, 3), dtype=np.float32)


def load(path: str, width: int, height: int):
    import tifffile
    import build_map_art as ba
    d = path if os.path.isdir(path) else os.path.dirname(path)
    pct = tifffile.imread(os.path.join(d, "GLWD_v2_0_area_pct.tif"))
    cls = tifffile.imread(os.path.join(d, "GLWD_v2_0_main_class.tif"))
    out = []
    step = 4096
    for group in (MARSH, RICE):
        acc = []
        for y0 in range(0, pct.shape[0], step):
            p = pct[y0:y0 + step]
            c = cls[y0:y0 + step]
            m = np.where(np.isin(c, group) & (p <= 100), p, 0).astype(np.float32) / 100.0
            acc.append(_blocks(m))
        m = np.concatenate(acc, 0)
        # до полного растра 90° с. ш. … 90° ю. ш. (как ждёт reproject)
        res = 180.0 / (m.shape[1] / 2.0)
        top = int(round((90.0 - LAT_TOP) / res))
        full = np.zeros((int(round(180.0 / res)), m.shape[1]), np.float32)
        full[top:top + m.shape[0]] = m
        r = ba.reproject(full, width * 2, height * 2, 0.5)
        out.append(r.reshape(height, 2, width, 2).mean((1, 3)).astype(np.float32))
        del m, full, r
    del pct, cls
    return out[0], out[1]
