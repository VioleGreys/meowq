#!/usr/bin/env python3
"""Сборка исторической карты Европы 1 января 1936 г. для игры.

Запускается на ПК, не на телефоне. Результат кладётся в data/europe1936/ и
коммитится — игра только читает готовые файлы.

Источник: Natural Earth (общественное достояние), https://www.naturalearthdata.com
  ne_10m_admin_1_states_provinces, ne_10m_populated_places, ne_10m_lakes,
  ne_10m_rivers_lake_centerlines, ne_10m_geography_regions_polys,
  ne_10m_geography_marine_polys (GeoJSON из github.com/nvkelso/natural-earth-vector)

Как собираются границы 1936 г.:
  1. каждая область (admin-1) современной страны получает государство 1936 г.
     по таблице ADM0_TAG / ADM1_TAG;
  2. поверх накладываются многоугольники OVERRIDES (долгота, широта) для
     областей, которые в 1936 г. были поделены (восток Германии, Восточная
     Пруссия, Данциг, Карельский перешеек, Бессарабия, Истрия и т.д.).
     Многоугольник меняет только пиксели перечисленных «старых» государств,
     поэтому его можно рисовать с запасом в сторону соседей.
Границы приблизительные — с точностью, достаточной для игры.

Зависимости: python3, numpy, scipy, pillow.
  python3 tools/build_map.py --ne путь/к/geojson
"""

import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.spatial import cKDTree

# --- Окно карты и проекция ----------------------------------------------------

LON0, LAT0 = 15.0, 50.0          # центр азимутальной равновеликой проекции Ламберта
R_KM = 6371.0
WIDTH = 2048
# окно в км (x вправо, y вверх), подобрано так, чтобы вошли Исландия, Урал,
# Северная Африка и Ближний Восток
X_MIN, X_MAX = -2750.0, 3750.0
Y_MIN, Y_MAX = -2350.0, 2450.0
HEIGHT = int(round(WIDTH * (Y_MAX - Y_MIN) / (X_MAX - X_MIN)))
KM_PER_PX = (X_MAX - X_MIN) / WIDTH

SEED = 1936


def project(lon, lat):
    lon = np.radians(np.asarray(lon, dtype=np.float64))
    lat = np.radians(np.asarray(lat, dtype=np.float64))
    l0, p0 = math.radians(LON0), math.radians(LAT0)
    k = np.sqrt(2.0 / (1.0 + math.sin(p0) * np.sin(lat) + math.cos(p0) * np.cos(lat) * np.cos(lon - l0)))
    x = R_KM * k * np.cos(lat) * np.sin(lon - l0)
    y = R_KM * k * (math.cos(p0) * np.sin(lat) - math.sin(p0) * np.cos(lat) * np.cos(lon - l0))
    px = (x - X_MIN) / KM_PER_PX
    py = (Y_MAX - y) / KM_PER_PX
    return px, py


def unproject(px, py):
    x = np.asarray(px, dtype=np.float64) * KM_PER_PX + X_MIN
    y = Y_MAX - np.asarray(py, dtype=np.float64) * KM_PER_PX
    x /= R_KM
    y /= R_KM
    rho = np.sqrt(x * x + y * y)
    c = 2.0 * np.arcsin(np.clip(rho / 2.0, -1, 1))
    l0, p0 = math.radians(LON0), math.radians(LAT0)
    with np.errstate(invalid="ignore", divide="ignore"):
        lat = np.arcsin(np.cos(c) * math.sin(p0) + np.where(rho > 0, y * np.sin(c) * math.cos(p0) / rho, 0))
        lon = l0 + np.arctan2(x * np.sin(c), rho * math.cos(p0) * np.cos(c) - y * math.sin(p0) * np.sin(c))
    return np.degrees(lon), np.degrees(lat)


# --- Государства 1936 г. -------------------------------------------------------
# tag: (название, цвет RGB, столица (долгота, широта))
NATIONS = {
    "GER": ("Германия", (112, 120, 128), (13.40, 52.52)),
    "SOV": ("СССР", (176, 58, 52), (37.62, 55.75)),
    "ENG": ("Великобритания", (196, 70, 92), (-0.13, 51.51)),
    "FRA": ("Франция", (70, 108, 184), (2.35, 48.86)),
    "ITA": ("Италия", (92, 150, 88), (12.50, 41.90)),
    "POL": ("Польша", (198, 126, 140), (21.01, 52.23)),
    "SPR": ("Испания", (214, 172, 70), (-3.70, 40.42)),
    "POR": ("Португалия", (60, 132, 104), (-9.14, 38.72)),
    "HOL": ("Нидерланды", (226, 140, 64), (4.90, 52.37)),
    "BEL": ("Бельгия", (202, 182, 92), (4.35, 50.85)),
    "LUX": ("Люксембург", (120, 170, 196), (6.13, 49.61)),
    "SWI": ("Швейцария", (176, 64, 64), (7.45, 46.95)),
    "AUS": ("Австрия", (222, 222, 210), (16.37, 48.21)),
    "CZE": ("Чехословакия", (88, 156, 160), (14.42, 50.09)),
    "HUN": ("Венгрия", (170, 120, 80), (19.04, 47.50)),
    "ROM": ("Румыния", (206, 190, 96), (26.10, 44.43)),
    "YUG": ("Югославия", (100, 112, 166), (20.46, 44.79)),
    "BUL": ("Болгария", (96, 140, 70), (23.32, 42.70)),
    "GRE": ("Греция", (110, 170, 210), (23.73, 37.98)),
    "ALB": ("Албания", (150, 72, 64), (19.82, 41.33)),
    "TUR": ("Турция", (150, 170, 120), (32.86, 39.93)),
    "DEN": ("Дания", (160, 92, 72), (12.57, 55.68)),
    "NOR": ("Норвегия", (148, 96, 112), (10.75, 59.91)),
    "SWE": ("Швеция", (86, 128, 196), (18.07, 59.33)),
    "FIN": ("Финляндия", (226, 226, 236), (24.94, 60.17)),
    "EST": ("Эстония", (76, 116, 150), (24.75, 59.44)),
    "LAT": ("Латвия", (138, 82, 92), (24.11, 56.95)),
    "LIT": ("Литва", (196, 196, 96), (23.90, 54.90)),   # столица — Каунас
    "IRE": ("Ирландия", (100, 176, 110), (-6.26, 53.35)),
    "ICE": ("Исландия", (140, 160, 190), (-21.90, 64.15)),
    "DNZ": ("Данциг", (208, 196, 170), (18.65, 54.35)),
    "EGY": ("Египет", (214, 196, 128), (31.24, 30.04)),
    "IRQ": ("Ирак", (150, 132, 92), (44.37, 33.31)),
    "SAU": ("Саудовская Аравия", (120, 156, 92), (46.72, 24.69)),
    "PER": ("Иран", (110, 160, 140), (51.39, 35.69)),
}

# Современная страна -> государство 1936 г. (колонии и мандаты пока принадлежат
# метрополии; марионетки и доминионы — этап 3).
ADM0_TAG = {
    "DEU": "GER", "AUT": "AUS", "CZE": "CZE", "SVK": "CZE", "POL": "POL",
    "RUS": "SOV", "BLR": "SOV", "UKR": "SOV", "GEO": "SOV", "ARM": "SOV", "AZE": "SOV",
    "KAZ": "SOV", "TKM": "SOV", "UZB": "SOV",
    "LTU": "LIT", "LVA": "LAT", "EST": "EST", "FIN": "FIN", "ALD": "FIN",
    "ROU": "ROM", "MDA": "ROM", "BGR": "BUL", "HUN": "HUN",
    "SRB": "YUG", "MNE": "YUG", "BIH": "YUG", "HRV": "YUG", "SVN": "YUG", "MKD": "YUG", "KOS": "YUG",
    "ITA": "ITA", "SMR": "ITA", "VAT": "ITA", "ALB": "ALB", "GRC": "GRE", "TUR": "TUR",
    "FRA": "FRA", "MCO": "FRA", "AND": "SPR", "BEL": "BEL", "NLD": "HOL", "LUX": "LUX",
    "CHE": "SWI", "LIE": "SWI", "ESP": "SPR", "PRT": "POR",
    "GBR": "ENG", "IMN": "ENG", "JEY": "ENG", "GGY": "ENG", "GIB": "ENG", "IRL": "IRE",
    "DNK": "DEN", "FRO": "DEN", "NOR": "NOR", "SWE": "SWE", "ISL": "ICE",
    "MLT": "ENG", "CYP": "ENG", "CYN": "ENG", "ESB": "ENG", "WSB": "ENG",
    "MAR": "FRA", "DZA": "FRA", "TUN": "FRA", "LBY": "ITA", "EGY": "EGY",
    "SYR": "FRA", "LBN": "FRA", "ISR": "ENG", "PSX": "ENG", "PSE": "ENG", "JOR": "ENG",
    "KWT": "ENG", "IRQ": "IRQ", "SAU": "SAU", "IRN": "PER",
}

# Отдельные области (adm0, name) -> государство 1936 г.
ADM1_TAG = {
    ("RUS", "Kaliningrad"): "GER",
    ("UKR", "L'viv"): "POL", ("UKR", "Volyn"): "POL", ("UKR", "Rivne"): "POL",
    ("UKR", "Ternopil'"): "POL", ("UKR", "Ivano-Frankivs'k"): "POL",
    ("UKR", "Transcarpathia"): "CZE", ("UKR", "Chernivtsi"): "ROM",
    ("BLR", "Grodno"): "POL", ("BLR", "Brest"): "POL",
    ("LTU", "Vilniaus"): "POL",
    ("MDA", "Stîngă Nistrului"): "SOV", ("MDA", "Transnistria"): "SOV",
    ("MDA", "Grigoriopol"): "SOV", ("MDA", "Camenca"): "SOV",
    ("BGR", "Dobrich"): "ROM", ("BGR", "Silistra"): "ROM",
    ("HRV", "Istarska"): "ITA",
    ("TUR", "Hatay"): "FRA",
    ("MAR", "Tanger - Tétouan"): "SPR",
}

# Многоугольники (долгота, широта): новое государство, какие «старые» меняет.
OVERRIDES = [
    # Восток Германии (Померания, Силезия) — граница 1936 г. с Польшей
    ("GER", ["POL"], [(13.5, 54.95), (17.95, 54.9), (17.95, 54.83), (17.6, 54.4), (17.4, 53.75),
                      (17.3, 53.3), (16.9, 53.05), (16.2, 52.85), (15.95, 52.6), (15.9, 52.25),
                      (16.2, 51.95), (16.35, 51.75), (16.9, 51.55), (17.5, 51.45), (17.85, 51.25),
                      (18.15, 51.1), (18.55, 50.8), (18.7, 50.62), (18.85, 50.45), (18.98, 50.38),
                      (18.85, 50.32), (18.7, 50.25), (18.6, 50.15), (18.35, 50.0), (18.3, 49.85),
                      (14.0, 50.8)]),
    # Восточная Пруссия (польская часть)
    ("GER", ["POL"], [(18.9, 54.5), (18.85, 54.05), (18.9, 53.75), (19.1, 53.6), (19.6, 53.55),
                      (19.9, 53.45), (20.3, 53.35), (20.7, 53.3), (21.4, 53.3), (21.9, 53.45),
                      (22.6, 53.55), (22.75, 53.95), (22.75, 54.35), (22.9, 54.45), (22.9, 55.3),
                      (18.9, 55.3)]),
    # Вольный город Данциг
    ("DNZ", ["POL", "GER"], [(18.47, 54.43), (18.5, 54.3), (18.6, 54.2), (18.75, 54.1), (19.15, 54.12),
                             (19.35, 54.3), (19.25, 54.38), (18.95, 54.38), (18.6, 54.47)]),
    # Восток Польши в Белоруссии (западнее границы 1921 г.)
    ("POL", ["SOV"], [(23.0, 56.2), (28.15, 56.0), (28.0, 55.5), (27.9, 55.1), (27.6, 54.6),
                      (27.2, 54.25), (26.95, 53.7), (27.0, 53.35), (27.2, 53.0), (27.5, 52.3),
                      (27.6, 51.6), (23.0, 51.6)]),
    # Финляндия: Карельский перешеек и Приладожье
    ("FIN", ["SOV"], [(27.5, 60.3), (29.95, 60.15), (30.6, 60.45), (31.15, 60.6), (32.05, 61.25),
                      (31.9, 61.6), (31.55, 62.1), (31.3, 62.6), (30.9, 63.0), (29.5, 63.3), (28.5, 61.5)]),
    # Финляндия: Петсамо
    ("FIN", ["SOV"], [(28.9, 68.9), (30.9, 69.0), (31.6, 69.7), (32.1, 69.95), (28.9, 70.1)]),
    # Эстония: Печоры и Ивангород; Латвия: Абрене
    ("EST", ["SOV"], [(27.3, 57.65), (28.1, 57.65), (28.15, 58.0), (27.6, 58.1), (28.0, 59.2),
                      (28.25, 59.45), (27.8, 59.5)]),
    ("LAT", ["SOV"], [(27.6, 56.9), (28.2, 56.9), (28.2, 57.25), (27.6, 57.3)]),
    # Румыния: Буджак (юг Бессарабии)
    ("ROM", ["SOV"], [(28.2, 46.65), (29.6, 46.6), (30.25, 46.2), (30.0, 45.6), (29.75, 45.15), (28.2, 45.15)]),
    # Италия: Истрия, Словенское приморье, Фиуме
    ("ITA", ["YUG"], [(13.3, 46.6), (13.6, 46.55), (13.85, 46.5), (14.0, 46.25), (14.15, 46.0),
                      (14.35, 45.75), (14.45, 45.5), (14.48, 45.32), (14.2, 44.9), (13.9, 44.75), (13.3, 45.0)]),
    # Италия: Додеканес
    ("ITA", ["GRE"], [(26.6, 35.35), (28.6, 35.35), (28.6, 37.4), (26.6, 37.4)]),
]

# Группы для плотности провинций (множитель площади провинции)
SPARSE_ADM0 = {"MAR": 3.0, "DZA": 3.5, "TUN": 2.5, "LBY": 4.0, "EGY": 3.5, "ISR": 2.0, "PSX": 2.0,
               "JOR": 3.5, "LBN": 2.0, "SYR": 3.0, "IRQ": 3.5, "SAU": 5.0, "KWT": 4.0, "IRN": 3.5,
               "TKM": 4.0, "KAZ": 4.0, "UZB": 4.0, "TUR": 1.7, "GEO": 1.6, "ARM": 1.6, "AZE": 1.8,
               "ISL": 3.0, "RUS": 2.0, "UKR": 1.3, "BLR": 1.3}

MOUNTAIN_HEIGHT = {"ALPS": 1.0, "CAUCASUS MTS.": 1.0, "PYRENEES": 0.85, "HAUT ATLAS": 0.9,
                   "KJØLEN MOUNTAINS": 0.75, "CARPATHIAN MOUNTAINS": 0.65, "Transylvanian Alps": 0.75,
                   "Tatra Mts.": 0.8, "ZAGROS MOUNTAINS": 0.85, "ELBURZ MTS.": 0.9, "Taurus Mts.": 0.8,
                   "PONTIC MOUNTAINS": 0.75, "Lesser Caucasus": 0.8, "Dinaric Alps": 0.6,
                   "APPENNINI": 0.55, "Balkan Mts.": 0.55, "Pindus Mts.": 0.65, "ATLAS MOUNTAINS": 0.75,
                   "S. Nevada": 0.75, "Cord. Cantábrica": 0.65, "URAL MOUNTAINS": 0.45}

# Названия городов на 1936 г. (по английскому названию Natural Earth)
CITY_1936 = {
    "Saint Petersburg": "Ленинград", "Volgograd": "Сталинград", "Donetsk": "Сталино",
    "Samara": "Куйбышев", "Nizhny Novgorod": "Горький", "Tver": "Калинин",
    "Yekaterinburg": "Свердловск", "Dnipro": "Днепропетровск", "Luhansk": "Ворошиловград",
    "Kaliningrad": "Кёнигсберг", "Gdańsk": "Данциг", "Gdansk": "Данциг", "Szczecin": "Штеттин",
    "Wrocław": "Бреслау", "Wroclaw": "Бреслау", "Olsztyn": "Алленштайн", "Opole": "Оппельн",
    "Koszalin": "Кёзлин", "Zielona Góra": "Грюнберг", "Gorzów Wielkopolski": "Ландсберг",
    "Elbląg": "Эльбинг", "Legnica": "Лигниц", "Wałbrzych": "Вальденбург", "Gliwice": "Глейвиц",
    "Słupsk": "Штольп", "Klaipėda": "Мемель", "Klaipeda": "Мемель", "Vilnius": "Вильно",
    "Lviv": "Львов", "Ivano-Frankivsk": "Станиславов", "Chișinău": "Кишинёв", "Chisinau": "Кишинёв",
    "Rijeka": "Фиуме", "Pula": "Пола", "Koper": "Каподистрия", "Istanbul": "Стамбул",
    "Tbilisi": "Тифлис", "Kirovohrad": "Кирово", "Kropyvnytskyi": "Кирово",
    "Zaporizhzhia": "Запорожье", "Kharkiv": "Харьков", "Kyiv": "Киев", "Kiev": "Киев",
    "Odesa": "Одесса", "Mykolaiv": "Николаев", "Khmelnytskyi": "Проскуров",
    "Vladikavkaz": "Орджоникидзе", "Cherkessk": "Баталпашинск", "Makhachkala": "Махачкала",
    "Izhevsk": "Ижевск", "Togliatti": "Ставрополь-на-Волге", "Naberezhnye Chelny": "Челны",
    "Podgorica": "Подгорица", "Ústí nad Labem": "Усти-над-Лабем",
}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def rings_of(geom):
    if geom is None:
        return []
    if geom["type"] == "Polygon":
        return [geom["coordinates"][0]]
    if geom["type"] == "MultiPolygon":
        return [p[0] for p in geom["coordinates"]]
    return []


def lines_of(geom):
    if geom is None:
        return []
    if geom["type"] == "LineString":
        return [geom["coordinates"]]
    if geom["type"] == "MultiLineString":
        return geom["coordinates"]
    return []


def poly_px(ring):
    arr = np.asarray(ring, dtype=np.float64)
    x, y = project(arr[:, 0], arr[:, 1])
    return list(zip(x.tolist(), y.tolist()))


def in_window(ring):
    arr = np.asarray(ring, dtype=np.float64)
    x, y = project(arr[:, 0], arr[:, 1])
    return x.max() >= -50 and x.min() <= WIDTH + 50 and y.max() >= -50 and y.min() <= HEIGHT + 50


def kmeans_regions(coords, weights_area, rng, iters=6):
    """Делит пиксели связной области на провинции. coords — (n,2), weights_area —
    целевая площадь провинции (в пикселях) для каждого пикселя."""
    n = coords.shape[0]
    density = 1.0 / weights_area
    k = max(1, int(round(density.sum())))
    if k == 1:
        return np.zeros(n, dtype=np.int32)
    p = density / density.sum()
    seeds = coords[rng.choice(n, size=k, replace=False, p=p)].astype(np.float64)
    sample = coords if n <= 60000 else coords[rng.choice(n, 60000, replace=False)]
    s_dens = density if n <= 60000 else None
    for _ in range(iters):
        tree = cKDTree(seeds)
        _, lab = tree.query(sample)
        cnt = np.bincount(lab, minlength=k).astype(np.float64)
        sx = np.bincount(lab, weights=sample[:, 0], minlength=k)
        sy = np.bincount(lab, weights=sample[:, 1], minlength=k)
        ok = cnt > 0
        seeds[ok, 0] = sx[ok] / cnt[ok]
        seeds[ok, 1] = sy[ok] / cnt[ok]
    _, lab = cKDTree(seeds).query(coords)
    # Убираем пустые метки
    uniq, lab = np.unique(lab, return_inverse=True)
    return lab.astype(np.int32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ne", required=True, help="папка с GeoJSON Natural Earth")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "europe1936"))
    ap.add_argument("--preview", default="", help="сохранить PNG-превью сюда")
    args = ap.parse_args()
    ne = args.ne
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    rng = np.random.default_rng(SEED)
    print(f"Карта {WIDTH}x{HEIGHT}, {KM_PER_PX:.2f} км/пиксель")

    tags = list(NATIONS.keys())
    tag_idx = {t: i for i, t in enumerate(tags)}

    # --- 1. Растр областей admin-1 ---------------------------------------------
    adm = load(os.path.join(ne, "ne_10m_admin_1_states_provinces.geojson"))["features"]
    feats = []
    for f in adm:
        p = f["properties"]
        a0 = p["adm0_a3"]
        if a0 not in ADM0_TAG:
            continue
        rings = [r for r in rings_of(f["geometry"]) if in_window(r)]
        if not rings:
            continue
        tag = ADM1_TAG.get((a0, p["name"]), ADM0_TAG[a0])
        feats.append((p.get("area_sqkm") or 0, a0, p, rings, tag))
    feats.sort(key=lambda t: -t[0])  # крупные первыми, анклавы поверх
    region_img = Image.new("I", (WIDTH, HEIGHT), 0)
    draw = ImageDraw.Draw(region_img)
    region_info = [None]
    for area, a0, p, rings, tag in feats:
        rid = len(region_info)
        region_info.append({"adm0": a0, "name_ru": p.get("name_ru") or p["name"], "tag": tag})
        for r in rings:
            pts = poly_px(r)
            if len(pts) >= 3:
                draw.polygon(pts, fill=rid)
    region = np.array(region_img, dtype=np.int32)

    # Крупные озёра — вода
    lakes = load(os.path.join(ne, "ne_10m_lakes.geojson"))["features"]
    lake_img = Image.new("L", (WIDTH, HEIGHT), 0)
    ld = ImageDraw.Draw(lake_img)
    for f in lakes:
        if (f["properties"].get("scalerank") or 9) <= 4:
            for r in rings_of(f["geometry"]):
                if in_window(r):
                    ld.polygon(poly_px(r), fill=255)
    region[np.array(lake_img) > 0] = 0

    land = region > 0
    owner = np.full(region.shape, -1, dtype=np.int32)
    reg_tag = np.array([-1] + [tag_idx[r["tag"]] for r in region_info[1:]], dtype=np.int32)
    owner[land] = reg_tag[region[land]]

    # --- 2. Поправки 1936 г. ---------------------------------------------------
    for tag, from_tags, poly in OVERRIDES:
        m_img = Image.new("L", (WIDTH, HEIGHT), 0)
        arr = np.asarray(poly)
        x, y = project(arr[:, 0], arr[:, 1])
        ImageDraw.Draw(m_img).polygon(list(zip(x.tolist(), y.tolist())), fill=255)
        m = np.array(m_img) > 0
        src = np.isin(owner, [tag_idx[t] for t in from_tags])
        owner[m & src] = tag_idx[tag]

    # Убираем крошечные островки (< 6 пикселей)
    lab, n = ndimage.label(land)
    sizes = ndimage.sum(land, lab, index=np.arange(1, n + 1))
    tiny = np.zeros(n + 1, bool)
    tiny[1:] = sizes < 6
    land &= ~tiny[lab]
    owner[~land] = -1
    region[~land] = 0

    # --- 3. Горы, рельеф, реки -------------------------------------------------
    geo = load(os.path.join(ne, "ne_10m_geography_regions_polys.geojson"))["features"]
    mount = np.zeros(region.shape, np.float32)
    for f in geo:
        p = f["properties"]
        if "Range" not in str(p.get("FEATURECLA")):
            continue
        name = p.get("NAME") or ""
        hgt = MOUNTAIN_HEIGHT.get(name, 0.4 if (p.get("SCALERANK") or 9) <= 5 else 0.0)
        if hgt <= 0:
            continue
        for r in rings_of(f["geometry"]):
            if not in_window(r):
                continue
            img = Image.new("L", (WIDTH, HEIGHT), 0)
            ImageDraw.Draw(img).polygon(poly_px(r), fill=255)
            m = np.array(img) > 0
            mount[m] = np.maximum(mount[m], hgt)
    noise = ndimage.gaussian_filter(rng.standard_normal(region.shape).astype(np.float32), 6) * 6.0
    noise2 = ndimage.gaussian_filter(rng.standard_normal(region.shape).astype(np.float32), 2) * 1.5
    mount_s = ndimage.gaussian_filter(mount, 5)
    land_h = np.clip(mount_s * (0.75 + 0.5 * np.clip(noise + 0.5, 0, 1)) + 0.05 + 0.03 * noise2, 0, 1)
    coast_dist = ndimage.distance_transform_edt(~land)
    sea_depth = np.clip(coast_dist / 45.0, 0, 1)
    height = np.where(land, 0.5 + 0.5 * land_h, 0.5 - 0.45 * sea_depth)

    rivers_img = Image.new("L", (WIDTH, HEIGHT), 0)
    rd = ImageDraw.Draw(rivers_img)
    for f in load(os.path.join(ne, "ne_10m_rivers_lake_centerlines.geojson"))["features"]:
        sr = f["properties"].get("scalerank") or 9
        if sr > 6:
            continue
        for line in lines_of(f["geometry"]):
            arr = np.asarray(line)
            x, y = project(arr[:, 0], arr[:, 1])
            pts = list(zip(x.tolist(), y.tolist()))
            if len(pts) >= 2:
                rd.line(pts, fill=255 if sr <= 4 else 170, width=2 if sr <= 3 else 1)
    rivers = np.array(rivers_img)
    rivers[~land] = 0

    # --- 4. Провинции суши ------------------------------------------------------
    py_all, px_all = np.mgrid[0:HEIGHT, 0:WIDTH]
    lon_all, lat_all = unproject(px_all + 0.5, py_all + 0.5)
    base_area = 4600.0 / (KM_PER_PX ** 2)   # ~4600 км² на провинцию в Европе
    adm0_mult = np.ones(len(region_info), np.float32)
    for i, r in enumerate(region_info[1:], start=1):
        adm0_mult[i] = SPARSE_ADM0.get(r["adm0"], 1.0)
    area_px = base_area * adm0_mult[region]
    area_px = np.where(lat_all > 63.5, area_px * 2.0, area_px)
    area_px = np.where((lon_all > 45) & (lat_all > 50), area_px * 1.6, area_px)

    prov = np.full(region.shape, -1, np.int32)
    next_id = 0
    for t in range(len(tags)):
        mask = owner == t
        if not mask.any():
            continue
        lab, n = ndimage.label(mask)
        objs = ndimage.find_objects(lab)
        for ci in range(n):
            sl = objs[ci]
            sub = lab[sl] == ci + 1
            ys, xs = np.nonzero(sub)
            ys = ys + sl[0].start
            xs = xs + sl[1].start
            coords = np.stack([xs, ys], 1).astype(np.float64)
            labels = kmeans_regions(coords, area_px[ys, xs], rng)
            prov[ys, xs] = labels + next_id
            next_id += int(labels.max()) + 1
    n_land = next_id
    print(f"Провинций суши: {n_land}")

    # --- 5. Морские зоны --------------------------------------------------------
    water = ~land
    lab, n = ndimage.label(water)
    sea_area = 70000.0 / (KM_PER_PX ** 2)   # ~70 тыс. км² на морскую зону
    for ci in range(1, n + 1):
        ys, xs = np.nonzero(lab == ci)
        if ys.size < 30:   # крошечные внутренние водоёмы — к соседней суше
            continue
        coords = np.stack([xs, ys], 1).astype(np.float64)
        labels = kmeans_regions(coords, np.full(ys.size, sea_area), rng, iters=8)
        prov[ys, xs] = labels + next_id
        next_id += int(labels.max()) + 1
    # оставшиеся пиксели (крошечная вода) — ближайшей провинции
    missing = prov < 0
    if missing.any():
        idx = ndimage.distance_transform_edt(missing, return_distances=False, return_indices=True)
        prov = prov[idx[0], idx[1]]
    n_prov = next_id
    print(f"Морских зон: {n_prov - n_land}")

    # --- 6. Статистика провинций ------------------------------------------------
    flat = prov.ravel()
    counts = np.bincount(flat, minlength=n_prov)
    cx = np.bincount(flat, weights=px_all.ravel() + 0.5, minlength=n_prov) / np.maximum(counts, 1)
    cy = np.bincount(flat, weights=py_all.ravel() + 0.5, minlength=n_prov) / np.maximum(counts, 1)
    p_owner = np.full(n_prov, -1, np.int32)
    p_owner[flat[land.ravel()]] = owner.ravel()[land.ravel()]
    p_land = np.zeros(n_prov, np.int8)
    p_land[:n_land] = 1
    # регион (для названий) по центральному пикселю
    p_region = np.zeros(n_prov, np.int32)
    reg_flat = region.ravel()
    # самая частая область внутри провинции
    pairs = flat[land.ravel()].astype(np.int64) * (len(region_info) + 1) + reg_flat[land.ravel()]
    up, upc = np.unique(pairs, return_counts=True)
    best = {}
    for key, c in zip(up.tolist(), upc.tolist()):
        pid, rid = divmod(key, len(region_info) + 1)
        if c > best.get(pid, (0, 0))[0]:
            best[pid] = (c, rid)
    for pid, (c, rid) in best.items():
        p_region[pid] = rid
    mount_mean = ndimage.mean(mount, labels=prov, index=np.arange(n_prov))

    # соседство
    a = prov[:, :-1].ravel(); b = prov[:, 1:].ravel()
    c = prov[:-1, :].ravel(); d = prov[1:, :].ravel()
    e1 = np.stack([np.concatenate([a, c]), np.concatenate([b, d])], 1)
    e1 = e1[e1[:, 0] != e1[:, 1]]
    e1.sort(1)
    edges = np.unique(e1, axis=0)

    # проливы
    straits = [((12.60, 55.68), (13.00, 55.60)), ((15.58, 38.20), (15.65, 38.05)),
               ((26.40, 40.20), (26.40, 40.05)), ((29.00, 41.10), (29.05, 40.98)),
               ((36.45, 45.32), (36.70, 45.30)), ((-5.40, 36.10), (-5.40, 35.85)),
               ((11.00, 55.40), (10.40, 55.35)), ((9.85, 55.40), (9.60, 55.50)),
               ((9.20, 41.40), (9.20, 41.20)), ((10.30, 57.10), (11.00, 57.30))]
    land_idx = ndimage.distance_transform_edt(~land, return_distances=False, return_indices=True)
    extra = []
    for p1, p2 in straits:
        ids = []
        for lon, lat in (p1, p2):
            x, y = project(lon, lat)
            xi, yi = int(np.clip(x, 0, WIDTH - 1)), int(np.clip(y, 0, HEIGHT - 1))
            ly, lx = land_idx[0][yi, xi], land_idx[1][yi, xi]
            ids.append(int(prov[ly, lx]))
        if ids[0] != ids[1]:
            extra.append(sorted(ids))
    adj = [[] for _ in range(n_prov)]
    for u, v in edges.tolist():
        adj[u].append(v)
        adj[v].append(u)
    for u, v in extra:
        if v not in adj[u]:
            adj[u].append(v)
            adj[v].append(u)

    # --- 7. Города, названия, очки победы ---------------------------------------
    places = load(os.path.join(ne, "ne_10m_populated_places.geojson"))["features"]
    city_best = {}
    city_pop = np.zeros(n_prov)
    for f in places:
        p = f["properties"]
        lon, lat = f["geometry"]["coordinates"][:2]
        x, y = project(lon, lat)
        xi, yi = int(x), int(y)
        if not (0 <= xi < WIDTH and 0 <= yi < HEIGHT) or not land[yi, xi]:
            continue
        pid = int(prov[yi, xi])
        pop = float(p.get("POP_MAX") or 0)
        city_pop[pid] += pop
        name = CITY_1936.get(p.get("NAME_EN") or "", CITY_1936.get(p.get("NAME") or "", p.get("NAME_RU") or p.get("NAME")))
        if pop > city_best.get(pid, (-1, ""))[0]:
            city_best[pid] = (pop, name)

    marine = load(os.path.join(ne, "ne_10m_geography_marine_polys.geojson"))["features"]
    marine_sorted = sorted(marine, key=lambda f: (f["properties"].get("scalerank") or 0), reverse=True)
    sea_img = Image.new("I", (WIDTH, HEIGHT), 0)
    sd = ImageDraw.Draw(sea_img)
    marine_names = [""]
    for f in marine_sorted:
        nm = f["properties"].get("name_ru") or f["properties"].get("name") or ""
        for r in rings_of(f["geometry"]):
            if in_window(r):
                sd.polygon(poly_px(r), fill=len(marine_names))
        marine_names.append(nm)
    sea_lab = np.array(sea_img)

    capitals = {}
    for t, (nm, col, (lon, lat)) in NATIONS.items():
        x, y = project(lon, lat)
        xi, yi = int(np.clip(x, 0, WIDTH - 1)), int(np.clip(y, 0, HEIGHT - 1))
        ly, lx = land_idx[0][yi, xi], land_idx[1][yi, xi]
        capitals[t] = int(prov[ly, lx])

    used = {}
    provinces = []
    for i in range(n_prov):
        xi, yi = int(cx[i]), int(cy[i])
        lon, lat = unproject(cx[i], cy[i])
        lon, lat = float(lon), float(lat)
        if p_land[i]:
            r = region_info[p_region[i]] if p_region[i] > 0 else {"name_ru": "?", "adm0": ""}
            pop, cname = city_best.get(i, (0, ""))
            name = cname if cname else r["name_ru"]
            used[name] = used.get(name, 0) + 1
            mm = float(mount_mean[i])
            terrain = 0
            if mm > 0.55:
                terrain = 3
            elif mm > 0.25:
                terrain = 2
            elif r["adm0"] in SPARSE_ADM0 and SPARSE_ADM0[r["adm0"]] >= 2.5 and lat < 34.5:
                terrain = 6   # пустыня
            elif 23.5 < lon < 30.5 and 51.3 < lat < 52.5:
                terrain = 7   # Полесье — болота
            else:
                fval = math.sin(lon * 1.7) * math.cos(lat * 2.3) + math.sin(lon * 0.6 + lat * 0.9)
                if lat > 57 or (lat > 52 and lon > 30):
                    fval += 0.9
                if fval > 1.0:
                    terrain = 1
            total_pop = city_pop[i]
            if pop >= 400000:
                terrain = 4
            vp = 10 if pop >= 1_000_000 else 5 if pop >= 400_000 else 3 if pop >= 150_000 else 1
            tag = tags[p_owner[i]]
            is_cap = capitals[tag] == i
            if is_cap:
                vp = 20
                terrain = 4
            provinces.append({
                "land": 1, "owner": tag, "name": name, "x": round(float(cx[i]), 1), "y": round(float(cy[i]), 1),
                "px": int(counts[i]), "terrain": terrain, "vp": vp, "pop": int(total_pop),
                "lat": round(lat, 2), "lon": round(lon, 2), "region": r["name_ru"],
                "adj": sorted(adj[i]),
            })
        else:
            ids = sea_lab[prov == i]
            ids = ids[ids > 0]
            nm = marine_names[int(np.bincount(ids).argmax())] if ids.size else ""
            provinces.append({
                "land": 0, "owner": "", "name": nm or "Море", "x": round(float(cx[i]), 1), "y": round(float(cy[i]), 1),
                "px": int(counts[i]), "terrain": 5, "vp": 0, "pop": 0,
                "lat": round(lat, 2), "lon": round(lon, 2), "region": "", "adj": sorted(adj[i]),
            })
    # повторяющиеся названия: добавляем область
    seen = {}
    for p in provinces:
        if p["land"] and used.get(p["name"], 0) > 1 and p["name"] == p["region"]:
            seen[p["name"]] = seen.get(p["name"], 0) + 1
            p["name"] = f"{p['name']} {seen[p['name']]}"

    nations = []
    for t in tags:
        nm, col, _ = NATIONS[t]
        nations.append({"tag": t, "name": nm, "color": list(col), "capital": capitals[t]})

    # --- 8. Запись --------------------------------------------------------------
    rgb = np.zeros((HEIGHT, WIDTH, 3), np.uint8)
    rgb[..., 0] = prov & 255
    rgb[..., 1] = (prov >> 8) & 255
    Image.fromarray(rgb, "RGB").save(os.path.join(out, "provinces.png.bin"), "PNG", optimize=True)
    rel = np.zeros((HEIGHT, WIDTH, 3), np.uint8)
    rel[..., 0] = np.clip(height * 255, 0, 255).astype(np.uint8)
    rel[..., 1] = rivers
    Image.fromarray(rel, "RGB").save(os.path.join(out, "relief.png.bin"), "PNG", optimize=True)
    meta = {
        "source": "Natural Earth (public domain); границы 1936 г. — tools/build_map.py",
        "width": WIDTH, "height": HEIGHT, "km_per_px": KM_PER_PX,
        "projection": {"type": "laea", "lon0": LON0, "lat0": LAT0, "x_min": X_MIN, "y_max": Y_MAX},
        "land_count": n_land, "nations": nations, "provinces": provinces,
    }
    with open(os.path.join(out, "map.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, separators=(",", ":"))
    print("Готово:", out)

    if args.preview:
        pal = np.array([NATIONS[t][1] for t in tags] + [(40, 70, 100)], np.uint8)
        o = np.where(owner >= 0, owner, len(tags))
        img = pal[o].astype(np.float32)
        border = np.zeros(prov.shape, bool)
        border[:, 1:] |= prov[:, 1:] != prov[:, :-1]
        border[1:, :] |= prov[1:, :] != prov[:-1, :]
        img[border & land] *= 0.7
        Image.fromarray(img.astype(np.uint8)).save(args.preview)


if __name__ == "__main__":
    sys.exit(main())
