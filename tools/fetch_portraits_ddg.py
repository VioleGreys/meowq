#!/usr/bin/env python3
"""Недостающие портреты — через поиск картинок DuckDuckGo (временное оформление,
решение пользователя: подходят любые, в том числе современные портреты).
Отсекаются фотобанки с водяными знаками, сайты игр/модов и Викимедиа (её лимит
на облачном адресе). Картинки помечаются "temporary" в assets/art_credits.json.

  python3 tools/fetch_portraits_ddg.py [--only USA,PER] [--force]
"""
import argparse
import io
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import build_portraits as bp  # noqa: E402

UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
OUT = os.path.join(bp.ROOT, "assets", "portraits")
BAD = re.compile(r"alamy|gettyimages|shutterstock|dreamstime|depositphotos|istockphoto|123rf|agefoto|"
                 r"kaiserreich|paradox|hoi4|heartsofiron|steam|wikitide|fandom|wikimedia|wikipedia|pinterest|"
                 r"pinimg|ebay|amazon", re.I)


def http(url: str, headers=None, timeout=30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def ddg_images(q: str) -> list:
    page = http("https://duckduckgo.com/?" + urllib.parse.urlencode({"q": q, "iax": "images", "ia": "images"})).decode("utf-8", "ignore")
    m = re.search(r'vqd="([^"]+)"', page) or re.search(r"vqd=([0-9-]+)", page)
    if not m:
        return []
    data = http("https://duckduckgo.com/i.js?" + urllib.parse.urlencode(
        {"l": "wt-wt", "o": "json", "q": q, "vqd": m.group(1), "f": ",,,,,", "p": "1"}),
        {"Referer": "https://duckduckgo.com/"})
    return json.loads(data).get("results", [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    credits = json.load(open(bp.CPATH, encoding="utf-8")) if os.path.exists(bp.CPATH) else {}
    tags = a.only.split(",") if a.only else list(bp.LEADERS)
    for tag in tags:
        if not a.force and os.path.exists(os.path.join(OUT, tag + ".jpg")):
            continue
        name = re.sub(r"\s*\(.*\)", "", bp.LEADERS[tag])
        res = []
        for attempt in range(4):
            try:
                res = ddg_images(name + " portrait photo")
            except Exception as e:
                res = []
                print(f"  {tag}: поиск не удался ({e}), жду", flush=True)
            if res:
                break
            time.sleep(60 * (attempt + 1))   # поиск ограничивает частоту — ждём и повторяем
        done = False
        for r in res[:25]:
            url, src = r.get("image", ""), r.get("url", "")
            w, h = int(r.get("width") or 0), int(r.get("height") or 0)
            if BAD.search(url) or BAD.search(src) or w < 280 or h < w * 1.05:
                continue
            try:
                img = Image.open(io.BytesIO(http(url, timeout=20))).convert("RGB")
            except Exception:
                continue
            if img.width < 200 or img.height < img.width:
                continue
            img = bp.sepia(bp.fit(img, 240, 320, 0.15))
            img.save(os.path.join(OUT, tag + ".jpg"), quality=84, optimize=True)
            credits["portraits/" + tag] = {"file": url, "page": src, "license": "неизвестна (поиск картинок)",
                                          "artist": "", "article": bp.LEADERS[tag], "temporary": True}
            bp.save_credits(credits)
            print(f"  {tag}: {urllib.parse.urlparse(src).netloc} — {r.get('title', '')[:60]}", flush=True)
            done = True
            break
        if not done:
            print(f"  {tag}: не найдено", flush=True)
        time.sleep(12)


if __name__ == "__main__":
    main()
