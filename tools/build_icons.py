#!/usr/bin/env python3
"""Иконки игры из набора game-icons.net (CC BY 3.0, авторы — Lorc, Delapouite и
др., https://game-icons.net) через npm-пакет @iconify-json/game-icons.

Берём только нужные иконки, заливка белая (в игре перекрашиваются), результат —
assets/icons/icons.json {имя: SVG}. Игра растеризует их при запуске
(Image.load_svg_from_string), импорт Godot не нужен.

  npm pack @iconify-json/game-icons && tar xzf iconify-json-game-icons-*.tgz
  python3 tools/build_icons.py --src package/icons.json
"""
import argparse
import json
import os
import sys

# имя в игре -> имя в game-icons
ICONS = {
    "inf": "brodie-helmet", "mnt": "mountains", "cav": "horse-head", "art": "field-gun",
    "mot": "truck", "arm": "battle-tank",
    "fleet": "battleship", "sub": "submarine", "fighter": "airplane", "bomber": "bomber",
    "anchor": "anchor", "battle": "crossed-swords", "factory": "factory", "civ": "gears",
    "mil": "gear-hammer", "research": "erlenmeyer", "diplomacy": "shaking-hands",
    "army": "rifle", "focus": "star-formation", "manpower": "person", "map": "globe",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "assets", "icons", "icons.json"))
    args = ap.parse_args()
    d = json.load(open(args.src, encoding="utf-8"))
    w, h = d.get("width", 512), d.get("height", 512)
    out = {}
    for name, src in ICONS.items():
        ic = d["icons"].get(src)
        if ic is None:
            print("нет иконки", src)
            continue
        body = ic["body"].replace("currentColor", "#ffffff")
        out[name] = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">%s</svg>'
                     % (ic.get("width", w), ic.get("height", h), ic.get("width", w), ic.get("height", h), body))
    meta = {"_comment": "Иконки game-icons.net (CC BY 3.0, Lorc, Delapouite и др.); имя в игре -> SVG. "
                        "Источник имён: tools/build_icons.py", "icons": out}
    json.dump(meta, open(args.out, "w", encoding="utf-8"), ensure_ascii=False)
    print(len(out), "иконок ->", os.path.abspath(args.out))


if __name__ == "__main__":
    sys.exit(main())
