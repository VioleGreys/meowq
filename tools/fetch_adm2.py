#!/usr/bin/env python3
"""Скачивает административные районы geoBoundaries (gbOpen, свободные лицензии:
ODbL / CC BY — авторство в assets/CREDITS.md) для всех стран окна карты:
ADM2, если есть, иначе ADM1. Упрощённая геометрия (для карты 5632 пикс. хватает).
Результат — папка с GEO-XXX.geojson (XXX — код ISO3), её передают
tools/build_map.py --adm2 папка.

  python3 tools/fetch_adm2.py --out папка
"""
import argparse
import json
import os
import sys
import time
import subprocess

sys.path.insert(0, os.path.dirname(__file__))
import build_map as bm  # noqa: E402

API = "https://www.geoboundaries.org/api/current/gbOpen/{iso}/{lvl}/"
# коды Natural Earth → ISO3 geoBoundaries, где отличаются
ISO = {"SDS": "SSD", "SAH": "ESH", "KOS": "XKX", "PSX": "PSE", "SOL": "SOM", "CYN": "CYP",
       "KAS": "IND", "KAB": "KAZ", "ALD": "ALA", "ESB": "CYP", "WSB": "CYP", "USG": "CUB"}


def get(url: str) -> bytes:
    # curl: учитывает прокси и сертификаты окружения
    for k in range(4):
        r = subprocess.run(["curl", "-sSfL", "-m", "300", url], capture_output=True)
        if r.returncode == 0:
            return r.stdout
        if k == 3 or r.returncode == 22:   # 22 — ответ 4xx/5xx: не повторять
            raise RuntimeError(r.stderr.decode(errors="replace"))
        print(f"  повтор ({r.stderr.decode(errors='replace').strip()})", flush=True)
        time.sleep(2 * (k + 1))
    return b""


def raw_url(u: str) -> str:
    # github.com/.../raw/... отдаёт LFS-указатель или 403 — берём через media
    if "github.com/wmgeolab/geoBoundaries/raw/" in u:
        return u.replace("https://github.com/wmgeolab/geoBoundaries/raw/",
                         "https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/")
    return u


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    isos = sorted({ISO.get(a, a) for a in bm.ADM0_TAG})
    lic = {}

    def one(iso):
        path = os.path.join(args.out, f"GEO-{iso}.geojson")
        if os.path.exists(path):
            return
        meta = None
        for lvl in ("ADM2", "ADM1"):
            try:
                meta = json.loads(get(API.format(iso=iso, lvl=lvl)))
                if isinstance(meta, dict) and meta.get("simplifiedGeometryGeoJSON"):
                    break
                meta = None
            except Exception:  # noqa: BLE001
                meta = None
        if not meta:
            print(f"{iso}: нет данных", flush=True)
            return
        try:
            data = get(raw_url(meta["simplifiedGeometryGeoJSON"]))
        except Exception as e:  # noqa: BLE001
            print(f"{iso}: не скачан ({e})", flush=True)
            return
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
        lic[iso] = [meta.get("boundaryType"), meta.get("boundaryLicense"), meta.get("boundarySource")]
        print(f"{iso} {meta.get('boundaryType')} {meta.get('admUnitCount')} ({len(data) // 1024} КБ)", flush=True)

    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(6) as ex:
        list(ex.map(one, isos))
    with open(os.path.join(args.out, "licenses.json"), "a") as f:
        json.dump(lic, f, ensure_ascii=False)


if __name__ == "__main__":
    sys.exit(main())
