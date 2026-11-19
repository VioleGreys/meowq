#!/usr/bin/env python3
"""Силуэты флотов и авиации для плашек на карте: assets/icons/navair.png.bin
(атлас RGBA, белый силуэт по альфе — в игре окрашивается) + assets/icons/navair.json
({имя: [x, y, w, h]}).

Самолёты (вид сверху) — набор «Top Down Planes Sprites Pack» (sujit1717 /
Unlucky Studio, OpenGameArt, CC0): Bf 109E — истребители (plane_0), Blenheim —
фронтовые бомбардировщики (plane_1), B-17 — тяжёлые (plane_2), TBM-3 Avenger —
морские (plane_3).
Корабли (профиль, как в опознавательных альбомах) — рисуются здесь же:
ship_0 линкор, ship_1 крейсер, ship_2 эсминец, ship_3 подлодка, ship_4 авианосец,
ship_5 транспорт (порядок — ShipDesigns.FAM_*).

  python3 tools/build_navair.py --planes "папка/Without Source files -Game Assets"
"""
import argparse
import io
import json
import os
import sys

from PIL import Image, ImageDraw

PLANES = {
    "plane_0": "BF-109E/Type-1/BF109E.png",
    "plane_1": "Blenheim/Type_1/Blemheim_progress_3.png",
    "plane_2": "B-17/Type-1/B-17.png",
    "plane_3": "TBM3/Type_1/TBM-3.png",
}
CELL = 128          # клетка атласа самолёта
SHIP_W, SHIP_H = 192, 64   # клетка корабля (профиль ~3:1)
SS = 4              # рисуем корабли в 4× и уменьшаем (сглаживание)


def plane_cell(path):
    im = Image.open(path).convert("RGBA")
    a = im.split()[3]
    bb = a.getbbox()
    a = a.crop(bb)
    s = (CELL - 8) / max(a.size)
    a = a.resize((max(1, round(a.size[0] * s)), max(1, round(a.size[1] * s))), Image.LANCZOS)
    a = a.point(lambda v: 255 if v > 40 else v * 6)   # силуэт: полупрозрачные края — плотнее
    out = Image.new("RGBA", (CELL, CELL), (255, 255, 255, 0))
    white = Image.new("RGBA", a.size, (255, 255, 255, 255))
    out.paste(white, ((CELL - a.size[0]) // 2, (CELL - a.size[1]) // 2), a)
    return out


def _hull(d, x0, x1, deck, wl, bow_rise=6, stern_cut=4):
    """Корпус: ватерлиния wl, палуба deck, нос справа приподнят и скошен."""
    d.polygon([(x0 + stern_cut, wl), (x1 - 14, wl), (x1, deck - bow_rise), (x1 - 4, deck - bow_rise),
               (x1 - 30, deck), (x0, deck), (x0, deck + 4)], fill=255)


def _turret(d, cx, top, w=14, h=6, gun=16, dirn=1):
    d.rectangle([cx - w // 2, top, cx + w // 2, top + h], fill=255)
    gy = top + 2
    if dirn > 0:
        d.rectangle([cx + w // 2, gy, cx + w // 2 + gun, gy + 2], fill=255)
    else:
        d.rectangle([cx - w // 2 - gun, gy, cx - w // 2, gy + 2], fill=255)


def ship_cell(kind):
    W, H = SHIP_W * SS, SHIP_H * SS
    im = Image.new("L", (W // SS * SS, H), 0)
    d = ImageDraw.Draw(im)
    # координаты в «единицах» 192×64, затем ×SS
    def P(pts):
        return [(x * SS, y * SS) for x, y in pts]
    def R(x0, y0, x1, y1):
        d.rectangle([x0 * SS, y0 * SS, x1 * SS, y1 * SS], fill=255)
    def poly(pts):
        d.polygon(P(pts), fill=255)
    wl = 46
    if kind == 0:   # линкор: две башни в носу, мачта-башня, труба, башня в корме
        poly([(6, wl), (170, wl), (186, 34), (182, 34), (150, 38), (6, 38), (4, 40)])
        R(70, 26, 112, 38)            # надстройка
        poly([(84, 26), (100, 26), (96, 10), (88, 10)])   # башенная мачта
        R(90, 4, 92, 10)
        poly([(106, 26), (116, 26), (114, 16), (107, 16)])   # труба
        for cx, top, dr in ((132, 31, 1), (150, 31, 1), (40, 31, -1), (24, 32, -1)):
            R(cx - 7, top, cx + 7, 38)
            if dr > 0:
                R(cx + 7, top + 1.5, cx + 20, top + 3)
            else:
                R(cx - 20, top + 1.5, cx - 7, top + 3)
    elif kind == 1:   # крейсер: длинный, две трубы, по две башни
        poly([(8, wl), (168, wl), (184, 36), (180, 36), (150, 39), (8, 39), (6, 41)])
        R(84, 28, 118, 39)
        poly([(108, 28), (116, 28), (114, 14), (110, 14)])
        R(111, 6, 112.5, 14)
        poly([(90, 28), (97, 28), (96, 18), (91, 18)])
        poly([(74, 39), (82, 39), (81, 22), (75, 22)])
        for cx, dr in ((138, 1), (153, 1), (46, -1), (31, -1)):
            R(cx - 6, 33, cx + 6, 39)
            if dr > 0:
                R(cx + 6, 34.5, cx + 16, 35.8)
            else:
                R(cx - 16, 34.5, cx - 6, 35.8)
    elif kind == 2:   # эсминец: низкий, мостик, две трубы, торпедные аппараты
        poly([(14, wl), (162, wl), (178, 38), (174, 38), (146, 41), (14, 41), (12, 43)])
        R(118, 31, 134, 41)
        R(124, 22, 126, 31)
        poly([(96, 41), (104, 41), (103, 29), (97, 29)])
        poly([(78, 41), (86, 41), (85, 30), (79, 30)])
        R(54, 37, 70, 39)
        R(146, 36, 154, 41); R(154, 37, 162, 38)
        R(24, 36, 32, 41); R(16, 37, 24, 38)
    elif kind == 3:   # подлодка: сигара, рубка, орудие
        d.ellipse([10 * SS, 36 * SS, 182 * SS, 48 * SS], fill=255)
        poly([(82, 37), (112, 37), (108, 26), (88, 26)])
        R(98, 18, 99.5, 26); R(92, 21, 93.5, 26)
        R(122, 33, 128, 37); R(128, 34, 138, 35.2)
    elif kind == 4:   # авианосец: сплошная полётная палуба со свесами, «остров» справа
        poly([(14, wl), (164, wl), (176, 38), (20, 38)])
        R(4, 34, 186, 38)             # полётная палуба
        R(120, 22, 140, 34)           # остров
        R(126, 12, 130, 22)
        R(130, 16, 136, 22)
    else:   # транспорт: корпус, надстройка в середине, труба, мачты со стрелами
        poly([(12, wl), (166, wl), (178, 34), (174, 34), (150, 36), (24, 36), (12, 34), (10, 38)])
        R(84, 26, 108, 36)
        poly([(92, 26), (100, 26), (99, 16), (93, 16)])
        R(54, 12, 55.5, 36); R(136, 12, 137.5, 36)
        d.line([(55 * SS, 16 * SS), (70 * SS, 30 * SS)], fill=255, width=SS)
        d.line([(137 * SS, 16 * SS), (122 * SS, 30 * SS)], fill=255, width=SS)
    a = im.resize((SHIP_W, SHIP_H), Image.LANCZOS)
    out = Image.new("RGBA", (SHIP_W, SHIP_H), (255, 255, 255, 0))
    out.putalpha(a)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--planes", required=True, help="папка 'Without Source files -Game Assets' набора")
    root = os.path.join(os.path.dirname(__file__), "..", "assets", "icons")
    ap.add_argument("--out", default=os.path.join(root, "navair.png.bin"))
    args = ap.parse_args()
    cells = [(n, plane_cell(os.path.join(args.planes, p))) for n, p in PLANES.items()]
    cells += [("ship_%d" % k, ship_cell(k)) for k in range(6)]
    pad = 4
    W = 512
    x = y = pad
    row_h = 0
    rects = {}
    for n, im in cells:
        if x + im.size[0] + pad > W:
            x, y, row_h = pad, y + row_h + pad, 0
        rects[n] = [x, y, im.size[0], im.size[1]]
        x += im.size[0] + pad
        row_h = max(row_h, im.size[1])
    atlas = Image.new("RGBA", (W, y + row_h + pad), (255, 255, 255, 0))
    for n, im in cells:
        atlas.paste(im, tuple(rects[n][:2]))
    buf = io.BytesIO()
    atlas.save(buf, "PNG", optimize=True)
    open(args.out, "wb").write(buf.getvalue())
    json.dump({"_comment": "Силуэты флотов и авиации (tools/build_navair.py): имя -> [x, y, w, h] в navair.png.bin",
               "icons": rects}, open(os.path.join(os.path.dirname(args.out), "navair.json"), "w"), ensure_ascii=False)
    atlas.save(os.environ.get("NAVAIR_PREVIEW", "/dev/null") if os.environ.get("NAVAIR_PREVIEW") else buf, "PNG")
    print(len(rects), "силуэтов ->", os.path.abspath(args.out), atlas.size)


if __name__ == "__main__":
    sys.exit(main())
