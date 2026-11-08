#!/usr/bin/env python3
"""Недостающие портреты — из Библиотеки Конгресса США и Europeana (когда
Викимедиа ограничивает частоту запросов). Временное оформление: картинки
помечаются "temporary" в assets/art_credits.json.

  python3 tools/fetch_portraits_alt.py [--only GER,USA] [--force]
"""
import argparse
import io
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import build_portraits as bp  # noqa: E402

OUT = os.path.join(bp.ROOT, "assets", "portraits")


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c)).lower()


def surname(title: str) -> str:
    t = re.sub(r"\s*\(.*\)", "", title)
    t = re.sub(r",.*", "", t)
    parts = [p for p in t.split() if not re.fullmatch(r"[IVX]+|of|the|\d+(st|nd|rd|th)|[A-Z]\.", p)]
    return parts[-1] if parts else t


def loc_candidates(q: str):
    d = bp.get("https://www.loc.gov/pictures/search/?" + urllib.parse.urlencode({"q": q, "fo": "json", "c": 12}))
    for r in d.get("results", []):
        img = r.get("image", {}) or {}
        url = img.get("full") or ""
        if not url:
            continue
        if url.startswith("//"):
            url = "https:" + url
        # «full» у части записей — миниатюра 150px; крупнее — …v.jpg / …r.jpg
        big = re.sub(r"_150px\.jpg$", "v.jpg", url)
        yield r.get("title", ""), [big, url], r.get("links", {}).get("item", ""), "Библиотека Конгресса США"


def europeana_candidates(q: str):
    d = bp.get("https://api.europeana.eu/record/v2/search.json?" + urllib.parse.urlencode(
        {"wskey": "api2demo", "query": q, "media": "true", "type": "IMAGE", "rows": 12, "profile": "rich"}))
    for it in d.get("items", []):
        urls = (it.get("edmIsShownBy") or []) + (it.get("edmPreview") or [])
        title = " ".join(it.get("title") or [])
        rights = " ".join(it.get("rights") or [])
        yield title, urls, it.get("guid", ""), "Europeana · " + rights


PORTRAIT = re.compile(r"portrait|bust|head-and-shoulders|half-length|portrat|portret|retrato|ritratto|bildnis")


def try_source(tag, title, gen, credits) -> bool:
    sn = norm(surname(title))
    for cap, urls, page, lic in gen:
        if sn not in norm(cap):
            continue
        # только портреты: групповые снимки, книги и документы не берём
        if not PORTRAIT.search(norm(cap)):
            continue
        for u in urls:
            try:
                data = bp.get(u, binary=True, tries=2)
                img = Image.open(io.BytesIO(data)).convert("RGB")
            except Exception:
                continue
            if img.width < 140 or img.height < 160:
                continue
            img = bp.sepia(bp.fit(img, 240, 320, 0.15))
            img.save(os.path.join(OUT, tag + ".jpg"), quality=84, optimize=True)
            credits["portraits/" + tag] = {"file": cap[:120], "page": page, "license": lic, "artist": "",
                                          "article": title, "temporary": True}
            bp.save_credits(credits)
            print(f"  {tag}: {lic.split(' ·')[0]} — {cap[:70]}", flush=True)
            return True
    return False


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
        title = bp.LEADERS[tag]
        name = re.sub(r"\s*\(.*\)", "", title)
        ok = False
        for gen in (lambda: loc_candidates(name), lambda: loc_candidates(name + " portrait"),
                    lambda: europeana_candidates(name), lambda: europeana_candidates(name + " portrait")):
            try:
                if try_source(tag, title, gen(), credits):
                    ok = True
                    break
            except Exception as e:
                print(f"  {tag}: ошибка источника ({e})", flush=True)
        if not ok:
            print(f"  {tag}: не найдено ({name})", flush=True)
        time.sleep(1)


if __name__ == "__main__":
    main()
