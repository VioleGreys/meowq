#!/usr/bin/env python3
"""Портреты лидеров и картинки событий из Википедии/Викисклада.

Берётся иллюстрация статьи английской Википедии (файл на Викискладе), его
лицензия проверяется по метаданным: допускаются общественное достояние, CC0,
CC BY и CC BY-SA (с указанием автора). Картинки тонируются в сепию, портреты
обрезаются до 3:4 (240×320), события — до 16:9 (640×360).

  python3 tools/build_portraits.py [--only portraits|events] [--force]

Результат: assets/portraits/<ТЕГ>.jpg, assets/events/<id>.jpg и
assets/art_credits.json (файл, автор, лицензия, ссылка) — для экрана «Авторы»
и assets/CREDITS.md. API Викимедиа ограничивает частоту запросов: запросы
идут пачками по 50, с паузой и повтором при ответе 429.
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

from PIL import Image, ImageOps, ImageEnhance

UA = "MeowqAssetBuilder/1.0 (https://github.com/VioleGreys/meowq; asset pipeline)"
API = "https://en.wikipedia.org/w/api.php"
ROOT = os.path.join(os.path.dirname(__file__), "..")

# лидер страны (тег из nations.json) -> статья английской Википедии
LEADERS = {
    "GER": "Adolf Hitler", "SOV": "Joseph Stalin", "ENG": "Stanley Baldwin", "FRA": "Pierre Laval",
    "ITA": "Benito Mussolini", "POL": "Ignacy Mościcki", "SPR": "Niceto Alcalá-Zamora",
    "POR": "António de Oliveira Salazar", "HOL": "Hendrikus Colijn", "BEL": "Paul van Zeeland",
    "LUX": "Joseph Bech", "SWI": "Albert Meyer (politician)", "AUS": "Kurt Schuschnigg",
    "CZE": "Edvard Beneš", "HUN": "Miklós Horthy", "ROM": "Carol II of Romania",
    "YUG": "Prince Paul of Yugoslavia", "BUL": "Boris III of Bulgaria", "GRE": "George II of Greece",
    "ALB": "Zog I", "TUR": "Mustafa Kemal Atatürk", "DEN": "Thorvald Stauning",
    "NOR": "Johan Nygaardsvold", "SWE": "Per Albin Hansson", "FIN": "Pehr Evind Svinhufvud",
    "EST": "Konstantin Päts", "LAT": "Kārlis Ulmanis", "LIT": "Antanas Smetona",
    "IRE": "Éamon de Valera", "ICE": "Hermann Jónasson", "DNZ": "Arthur Greiser",
    "EGY": "Fuad I of Egypt", "IRQ": "Ghazi of Iraq", "SAU": "Ibn Saud", "PER": "Reza Shah",
    "NSP": "Francisco Franco", "SLO": "Jozef Tiso", "VIC": "Philippe Pétain",
    "USA": "Franklin D. Roosevelt", "CAN": "William Lyon Mackenzie King", "MEX": "Lázaro Cárdenas",
    "GUA": "Jorge Ubico", "HON": "Tiburcio Carías Andino", "ELS": "Maximiliano Hernández Martínez",
    "NIC": "Juan Bautista Sacasa", "HAI": "Sténio Vincent", "DOM": "Rafael Trujillo",
    "COS": "Ricardo Jiménez Oreamuno", "PAN": "Harmodio Arias Madrid", "CUB": "José Agripino Barnet",
    "COL": "Alfonso López Pumarejo", "VEN": "Eleazar López Contreras", "ECU": "Federico Páez",
    "PRU": "Óscar R. Benavides", "BOL": "José Luis Tejada Sorzano", "PAR": "Eusebio Ayala",
    "CHL": "Arturo Alessandri", "ARG": "Agustín Pedro Justo", "URU": "Gabriel Terra",
    "BRA": "Getúlio Vargas", "JAP": "Keisuke Okada", "MAN": "Puyi", "CHI": "Chiang Kai-shek",
    "PRC": "Mao Zedong", "GXC": "Li Zongren", "YUN": "Long Yun", "SHX": "Yan Xishan",
    "XSM": "Ma Bufang", "SIK": "Sheng Shicai", "TIB": "5th Reting Rinpoche",
    "MON": "Peljidiin Genden", "TAN": "Salchak Toka", "SIA": "Phraya Phahonphonphayuhasena",
    "AFG": "Mohammad Zahir Shah", "NEP": "Juddha Shumsher Jung Bahadur Rana",
    "BHU": "Jigme Wangchuck", "RAJ": "Freeman Freeman-Thomas, 1st Marquess of Willingdon",
    "PHI": "Manuel L. Quezon", "YEM": "Yahya Muhammad Hamid ed-Din", "OMA": "Said bin Taimur",
    "AST": "Joseph Lyons", "NZL": "Michael Joseph Savage", "ETH": "Haile Selassie",
    "LIB": "Edwin Barclay", "SAF": "J. B. M. Hertzog",
}

# событие (id из events.json) -> статья
EVENTS = {
    "rhineland": "Remilitarization of the Rhineland",
    "spanish_war": "Spanish Civil War",
    "axis_offer": "Rome–Berlin Axis",
    "anschluss": "Anschluss",
    "munich": "Munich Agreement",
    "bohemia": "German occupation of Czechoslovakia",
    "memel": "1939 German ultimatum to Lithuania",
    "albania": "Italian invasion of Albania",
    "mr_pact": "Molotov–Ribbentrop Pact",
    "baltic_est": "Occupation of the Baltic states",
    "baltic_lat": "Occupation of Latvia by the Soviet Union (1940)",
    "baltic_lit": "Soviet occupation of Lithuania (1940)",
    "moscow_peace": "Winter War",
    "bessarabia": "Soviet occupation of Bessarabia and Northern Bukovina",
    "ethiopia_fall": "Second Italo-Ethiopian War",
}

OK_LICENSE = re.compile(r"public domain|^pd\b|pd-|cc0|cc by(-sa)? \d|cc-by(-sa)?-\d|cc by(-sa)?$", re.I)


def get(url: str, binary: bool = False, tries: int = 8):
    delay = 10.0
    for i in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                return data if binary else json.loads(data)
        except urllib.error.HTTPError as e:
            if e.code == 429 and i < tries - 1:
                wait = float(e.headers.get("Retry-After") or delay)
                print(f"  429 — жду {wait:.0f} с", file=sys.stderr)
                time.sleep(wait)
                delay = min(delay * 2, 120)
                continue
            raise
    raise RuntimeError("не удалось: " + url)


def api(params: dict) -> dict:
    params = dict(params, format="json", formatversion="2")
    return get(API + "?" + urllib.parse.urlencode(params))


def page_images(titles: list) -> dict:
    """статья -> имя файла иллюстрации (File:...)"""
    out = {}
    for i in range(0, len(titles), 50):
        chunk = titles[i:i + 50]
        d = api({"action": "query", "titles": "|".join(chunk), "prop": "pageimages",
                 "piprop": "name", "redirects": 1})
        q = d["query"]
        back = {}
        for n in q.get("normalized", []) + q.get("redirects", []):
            back[n["to"]] = back.get(n["from"], n["from"])
        for p in q["pages"]:
            src = back.get(p["title"], p["title"])
            while src in back:
                src = back[src]
            if "pageimage" in p:
                out[src] = "File:" + p["pageimage"]
        time.sleep(2)
    return out


def file_infos(files: list, width: int) -> dict:
    out = {}
    for i in range(0, len(files), 50):
        chunk = files[i:i + 50]
        d = api({"action": "query", "titles": "|".join(chunk), "prop": "imageinfo",
                 "iiprop": "url|extmetadata", "iiurlwidth": width})
        q = d["query"]
        back = {n["to"]: n["from"] for n in q.get("normalized", [])}
        for p in q["pages"]:
            if "imageinfo" not in p:
                continue
            ii = p["imageinfo"][0]
            m = ii.get("extmetadata", {})
            val = lambda k: re.sub(r"<[^>]+>", "", m.get(k, {}).get("value", "")).strip()
            out[back.get(p["title"], p["title"])] = {
                "thumb": ii.get("thumburl") or ii["url"],
                "page": ii.get("descriptionurl", ""),
                "license": val("LicenseShortName"),
                "artist": val("Artist")[:120],
            }
        time.sleep(2)
    return out


def sepia(img: Image.Image) -> Image.Image:
    g = ImageOps.grayscale(img)
    g = ImageOps.autocontrast(g, cutoff=1)
    s = ImageOps.colorize(g, black=(38, 28, 18), white=(246, 234, 208), mid=(150, 122, 88))
    return ImageEnhance.Contrast(s).enhance(1.05)


def fit(img: Image.Image, w: int, h: int, top_bias: float) -> Image.Image:
    """обрезка до пропорции w:h; лишняя высота срезается в основном снизу
    (у портретов лицо вверху), лишняя ширина — поровну"""
    iw, ih = img.size
    target = w / h
    if iw / ih > target:
        nw = int(ih * target)
        x0 = (iw - nw) // 2
        img = img.crop((x0, 0, x0 + nw, ih))
    else:
        nh = int(iw / target)
        y0 = int((ih - nh) * top_bias)
        img = img.crop((0, y0, iw, y0 + nh))
    return img.resize((w, h), Image.LANCZOS)


def build(kind: str, table: dict, out_dir: str, size: tuple, top_bias: float, force: bool, credits: dict):
    os.makedirs(out_dir, exist_ok=True)
    todo = {k: t for k, t in table.items() if force or not os.path.exists(os.path.join(out_dir, k + ".jpg"))}
    if not todo:
        print(f"{kind}: всё уже есть")
        return
    imgs = page_images(list(todo.values()))
    infos = file_infos(sorted(set(imgs.values())), size[0] * 2)
    for key, title in todo.items():
        f = imgs.get(title)
        info = infos.get(f) if f else None
        if not info:
            print(f"  {key}: нет иллюстрации у «{title}»")
            continue
        lic = info["license"]
        if not OK_LICENSE.search(lic):
            print(f"  {key}: пропуск — лицензия «{lic}» ({f})")
            continue
        try:
            data = get(info["thumb"], binary=True)
        except Exception as e:
            print(f"  {key}: не скачалось ({e})")
            continue
        img = Image.open(io.BytesIO(data)).convert("RGB")
        img = sepia(fit(img, size[0], size[1], top_bias))
        img.save(os.path.join(out_dir, key + ".jpg"), quality=84, optimize=True)
        credits[f"{kind}/{key}"] = {"file": f, "page": info["page"], "license": lic, "artist": info["artist"],
                                    "article": title}
        print(f"  {key}: {f} — {lic}")
        time.sleep(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["portraits", "events"])
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    cpath = os.path.join(ROOT, "assets", "art_credits.json")
    credits = json.load(open(cpath, encoding="utf-8")) if os.path.exists(cpath) else {}
    if a.only in (None, "portraits"):
        build("portraits", LEADERS, os.path.join(ROOT, "assets", "portraits"), (240, 320), 0.15, a.force, credits)
    if a.only in (None, "events"):
        build("events", EVENTS, os.path.join(ROOT, "assets", "events"), (640, 360), 0.35, a.force, credits)
    with open(cpath, "w", encoding="utf-8") as fh:
        json.dump(dict(sorted(credits.items())), fh, ensure_ascii=False, indent=1)
    print("готово:", len(credits), "картинок в", cpath)


if __name__ == "__main__":
    main()
