#!/usr/bin/env python3
"""Сборка исторической карты мира 1 января 1936 г. для игры.

Запускается на ПК, не на телефоне. Результат кладётся в data/world1936/ и
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
# Весь мир в цилиндрической проекции Миллера (как карты стратегий жанра):
# долготы с разрывом в Беринговом проливе, широты от мыса Горн до Арктики.

LON_MIN = -169.0                 # левый край карты (Берингов пролив)
LAT_MIN, LAT_MAX = -56.0, 80.0
R_KM = 6371.0
WIDTH = 5632
S_PX = WIDTH / (2.0 * math.pi)   # пикселей на радиан долготы


def _miller(lat_rad):
    return 1.25 * np.log(np.tan(math.pi / 4.0 + 0.4 * lat_rad))


Y_TOP = float(_miller(math.radians(LAT_MAX)))
HEIGHT = int(math.ceil((Y_TOP - float(_miller(math.radians(LAT_MIN)))) * S_PX))
KM_PER_PX = R_KM / S_PX          # на экваторе; с широтой пиксель уменьшается (px_km)

SEED = 1936


def _wrap(lon):
    lon = np.asarray(lon, dtype=np.float64)
    return np.where(lon < LON_MIN, lon + 360.0, lon)


def project(lon, lat):
    lon = _wrap(lon)
    lat = np.clip(np.asarray(lat, dtype=np.float64), -89.0, 89.0)
    px = np.radians(lon - LON_MIN) * S_PX
    py = (Y_TOP - _miller(np.radians(lat))) * S_PX
    return px, py


def unproject(px, py):
    lon = np.degrees(np.asarray(px, dtype=np.float64) / S_PX) + LON_MIN
    y = Y_TOP - np.asarray(py, dtype=np.float64) / S_PX
    lat = np.degrees(2.5 * np.arctan(np.exp(0.8 * y)) - 0.625 * math.pi)
    lon = np.where(lon > 180.0, lon - 360.0, lon)
    return lon, lat


def px_area_km2(lat):
    """Площадь пикселя (км²) на широте lat: Миллер не равновелик."""
    phi = np.radians(np.asarray(lat, dtype=np.float64))
    return KM_PER_PX * KM_PER_PX * np.cos(phi) * np.cos(0.8 * phi)


def px_km(lat):
    """Средний размер пикселя (км) на широте lat."""
    return np.sqrt(px_area_km2(lat))


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
    # --- Америка
    "USA": ("США", (60, 96, 160), (-77.04, 38.90)),
    "CAN": ("Канада", (160, 58, 58), (-75.70, 45.42)),
    "MEX": ("Мексика", (92, 148, 92), (-99.13, 19.43)),
    "GUA": ("Гватемала", (120, 170, 200), (-90.51, 14.64)),
    "HON": ("Гондурас", (70, 110, 160), (-87.21, 14.07)),
    "ELS": ("Сальвадор", (60, 80, 170), (-89.19, 13.69)),
    "NIC": ("Никарагуа", (210, 170, 90), (-86.25, 12.13)),
    "COS": ("Коста-Рика", (170, 80, 110), (-84.08, 9.93)),
    "PAN": ("Панама", (200, 120, 60), (-79.52, 8.98)),
    "CUB": ("Куба", (60, 130, 170), (-82.37, 23.11)),
    "HAI": ("Гаити", (110, 70, 150), (-72.34, 18.54)),
    "DOM": ("Доминиканская Республика", (180, 160, 210), (-69.93, 18.49)),
    "COL": ("Колумбия", (230, 200, 70), (-74.07, 4.71)),
    "VEN": ("Венесуэла", (170, 90, 60), (-66.90, 10.49)),
    "ECU": ("Эквадор", (230, 230, 120), (-78.47, -0.18)),
    "PRU": ("Перу", (196, 90, 90), (-77.04, -12.05)),
    "BOL": ("Боливия", (120, 160, 80), (-68.15, -16.50)),
    "PAR": ("Парагвай", (110, 130, 200), (-57.58, -25.26)),
    "CHL": ("Чили", (150, 60, 100), (-70.65, -33.45)),
    "ARG": ("Аргентина", (140, 190, 230), (-58.38, -34.60)),
    "URU": ("Уругвай", (90, 120, 190), (-56.16, -34.90)),
    "BRA": ("Бразилия", (90, 160, 90), (-43.17, -22.91)),
    # --- Азия и Океания
    "JAP": ("Япония", (220, 200, 110), (139.69, 35.69)),
    "MAN": ("Маньчжоу-го", (160, 140, 80), (125.32, 43.82)),
    "CHI": ("Китай", (98, 132, 170), (118.78, 32.06)),
    "PRC": ("Китайская Советская Республика", (190, 60, 60), (108.77, 36.82)),
    "GXC": ("Гуанси", (130, 170, 130), (108.32, 22.82)),
    "YUN": ("Юньнань", (170, 140, 190), (102.83, 24.88)),
    "SHX": ("Шаньси", (150, 120, 90), (112.55, 37.87)),
    "XSM": ("Клика Ма", (120, 100, 140), (101.78, 36.62)),
    "SIK": ("Синьцзян", (190, 170, 120), (87.62, 43.83)),
    "TIB": ("Тибет", (220, 180, 150), (91.13, 29.65)),
    "MON": ("Монголия", (130, 90, 70), (106.91, 47.92)),
    "TAN": ("Тува", (180, 120, 120), (94.45, 51.72)),
    "SIA": ("Сиам", (100, 80, 160), (100.50, 13.75)),
    "AFG": ("Афганистан", (110, 140, 100), (69.17, 34.53)),
    "NEP": ("Непал", (170, 100, 120), (85.32, 27.71)),
    "BHU": ("Бутан", (230, 150, 70), (89.86, 27.58)),
    "RAJ": ("Британская Индия", (200, 150, 110), (77.21, 28.61)),
    "PHI": ("Филиппины", (100, 140, 200), (120.98, 14.60)),
    "YEM": ("Йемен", (160, 110, 90), (44.21, 15.35)),
    "OMA": ("Маскат и Оман", (190, 100, 90), (58.59, 23.61)),
    "AST": ("Австралия", (90, 110, 170), (149.13, -35.28)),
    "NZL": ("Новая Зеландия", (80, 90, 140), (174.78, -41.29)),
    # --- Африка
    "ETH": ("Эфиопия", (100, 160, 110), (38.75, 9.03)),
    "LIB": ("Либерия", (150, 100, 140), (-10.80, 6.30)),
    "SAF": ("Южно-Африканский Союз", (200, 160, 100), (28.19, -25.75)),
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
    # --- Америка
    "USA": "USA", "PRI": "USA", "VIR": "USA", "GUM": "USA", "ASM": "USA", "UMI": "USA", "USG": "USA",
    "CAN": "CAN", "GRL": "DEN", "MEX": "MEX", "GTM": "GUA", "HND": "HON", "SLV": "ELS", "NIC": "NIC",
    "CRI": "COS", "PAN": "PAN", "CUB": "CUB", "HTI": "HAI", "DOM": "DOM",
    "BLZ": "ENG", "JAM": "ENG", "BHS": "ENG", "TTO": "ENG", "BRB": "ENG", "ATG": "ENG", "DMA": "ENG",
    "GRD": "ENG", "KNA": "ENG", "LCA": "ENG", "VCT": "ENG", "VGB": "ENG", "AIA": "ENG", "MSR": "ENG",
    "CYM": "ENG", "TCA": "ENG", "BMU": "ENG", "ABW": "HOL", "CUW": "HOL", "SXM": "HOL",
    "BLM": "FRA", "MAF": "FRA", "SPM": "FRA",
    "COL": "COL", "VEN": "VEN", "ECU": "ECU", "PER": "PRU", "BOL": "BOL", "PRY": "PAR", "CHL": "CHL",
    "ARG": "ARG", "URY": "URU", "BRA": "BRA", "GUY": "ENG", "SUR": "HOL", "FLK": "ENG", "SGS": "ENG",
    # --- Азия
    "JPN": "JAP", "KOR": "JAP", "PRK": "JAP", "TWN": "JAP", "MNP": "JAP", "FSM": "JAP", "PLW": "JAP",
    "MHL": "JAP", "CHN": "CHI", "HKG": "ENG", "MAC": "POR", "MNG": "MON",
    "IND": "RAJ", "PAK": "RAJ", "BGD": "RAJ", "MMR": "RAJ", "KAS": "RAJ", "LKA": "ENG", "MDV": "ENG",
    "NPL": "NEP", "BTN": "BHU", "AFG": "AFG", "THA": "SIA", "VNM": "FRA", "LAO": "FRA", "KHM": "FRA",
    "MYS": "ENG", "SGP": "ENG", "BRN": "ENG", "IDN": "HOL", "TLS": "POR", "PHL": "PHI",
    "KGZ": "SOV", "TJK": "SOV", "KAB": "SOV", "YEM": "YEM", "OMN": "OMA", "ARE": "ENG", "QAT": "ENG",
    "BHR": "ENG", "IOT": "ENG",
    # --- Африка
    "ETH": "ETH", "ERI": "ITA", "SOM": "ITA", "SOL": "ENG", "DJI": "FRA", "SDN": "ENG", "SDS": "ENG",
    "KEN": "ENG", "UGA": "ENG", "TZA": "ENG", "RWA": "BEL", "BDI": "BEL", "COD": "BEL",
    "COG": "FRA", "GAB": "FRA", "CAF": "FRA", "TCD": "FRA", "CMR": "FRA", "NGA": "ENG", "GHA": "ENG",
    "SLE": "ENG", "GMB": "ENG", "LBR": "LIB", "CIV": "FRA", "GIN": "FRA", "SEN": "FRA", "MLI": "FRA",
    "MRT": "FRA", "BFA": "FRA", "NER": "FRA", "BEN": "FRA", "TGO": "FRA", "GNB": "POR", "CPV": "POR",
    "STP": "POR", "AGO": "POR", "MOZ": "POR", "GNQ": "SPR", "SAH": "SPR", "ZMB": "ENG", "ZWE": "ENG",
    "MWI": "ENG", "BWA": "ENG", "LSO": "ENG", "SWZ": "ENG", "ZAF": "SAF", "NAM": "SAF",
    "MDG": "FRA", "COM": "FRA", "MUS": "ENG", "SYC": "ENG", "SHN": "ENG", "ATF": "FRA",
    # --- Океания
    "AUS": "AST", "NZL": "NZL", "PNG": "AST", "NFK": "AST", "FJI": "ENG", "SLB": "ENG", "TON": "ENG",
    "KIR": "ENG", "TUV": "ENG", "NRU": "AST", "VUT": "ENG", "PCN": "ENG", "NCL": "FRA", "PYF": "FRA",
    "WLF": "FRA", "WSM": "NZL", "COK": "NZL", "NIU": "NZL",
}

# Колониальные владения (у метрополий Франции, Британии, Италии, Испании):
# такие провинции дают меньше промышленности и призывников (данные — nations.json).
COLONY_ADM0 = {
    "PRI", "VIR", "GUM", "ASM", "UMI", "USG", "GRL", "BLZ", "JAM", "BHS", "TTO", "BRB", "ATG", "DMA",
    "GRD", "KNA", "LCA", "VCT", "VGB", "AIA", "MSR", "CYM", "TCA", "BMU", "ABW", "CUW", "SXM", "BLM",
    "MAF", "SPM", "GUY", "SUR", "FLK", "SGS", "KOR", "PRK", "TWN", "MNP", "FSM", "PLW", "MHL", "HKG",
    "MAC", "LKA", "MDV", "VNM", "LAO", "KHM", "MYS", "SGP", "BRN", "IDN", "TLS", "ARE", "QAT", "BHR",
    "IOT", "ERI", "SOM", "SOL", "DJI", "SDN", "SDS", "KEN", "UGA", "TZA", "RWA", "BDI", "COD", "COG",
    "GAB", "CAF", "TCD", "CMR", "NGA", "GHA", "SLE", "GMB", "CIV", "GIN", "SEN", "MLI", "MRT", "BFA",
    "NER", "BEN", "TGO", "GNB", "CPV", "STP", "AGO", "MOZ", "GNQ", "SAH", "ZMB", "ZWE", "MWI", "BWA",
    "LSO", "SWZ", "NAM", "MDG", "COM", "MUS", "SYC", "SHN", "ATF", "PNG", "NFK", "FJI", "SLB", "TON",
    "KIR", "TUV", "NRU", "VUT", "PCN", "NCL", "PYF", "WLF", "WSM", "COK", "NIU",
    "MAR", "DZA", "TUN", "LBY", "SYR", "LBN", "ISR", "PSX", "PSE", "JOR", "KWT",
               "MLT", "CYP", "CYN", "ESB", "WSB", "GIB", "GRC", "TUR"}
COLONIAL_POWERS = {"FRA", "ENG", "ITA", "SPR", "POR", "HOL", "BEL", "USA", "JAP", "DEN", "AST", "NZL", "SAF"}

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
    ("MAR", "Laâyoune - Boujdour - Sakia El Hamra"): "SPR", ("MAR", "Oued el Dahab"): "SPR",
    ("CAN", "Newfoundland and Labrador"): "ENG",
    ("CHN", "Heilongjiang"): "MAN", ("CHN", "Jilin"): "MAN", ("CHN", "Liaoning"): "MAN",
    ("CHN", "Guangxi"): "GXC", ("CHN", "Yunnan"): "YUN", ("CHN", "Shanxi"): "SHX",
    ("CHN", "Qinghai"): "XSM", ("CHN", "Ningxia"): "XSM", ("CHN", "Xinjiang"): "SIK", ("CHN", "Xizang"): "TIB",
    ("YEM", "Hadramawt"): "ENG", ("YEM", "Al Mahrah"): "ENG", ("YEM", "Lahij"): "ENG", ("YEM", "`Adan"): "ENG",
    ("YEM", "Abyan"): "ENG", ("YEM", "Shabwah"): "ENG", ("YEM", "Al Dali'"): "ENG",
    ("IND", "Goa"): "POR", ("IND", "Dadra and Nagar Haveli and Daman and Diu"): "POR", ("IND", "Puducherry"): "FRA",
    ("RUS", "Tuva"): "TAN",
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
    # Маньчжоу-го: восток Внутренней Монголии и Жэхэ
    ("MAN", ["CHI"], [(117.0, 41.6), (119.6, 41.2), (122.5, 42.2), (126.5, 46.0), (125.5, 51.0),
                      (121.0, 53.6), (115.4, 50.0), (115.6, 46.5), (117.2, 45.0), (116.4, 42.6)]),
    ("MAN", ["CHI"], [(115.9, 40.75), (117.4, 40.2), (118.9, 40.0), (119.8, 40.0), (120.0, 41.5),
                      (117.6, 42.4), (116.0, 41.9)]),
    # Квантунская область (Дайрен, Порт-Артур) — Япония
    ("JAP", ["MAN"], [(120.9, 38.6), (122.4, 38.6), (122.4, 39.45), (120.9, 39.45)]),
    # Карафуто (юг Сахалина) и Курилы — Япония
    ("JAP", ["SOV"], [(140.5, 45.6), (145.5, 45.6), (145.5, 50.0), (140.5, 50.0)]),
    ("JAP", ["SOV"], [(144.6, 43.5), (146.6, 42.9), (158.2, 50.6), (156.3, 51.6)]),
    # Советский район Шэньси — Ганьсу — Нинся
    ("PRC", ["CHI"], [(107.0, 36.0), (110.2, 36.0), (110.2, 38.3), (107.0, 38.3)]),
]

MOUNTAIN_HEIGHT = {"HIMALAYAS": 1.0, "KARAKORAM RA.": 1.0, "PAMIRS": 1.0, "HINDU KUSH": 0.9,
                   "KUNLUN MOUNTAINS": 0.85, "TIAN SHAN": 0.85, "ANDES": 1.0, "CORDILLERA OCCIDENTAL": 0.85,
                   "CORDILLERA  REAL": 0.9, "CORDILLERA ORIENTAL": 0.8, "CORD. CENTRAL": 0.8,
                   "CORD. OCCIDENTAL": 0.8, "ROCKY MOUNTAINS": 0.85, "COAST MOUNTAINS": 0.7,
                   "CASCADE RANGE": 0.65, "SIERRA NEVADA": 0.7, "ALASKA RANGE": 0.85, "BROOKS RANGE": 0.6,
                   "ETHIOPIAN HIGHLANDS": 0.7, "ALTAY MOUNTAINS": 0.7, "SOUTHERN ALPS": 0.8,
                   "NEW GUINEA HIGHLANDS": 0.8, "SIERRA MADRE OCCIDENTAL": 0.65, "SIERRA MADRE ORIENTAL": 0.6,
                   "Sierra Madre del Sur": 0.6, "DRAKENSBERG": 0.65, "QUILIAN MOUNTAINS": 0.8,
                   "ALTUN MTS.": 0.75, "EASTERN SAYAN MTS.": 0.6, "Qinling Mountains": 0.6,
                   "ALPS": 1.0, "CAUCASUS MTS.": 1.0, "PYRENEES": 0.85, "HAUT ATLAS": 0.9,
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
    # Азия, Африка, Америка — названия 1936 г.
    "Beijing": "Бэйпин", "Shenyang": "Мукден", "Changchun": "Синьцзин", "Dalian": "Дайрен",
    "Lüshun": "Порт-Артур", "Guangzhou": "Кантон", "Wuhan": "Ханькоу", "Ürümqi": "Дихуа",
    "Urumqi": "Дихуа", "Hohhot": "Гуйсуй", "Seoul": "Кэйдзё", "Pyongyang": "Хэйдзё", "Busan": "Фузан",
    "Taipei": "Тайхоку", "Kaohsiung": "Такао", "Yuzhno-Sakhalinsk": "Тоёхара",
    "Mumbai": "Бомбей", "Chennai": "Мадрас", "Kolkata": "Калькутта", "Yangon": "Рангун",
    "Ho Chi Minh City": "Сайгон", "Jakarta": "Батавия", "Kinshasa": "Леопольдвиль",
    "Lubumbashi": "Элизабетвиль", "Kisangani": "Стэнливиль", "Harare": "Солсбери",
    "Maputo": "Лоренсу-Маркиш", "Antananarivo": "Тананариве", "N'Djamena": "Форт-Лами",
    "Almaty": "Алма-Ата", "Bishkek": "Фрунзе", "Dushanbe": "Сталинабад", "Santo Domingo": "Сьюдад-Трухильо",
}


# --- Плотность провинций ------------------------------------------------------
# Как в стратегиях жанра: где решается война — мелкие провинции, где пусто —
# крупные. Значение — целевая площадь провинции (км²); побеждает наименьшая
# подходящая зона, поэтому зоны можно задавать грубыми прямоугольниками.
#   (мин. долгота, мин. широта, макс. долгота, макс. широта, км²)
DENSITY_ZONES = [
    # ядро: Франция, Бенилюкс, Германия, Чехия, Австрия, Польша, север Италии, юг Англии
    (-5.0, 43.0, 24.5, 55.5, 6500),
    (-3.5, 50.5, 1.8, 54.0, 6500),
    # остальная Центральная и Западная Европа, Балканы, Прибалтика, Италия
    (-10.5, 36.0, 30.0, 60.0, 11000),
    # западная часть СССР до линии Ленинград — Москва — Сталинград
    (24.0, 44.0, 45.0, 60.5, 17000),
    # Скандинавия, Иберия, Анатолия, Кавказ
    (-10.0, 35.5, 32.0, 64.0, 16000),
    (26.0, 35.5, 50.0, 43.5, 22000),
]
DEFAULT_AREA = 45000          # север и восток Европы, Исландия
WORLD_DEFAULT_AREA = 60000    # остальной мир, если страна не указана ниже
REMOTE_AREA = 65000           # пустыни Африки, Аравии, Ирана, Заволжье
COAST_AREA = 26000            # обжитое побережье Северной Африки и Леванта
REMOTE_ADM0 = {"MAR", "DZA", "TUN", "LBY", "EGY", "SYR", "IRQ", "SAU", "KWT", "IRN", "JOR",
               "ISR", "PSX", "LBN", "KAZ", "TKM", "UZB"}
EUROPE_ADM0 = {"DEU", "AUT", "CZE", "SVK", "POL", "RUS", "BLR", "UKR", "GEO", "ARM", "AZE", "LTU", "LVA",
               "EST", "FIN", "ALD", "ROU", "MDA", "BGR", "HUN", "SRB", "MNE", "BIH", "HRV", "SVN", "MKD",
               "KOS", "ITA", "SMR", "VAT", "ALB", "GRC", "TUR", "FRA", "MCO", "AND", "BEL", "NLD", "LUX",
               "CHE", "LIE", "ESP", "PRT", "GBR", "IMN", "JEY", "GGY", "GIB", "IRL", "DNK", "FRO", "NOR",
               "SWE", "ISL", "MLT", "CYP", "CYN", "ESB", "WSB"}
# Вне Европы: целевая площадь провинции по стране (км²). Как в жанре: где
# будет война (Китай, Маньчжурия, Япония, восток США, побережья) — мельче,
# пустыни, тайга и джунгли — крупно.
ADM0_AREA = {
    "KGZ": 50000, "TJK": 50000, "MNG": 150000, "CHN": 20000, "JPN": 9000, "KOR": 12000, "PRK": 12000,
    "TWN": 12000, "IND": 35000, "PAK": 50000, "BGD": 15000, "LKA": 20000, "NPL": 40000, "BTN": 40000,
    "MMR": 50000, "THA": 40000, "VNM": 25000, "LAO": 50000, "KHM": 40000, "MYS": 25000, "SGP": 5000,
    "BRN": 10000, "IDN": 35000, "PHL": 15000, "TLS": 20000, "PNG": 60000, "AFG": 70000, "YEM": 50000,
    "OMN": 80000, "ARE": 40000, "QAT": 20000,
    "NGA": 50000, "GHA": 40000, "SLE": 30000, "GMB": 10000, "LBR": 40000, "CIV": 60000, "GIN": 60000,
    "SEN": 50000, "GNB": 30000, "TGO": 30000, "BEN": 40000, "BFA": 70000, "MLI": 200000, "MRT": 200000,
    "NER": 200000, "TCD": 200000, "SDN": 150000, "SDS": 120000, "SAH": 150000, "ETH": 50000, "ERI": 40000,
    "DJI": 20000, "SOM": 80000, "SOL": 60000, "KEN": 60000, "UGA": 40000, "TZA": 70000, "RWA": 20000,
    "BDI": 20000, "COD": 120000, "COG": 80000, "GAB": 70000, "CMR": 60000, "CAF": 100000, "GNQ": 20000,
    "AGO": 110000, "ZMB": 100000, "ZWE": 60000, "MWI": 40000, "MOZ": 80000, "BWA": 150000, "NAM": 150000,
    "ZAF": 60000, "LSO": 30000, "SWZ": 15000, "MDG": 70000,
    "USA": 45000, "CAN": 300000, "GRL": 500000, "MEX": 45000, "GTM": 15000, "HND": 15000, "SLV": 15000,
    "NIC": 15000, "CRI": 15000, "PAN": 15000, "BLZ": 20000, "CUB": 20000, "HTI": 15000, "DOM": 15000,
    "JAM": 10000, "PRI": 9000, "BHS": 10000, "TTO": 5000,
    "BRA": 120000, "ARG": 90000, "CHL": 30000, "URY": 25000, "PRY": 50000, "BOL": 70000, "PER": 50000,
    "ECU": 30000, "COL": 50000, "VEN": 50000, "GUY": 60000, "SUR": 60000,
    "AUS": 200000, "NZL": 25000,
}
ADM1_AREA = {
    ("CHN", "Xinjiang"): 150000, ("CHN", "Xizang"): 150000, ("CHN", "Qinghai"): 110000,
    ("CHN", "Inner Mongol"): 70000, ("CHN", "Gansu"): 45000, ("CHN", "Heilongjiang"): 40000,
    ("CHN", "Jilin"): 25000, ("CHN", "Liaoning"): 15000, ("CHN", "Sichuan"): 35000,
    ("USA", "Alaska"): 250000, ("USA", "Hawaii"): 8000, ("FRA", "Guyane française"): 60000,
}
# Прямоугольники вне Европы, где провинции мельче базовых (минимум из подходящих)
AREA_RECTS = [
    (-98.0, 24.0, -66.0, 50.0, 22000),     # восток США
    (-125.0, 32.0, -116.0, 49.0, 30000),   # тихоокеанское побережье США
    (-84.0, 42.0, -60.0, 48.6, 25000),     # Онтарио, Квебек, Приморье Канады
    (-125.0, 48.9, -95.0, 54.0, 60000),    # канадские прерии
    (-55.0, -34.0, -34.0, -3.0, 45000),    # побережье Бразилии
    (-66.0, -40.0, -56.0, -27.0, 35000),   # пампа
    (138.0, -39.0, 154.0, -26.0, 50000),   # юго-восток Австралии
    (114.0, -36.0, 119.0, -30.0, 60000),   # юго-запад Австралии
    (60.0, 50.0, 135.0, 57.0, 60000),      # Транссиб
    (127.0, 42.0, 142.0, 52.0, 30000),     # Приморье, Приамурье
]


def province_area_km2(lon, lat, region, region_info, land):
    n_reg = len(region_info)
    base = np.full(n_reg, float(WORLD_DEFAULT_AREA), np.float32)
    remote = np.zeros(n_reg, bool)
    europe = np.zeros(n_reg, bool)
    is_rus = np.zeros(n_reg, bool)
    for i, r in enumerate(region_info[1:], start=1):
        a0 = r["adm0"]
        remote[i] = a0 in REMOTE_ADM0
        europe[i] = a0 in EUROPE_ADM0
        is_rus[i] = a0 == "RUS"
        if europe[i]:
            base[i] = DEFAULT_AREA
        base[i] = ADM1_AREA.get((a0, r.get("name_en", "")), ADM0_AREA.get(a0, base[i]))
    area = base[region]
    is_remote = remote[region]
    in_rus = is_rus[region]
    km = px_km(lat)
    coast_km = ndimage.distance_transform_edt(land) * km
    area = np.where(is_remote, np.where(coast_km < 160, COAST_AREA, REMOTE_AREA), area)
    # Россия: Европейская часть — как раньше, Заволжье и Урал крупнее, Сибирь — крупно
    area = np.where(in_rus & (lon > 52) & (lon <= 60), REMOTE_AREA, area)
    area = np.where(in_rus & (lon > 60), 90000.0, area)
    for x0, y0, x1, y1, a in AREA_RECTS:
        m = (lon >= x0) & (lon <= x1) & (lat >= y0) & (lat <= y1) & ~is_remote & ~europe[region]
        area = np.where(m, np.minimum(area, a), area)
    # обжитое побережье в больших пустых странах — мельче
    big = (area >= 60000) & ~is_remote
    area = np.where(big & (coast_km < 200), np.maximum(area * 0.5, 30000), area)
    for x0, y0, x1, y1, a in DENSITY_ZONES:
        m = (lon >= x0) & (lon <= x1) & (lat >= y0) & (lat <= y1) & ~is_remote
        area = np.where(m, np.minimum(area, a), area)
    # плавный переход между зонами, чтобы не было резкой «ступеньки»
    return ndimage.gaussian_filter(area.astype(np.float32), 25)


# Морские зоны: какие акватории берём, пороги площади (км²)
SEA_CLASSES = {"ocean", "sea", "gulf", "bay", "strait", "channel", "sound"}
SEA_MIN_EUROPE = 20000      # в Европе отдельной зоной и Каттегат, и Ла-Манш
SEA_MIN_WORLD = 80000
SEA_MAX_EUROPE = 400000     # крупнее — делим (Норвежское, Средиземное море)
SEA_MAX_WORLD = 1300000
OCEAN_PART = 4000000
LAKE_MIN_KM2 = 15000        # Ладога, Байкал, Великие озёра — зоны; мелкие озёра — часть суши

# Местность по прямоугольникам (долгота, широта): пустыни, джунгли, нагорья
DESERT_BOXES = [(-17, 15, 35, 34), (35, 12, 60, 32), (90, 38, 118, 46), (75, 36, 92, 42),
                (118, -32, 145, -18), (12, -28, 26, -18), (-71, -27, -68, -18), (-118, 30, -106, 37)]
JUNGLE_BOXES = [(-75, -12, -48, 5), (10, -5, 30, 5), (95, -8, 125, 20), (-92, 7, -77, 18),
                (130, -10, 151, 0)]
PLATEAU_BOXES = [(78, 28, 102, 37), (-70, -22, -66, -15)]


def _in_boxes(lon, lat, boxes):
    for x0, y0, x1, y1 in boxes:
        if x0 <= lon <= x1 and y0 <= lat <= y1:
            return True
    return False


# Воздушные (стратегические) районы, как в жанре: группы соседних провинций
# суши, примерно по AIR_GROUP_EUROPE провинций в Европе и AIR_GROUP_WORLD в
# остальном мире; каждая морская зона — свой район.
AIR_GROUP_EUROPE = 12
AIR_GROUP_WORLD = 16


def build_air_regions(provinces, n_land, adj, cx, cy, counts, rng):
    n_prov = len(provinces)
    region = np.full(n_prov, -1, np.int64)
    land_adj = [[q for q in adj[i] if q < n_land] for i in range(n_land)]
    # связные массивы суши (материки, острова)
    comp = np.full(n_land, -1, np.int64)
    comps = []
    for i in range(n_land):
        if comp[i] >= 0:
            continue
        stack = [i]
        comp[i] = len(comps)
        members = []
        while stack:
            u = stack.pop()
            members.append(u)
            for v in land_adj[u]:
                if comp[v] < 0:
                    comp[v] = len(comps)
                    stack.append(v)
        comps.append(sorted(members))
    next_r = 0
    small = []
    for members in comps:
        if len(members) < 4:
            small.extend(members)
            continue
        idx = np.asarray(members)
        coords = np.stack([cx[idx], cy[idx]], 1)
        target = np.array([AIR_GROUP_EUROPE if (-12 <= provinces[i]["lon"] <= 45 and 34 <= provinces[i]["lat"] <= 72)
                           else AIR_GROUP_WORLD for i in members], np.float64)
        lab = kmeans_regions(coords, target, rng, iters=10) if len(members) > 1 else np.zeros(1, np.int32)
        region[idx] = lab + next_r
        next_r += int(lab.max()) + 1
    # оторванные куски района (k-means может перешагнуть залив) — к соседу,
    # с которым больше всего общих границ
    for _ in range(3):
        changed = False
        for r in range(next_r):
            members = np.nonzero(region[:n_land] == r)[0].tolist()
            if not members:
                continue
            seen = set()
            parts = []
            for m in members:
                if m in seen:
                    continue
                part = []
                stack = [m]
                seen.add(m)
                while stack:
                    u = stack.pop()
                    part.append(u)
                    for v in land_adj[u]:
                        if v not in seen and region[v] == r:
                            seen.add(v)
                            stack.append(v)
                parts.append(part)
            if len(parts) < 2:
                continue
            parts.sort(key=len, reverse=True)
            for part in parts[1:]:
                votes = {}
                for u in part:
                    for v in land_adj[u]:
                        if region[v] != r and region[v] >= 0:
                            votes[int(region[v])] = votes.get(int(region[v]), 0) + 1
                if votes:
                    best = max(sorted(votes), key=lambda k: votes[k])
                    for u in part:
                        region[u] = best
                    changed = True
        if not changed:
            break
    # мелкие острова — к ближайшему району суши
    big = np.nonzero(region[:n_land] >= 0)[0]
    if small and big.size:
        tree = cKDTree(np.stack([cx[big], cy[big]], 1))
        for i in small:
            _, k = tree.query([cx[i], cy[i]])
            region[i] = region[big[k]]
    # перенумерация без пропусков, морские зоны — свои районы
    used_r = sorted(set(region[:n_land].tolist()))
    remap = {r: k for k, r in enumerate(used_r)}
    for i in range(n_land):
        region[i] = remap[int(region[i])]
    n_air_land = len(used_r)
    for i in range(n_land, n_prov):
        region[i] = n_air_land + (i - n_land)
    # названия: историческая область крупнейшего города района
    names = []
    taken = {}
    for r in range(n_air_land):
        members = [i for i in range(n_land) if region[i] == r]
        best = max(members, key=lambda i: (provinces[i]["pop"], -i))
        nm = provinces[best]["region"] or provinces[best]["name"]
        if nm in taken:
            nm = provinces[best]["name"]
        if nm in taken:
            taken[nm] += 1
            nm = "%s %d" % (nm, taken[nm])
        taken[nm] = 1
        names.append(nm)
    for i in range(n_land, n_prov):
        names.append(provinces[i]["name"])
    for i in range(n_prov):
        provinces[i]["air"] = int(region[i])
    print(f"Воздушных районов: {n_air_land} над сушей + {n_prov - n_land} морских")
    return names


def _rank(v):
    """scalerank Natural Earth: 0 — самые крупные объекты (не путать с «нет данных»)."""
    return 9 if v is None else int(v)


def _dist_km(lon1, lat1, lon2, lat2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    c = math.sin(p1) * math.sin(p2) + math.cos(p1) * math.cos(p2) * math.cos(dl)
    return R_KM * math.acos(max(-1.0, min(1.0, c)))


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


def _ring_lonlat(ring):
    """Кольцо целиком по одну сторону разрыва карты (иначе — полоса через всю карту)."""
    arr = np.asarray(ring, dtype=np.float64)
    lon = arr[:, 0]
    if (lon < LON_MIN).any() and (lon >= LON_MIN).any():
        # кольцо пересекает разрыв: переносим целиком на ту сторону, где его больше
        lon = lon + 360.0 if lon.mean() < LON_MIN else np.maximum(lon, LON_MIN)
    else:
        lon = np.where(lon < LON_MIN, lon + 360.0, lon)
    return lon, arr[:, 1]


def poly_px(ring):
    lon, lat = _ring_lonlat(ring)
    lat = np.clip(lat, -89.0, 89.0)
    x = np.radians(lon - LON_MIN) * S_PX
    y = (Y_TOP - _miller(np.radians(lat))) * S_PX
    return list(zip(x.tolist(), y.tolist()))


def in_window(ring):
    pts = poly_px(ring)
    if not pts:
        return False
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return max(xs) >= -50 and min(xs) <= WIDTH + 50 and max(ys) >= -50 and min(ys) <= HEIGHT + 50


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
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "world1936"))
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
        region_info.append({"adm0": a0, "name_ru": p.get("name_ru") or p["name"], "name_en": p["name"], "tag": tag})
        for r in rings:
            pts = poly_px(r)
            if len(pts) >= 3:
                draw.polygon(pts, fill=rid)
    region = np.array(region_img, dtype=np.int32)

    # Крупные озёра — вода
    lakes = load(os.path.join(ne, "ne_10m_lakes.geojson"))["features"]
    lake_img = Image.new("I", (WIDTH, HEIGHT), 0)
    ld = ImageDraw.Draw(lake_img)
    lake_names = [""]
    for f in lakes:
        if _rank(f["properties"].get("scalerank")) <= 4:
            lp = f["properties"]
            lake_names.append(lp.get("name_ru") or lp.get("name") or "Озеро")
            for r in rings_of(f["geometry"]):
                if in_window(r):
                    ld.polygon(poly_px(r), fill=len(lake_names) - 1)
    lake_lab = np.array(lake_img, dtype=np.int32)
    region[lake_lab > 0] = 0

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
    # все хребты на одном изображении: низкие первыми, высокие поверх
    ranges = []
    for f in geo:
        p = f["properties"]
        if "Range" not in str(p.get("FEATURECLA")):
            continue
        name = p.get("NAME") or ""
        hgt = MOUNTAIN_HEIGHT.get(name, 0.4 if _rank(p.get("SCALERANK")) <= 5 else 0.0)
        if hgt > 0:
            ranges.append((hgt, f))
    m_img = Image.new("L", (WIDTH, HEIGHT), 0)
    md = ImageDraw.Draw(m_img)
    for hgt, f in sorted(ranges, key=lambda t: t[0]):
        for r in rings_of(f["geometry"]):
            if in_window(r):
                md.polygon(poly_px(r), fill=int(round(hgt * 255)))
    mount = np.array(m_img, dtype=np.float32) / 255.0
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
        sr = _rank(f["properties"].get("scalerank"))
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
    area_km2 = province_area_km2(lon_all, lat_all, region, region_info, land)
    area_px = area_km2 / px_area_km2(lat_all)

    prov = np.full(region.shape, -1, np.int32)
    next_id = 0
    # мелкий остров ближе 300 км к своей стране — к ней (в пикселях своей широты)
    for t in range(len(tags)):
        mask = owner == t
        if not mask.any():
            continue
        lab, n = ndimage.label(mask)
        objs = ndimage.find_objects(lab)
        small = []
        for ci in range(n):
            sl = objs[ci]
            sub = lab[sl] == ci + 1
            ys, xs = np.nonzero(sub)
            ys = ys + sl[0].start
            xs = xs + sl[1].start
            # остров меньше трети целевой провинции (и не больше 2500 км²) — отложить
            if ys.size < min(0.33 * float(area_px[ys, xs].mean()), 2500.0 / float(px_area_km2(lat_all[ys[0], xs[0]]))):
                small.append((ys, xs))
                continue
            coords = np.stack([xs, ys], 1).astype(np.float64)
            labels = kmeans_regions(coords, area_px[ys, xs], rng)
            prov[ys, xs] = labels + next_id
            next_id += int(labels.max()) + 1
        if small:
            own = (prov >= 0) & mask
            if own.any():
                dist, idx = ndimage.distance_transform_edt(~own, return_indices=True)
            for ys, xs in sorted(small, key=lambda c: -c[0].size):
                if own.any() and dist[ys, xs].min() < 300.0 / float(px_km(lat_all[ys[0], xs[0]])):
                    k = int(np.argmin(dist[ys, xs]))
                    prov[ys, xs] = prov[idx[0][ys[k], xs[k]], idx[1][ys[k], xs[k]]]
                else:
                    prov[ys, xs] = next_id
                    next_id += 1
    n_land = next_id
    print(f"Провинций суши: {n_land}")

    # --- 5. Морские зоны --------------------------------------------------------
    # Как в жанре: зона — именованное море, залив или пролив (Natural Earth,
    # marine polys); мелкие заливы вливаются в своё море, большие моря делятся
    # на части по сторонам света, океаны — на куски по ~4 млн км².
    water = ~land
    pix_km2 = px_area_km2(lat_all)
    marine = load(os.path.join(ne, "ne_10m_geography_marine_polys.geojson"))["features"]

    def _marine_area(f):
        a = 0.0
        for r in rings_of(f["geometry"]):
            arr = np.asarray(r, dtype=np.float64)
            x, y = arr[:, 0], arr[:, 1]
            a += abs(np.dot(x, np.roll(y, 1)) - np.dot(y, np.roll(x, 1))) * 0.5
        return a
    feats_m = sorted(marine, key=_marine_area, reverse=True)
    m_img = Image.new("I", (WIDTH, HEIGHT), 0)
    mdr = ImageDraw.Draw(m_img)
    m_info = [None]
    for f in feats_m:
        pr = f["properties"]
        cla = pr.get("featurecla") or ""
        nm = pr.get("name_ru") or pr.get("name") or ""
        if cla not in SEA_CLASSES or not nm:
            continue
        m_info.append({"name": nm, "cla": cla})
        for r in rings_of(f["geometry"]):
            if in_window(r):
                mdr.polygon(poly_px(r), fill=len(m_info) - 1)
    mlab = np.array(m_img, dtype=np.int32)
    mlab[~water] = 0
    # площадь каждой акватории; мелкие (меньше порога своего района) — убрать
    m_km2 = np.bincount(mlab.ravel(), weights=pix_km2.ravel(), minlength=len(m_info))
    m_lon = np.bincount(mlab.ravel(), weights=lon_all.ravel(), minlength=len(m_info))
    m_lat = np.bincount(mlab.ravel(), weights=lat_all.ravel(), minlength=len(m_info))
    m_cnt = np.maximum(np.bincount(mlab.ravel(), minlength=len(m_info)), 1)
    keep = np.zeros(len(m_info), bool)
    for i in range(1, len(m_info)):
        lo, la = m_lon[i] / m_cnt[i], m_lat[i] / m_cnt[i]
        europe = -30 < lo < 60 and la > 25
        keep[i] = m_km2[i] >= (SEA_MIN_EUROPE if europe else SEA_MIN_WORLD)
    # убранные и неразмеченные пиксели воды — ближайшей оставшейся акватории
    # (только в водоёмах, где есть море: озёра морских меток не получают)
    mlab[~keep[mlab]] = 0
    wl0, wn0 = ndimage.label(water)
    has_marine = np.zeros(wn0 + 1, bool)
    has_marine[np.unique(wl0[mlab > 0])] = True
    has_marine[0] = False
    unl = water & (mlab == 0) & has_marine[wl0]
    if unl.any():
        idx = ndimage.distance_transform_edt(mlab == 0, return_distances=False, return_indices=True)
        mlab[unl] = mlab[idx[0][unl], idx[1][unl]]
    sea_names = []
    dirs = ["восток", "северо-восток", "север", "северо-запад", "запад", "юго-запад", "юг", "юго-восток"]
    for i in range(1, len(m_info)):
        if not keep[i]:
            continue
        mask = mlab == i
        lab, n = ndimage.label(mask, structure=np.ones((3, 3)))
        objs = ndimage.find_objects(lab)
        info = m_info[i]
        comp_km2 = ndimage.sum(pix_km2, lab, index=np.arange(1, n + 1)) if n else []
        for ci in range(1, n + 1):
            km2 = float(comp_km2[ci - 1])
            sl = objs[ci - 1]
            sub = lab[sl] == ci
            ys, xs = np.nonzero(sub)
            ys = ys + sl[0].start
            xs = xs + sl[1].start
            lo0, la0 = float(lon_all[ys, xs].mean()), float(lat_all[ys, xs].mean())
            europe = -30 < lo0 < 60 and la0 > 25
            # обрывки (между островами, в шхерах) — к соседней зоне ниже
            if km2 < 0.25 * m_km2[i] and km2 < (SEA_MIN_EUROPE if europe else SEA_MIN_WORLD):
                continue
            cap = OCEAN_PART if info["cla"] == "ocean" else (SEA_MAX_EUROPE if europe else SEA_MAX_WORLD)
            k = max(1, int(math.ceil(km2 / cap)))
            if k == 1:
                labels = np.zeros(ys.size, np.int32)
            else:
                coords = np.stack([xs, ys], 1).astype(np.float64)
                labels = kmeans_regions(coords, (km2 / k) / pix_km2[ys, xs], rng, iters=10)
            nk = int(labels.max()) + 1
            prov[ys, xs] = labels + next_id
            for j in range(nk):
                sel = labels == j
                lo, la = float(lon_all[ys[sel], xs[sel]].mean()), float(lat_all[ys[sel], xs[sel]].mean())
                if info["cla"] == "ocean":
                    nm = "%s (%d° %s, %d° %s)" % (info["name"], abs(round(la)), "с. ш." if la >= 0 else "ю. ш.",
                                                   abs(round(lo)), "в. д." if lo >= 0 else "з. д.")
                elif nk > 1:
                    ang = math.degrees(math.atan2(la - la0, (lo - lo0) * math.cos(math.radians(la0))))
                    nm = "%s (%s)" % (info["name"], dirs[int(round(ang / 45.0)) % 8])
                else:
                    nm = info["name"]
                sea_names.append(nm)
            next_id += nk
    # одинаковые названия (часть моря в двух кусках) — с номером
    seen_n = {}
    for j, nm in enumerate(sea_names):
        seen_n[nm] = seen_n.get(nm, 0) + 1
        if seen_n[nm] > 1:
            sea_names[j] = "%s %d" % (nm, seen_n[nm])
    # Озёра (вода без связи с морем): крупные — отдельная зона со своим
    # названием; мелкие — к соседней суше. Обрывки моря — ближайшей морской зоне.
    wl, wn = ndimage.label(water)
    has_sea = np.zeros(wn + 1, bool)
    has_sea[np.unique(wl[prov >= n_land])] = True
    wobjs = ndimage.find_objects(wl)
    for ci in range(1, wn + 1):
        if has_sea[ci]:
            continue
        sl = wobjs[ci - 1]
        sub = wl[sl] == ci
        ys, xs = np.nonzero(sub)
        ys = ys + sl[0].start
        xs = xs + sl[1].start
        if float(pix_km2[ys, xs].sum()) < LAKE_MIN_KM2:
            continue   # мелкое озеро — к соседней суше (рисуется водой по высоте)
        prov[ys, xs] = next_id
        ln = lake_lab[ys, xs]
        ln = ln[ln > 0]
        sea_names.append(lake_names[int(np.bincount(ln).argmax())] if ln.size else "Озеро")
        next_id += 1
    sea_zone = prov >= n_land
    loose = water & (prov < 0) & has_sea[wl]
    if loose.any():
        idx = ndimage.distance_transform_edt(~sea_zone, return_distances=False, return_indices=True)
        prov[loose] = prov[idx[0][loose], idx[1][loose]]
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
               ((9.20, 41.40), (9.20, 41.20)), ((10.30, 57.10), (11.00, 57.30)),
               ((103.75, 1.47), (103.75, 1.38)), ((141.65, 52.2), (141.3, 52.2)),
               ((130.95, 33.95), (130.9, 33.88)), ((-68.5, -52.5), (-69.3, -52.6))]
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


    capitals = {}
    for t, (nm, col, (lon, lat)) in NATIONS.items():
        x, y = project(lon, lat)
        xi, yi = int(np.clip(x, 0, WIDTH - 1)), int(np.clip(y, 0, HEIGHT - 1))
        ly, lx = land_idx[0][yi, xi], land_idx[1][yi, xi]
        capitals[t] = int(prov[ly, lx])

    home_adm0 = {t: set() for t in tags}
    for a0, t in ADM0_TAG.items():
        if a0 not in COLONY_ADM0:
            home_adm0[t].add(a0)

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
            elif (r["adm0"] in REMOTE_ADM0 and lat < 34.5) or _in_boxes(lon, lat, DESERT_BOXES):
                terrain = 6   # пустыня
            elif 23.5 < lon < 30.5 and 51.3 < lat < 52.5:
                terrain = 7   # Полесье — болота
            elif _in_boxes(lon, lat, JUNGLE_BOXES):
                terrain = 1   # джунгли — как лес
            else:
                fval = math.sin(lon * 1.7) * math.cos(lat * 2.3) + math.sin(lon * 0.6 + lat * 0.9)
                if lat > 57 or (lat > 52 and lon > 30) or (lat > 50 and lon < -60):
                    fval += 0.9   # тайга
                if fval > 1.0:
                    terrain = 1
            if _in_boxes(lon, lat, PLATEAU_BOXES) and terrain != 4:
                terrain = 3   # Тибетское нагорье, Альтиплано
            total_pop = city_pop[i]
            if pop >= 400000:
                terrain = 4
            vp = 10 if pop >= 1_000_000 else 5 if pop >= 400_000 else 3 if pop >= 150_000 else 1
            tag = tags[p_owner[i]]
            is_cap = capitals[tag] == i
            if is_cap:
                vp = 20
                terrain = 4
            # колония: владение колониальной державы вне её метрополии (или далеко от столицы)
            colony = tag in COLONIAL_POWERS and (r["adm0"] in COLONY_ADM0 or r["adm0"] not in home_adm0[tag]
                                                or _dist_km(lon, lat, *NATIONS[tag][2]) > 2500)
            provinces.append({
                "land": 1, "owner": tag, "name": name, "adm0": r["adm0"], "colony": colony, "x": round(float(cx[i]), 1), "y": round(float(cy[i]), 1),
                "px": int(counts[i]), "terrain": terrain, "vp": vp, "pop": int(total_pop),
                "lat": round(lat, 2), "lon": round(lon, 2), "region": r["name_ru"],
                "adj": sorted(adj[i]),
            })
        else:
            nm = sea_names[i - n_land]
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

    air_names = build_air_regions(provinces, n_land, adj, cx, cy, counts, rng)

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
        "projection": {"type": "miller", "lon_min": LON_MIN, "lat_min": LAT_MIN, "lat_max": LAT_MAX},
        "land_count": n_land, "nations": nations, "provinces": provinces, "air_regions": air_names,
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
