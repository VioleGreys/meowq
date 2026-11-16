"""Пустыни и степи по климату: карта Кёппена — Гейгера за 1901–1930 гг.
(Beck et al. 2023, Scientific Data, CC BY 4.0; figshare 21789074,
1901_1930/koppen_geiger_0p00833333.tif, 1 км). Классы: 4 BWh, 5 BWk — пустыня;
6 BSh, 7 BSk — полупустыня и степь.

load(path, w, h) → (доля пустыни, доля степи) 0…1 в разрешении карты: маски
классов усредняются блоками 2×2 исходника и перепроецируются билинейно вдвое
подробнее карты (как графика карты), затем среднее 2×2.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))


def load(path: str, width: int, height: int):
    import tifffile
    import build_map_art as ba
    kg = tifffile.imread(path)
    hh, ww = kg.shape[0] // 2 * 2, kg.shape[1] // 2 * 2
    kg = kg[:hh, :ww]
    out = []
    for cls in ((4, 5), (6, 7)):
        m = np.isin(kg, cls).astype(np.float32)
        m = m.reshape(hh // 2, 2, ww // 2, 2).mean((1, 3))
        r = ba.reproject(m, width * 2, height * 2, 0.5)
        out.append(r.reshape(height, 2, width, 2).mean((1, 3)).astype(np.float32))
        del m, r
    return out[0], out[1]
