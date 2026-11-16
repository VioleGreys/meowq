#!/usr/bin/env python3
"""Рамки провинций (x0, y0, x1, y1 в пикселях карты 1×, включительно) по карте
отрисовки 2× (data/world1936/ids2_*.png.bin, tools/build_ids2x.py) — в map.json
полем "bb". Игра перерисовывает после смены владельцев только экранную область
изменившихся провинций (MapView), а не всю карту.

  python3 tools/build_bbox.py      (после build_ids2x.py)
"""
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(__file__))
from build_ids2x import PAD  # noqa: E402

DATA = os.path.join(os.path.dirname(__file__), "..", "data", "world1936")


def main():
    mp = os.path.join(DATA, "map.json")
    meta = json.load(open(mp, encoding="utf-8"))
    n = len(meta["provinces"])
    w1 = int(meta["width"])
    half2 = w1   # половина сетки 2× по ширине — столько же столбцов, сколько у 1×
    bb = np.full((n, 4), -1, np.int64)
    for k in ("w", "e"):
        a = np.asarray(Image.open(os.path.join(DATA, f"ids2_{k}.png.bin")).convert("RGB")).astype(np.int64)
        ids = a[..., 0] + a[..., 1] * 256
        x_off = 0 if k == "w" else half2 - PAD
        # только «своя» часть половины (без перекрытия)
        if k == "w":
            ids = ids[:, :half2]
        else:
            ids = ids[:, PAD:]
            x_off = half2
        sl = ndimage.find_objects(ids + 1)
        for pid in range(min(n, len(sl))):
            s = sl[pid] if pid < len(sl) else None
            # find_objects: индекс метки − 1; метка = id + 1
            if s is None:
                continue
            y0, y1 = s[0].start, s[0].stop - 1
            x0, x1 = s[1].start + x_off, s[1].stop - 1 + x_off
            if bb[pid, 0] < 0:
                bb[pid] = (x0, y0, x1, y1)
            else:
                bb[pid] = (min(bb[pid, 0], x0), min(bb[pid, 1], y0), max(bb[pid, 2], x1), max(bb[pid, 3], y1))
    miss = 0
    for i, p in enumerate(meta["provinces"]):
        if bb[i, 0] < 0:
            miss += 1
            p["bb"] = [int(p["x"]), int(p["y"]), int(p["x"]), int(p["y"])]
        else:
            # в пикселях 1× (сетка 2× / 2), с запасом в пиксель
            p["bb"] = [int(bb[i, 0] // 2), int(bb[i, 1] // 2), int(bb[i, 2] // 2 + 1), int(bb[i, 3] // 2 + 1)]
    json.dump(meta, open(mp, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
    print(f"рамки провинций: {n} (нет на карте 2×: {miss}) → {os.path.abspath(mp)}")


if __name__ == "__main__":
    sys.exit(main())
