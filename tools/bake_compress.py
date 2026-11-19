#!/usr/bin/env python3
"""Сжатие пакетов заготовок карты для APK (MapBake, docs/notes/ui.md).

Игра рисует пакеты без потерь (`--bake_pack=DIR [--bake_levels=k]`, WebP
lossless); здесь каждый тайл пережимается в AVIF (avifenc, 4:4:4, -s 6,
цвет q78, альфа (1 − S/2) q80). Читает их ядро C++ (MeowqCore.avif_rgba:
libavif + dav1d) — без него игра пакеты AVIF не берёт.

Выбор по замеру (ноябрь 2026, optimization.md шаг 14): ошибка итогового цвета
карты как у WebP q90 с альфой a70 (в среднем ~3 уровня из 255, 99% ≤ 12), а
вес на ~38 % меньше (6.0 против 9.7 КБ на тайл); JPEG XL при той же ошибке
тяжелее. -s 4 даёт ещё −7 %, но кодирует в 6 раз дольше.
Ссылки «зима как лето» сохраняются. Пакет читается по тайлам (ближние уровни
без потерь — гигабайты).

  sudo apt-get install libavif-bin webp
  python3 tools/bake_compress.py RAW_DIR data/bake [--q=78 --aq=80 --speed=6]
"""
import os
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor


def read_head(f):
    """Заголовок пакета и таблица [(смещение, размер)]; размер ≤ 0 — пусто/ссылка."""
    f.seek(0)
    d = f.read(4)
    assert d == b"MQB1", f.name
    n = struct.unpack("<I", f.read(4))[0]
    f.read(n)
    f.read(4)
    w, h = struct.unpack("<II", f.read(8))
    head_end = f.tell()
    tab = [struct.unpack_from("<Ii", f.read(8)) for _ in range(w * h)]
    f.seek(0)
    head = f.read(head_end)
    return head, w, h, tab


def read_pack(path):
    """Весь пакет: (заголовок, w, h, [байты тайла | размер ≤ 0]) — для оценок."""
    with open(path, "rb") as f:
        head, w, h, tab = read_head(f)
        tiles = []
        for off, sz in tab:
            if sz > 0:
                f.seek(off)
                tiles.append(f.read(sz))
            else:
                tiles.append(sz)
    return head, w, h, tiles


def recode(blob, opt, tmp, i):
    src = os.path.join(tmp, "%d.webp" % i)
    png = os.path.join(tmp, "%d.png" % i)
    dst = os.path.join(tmp, "%d.avif" % i)
    open(src, "wb").write(blob)
    subprocess.run(["dwebp", "-quiet", src, "-o", png], check=True)
    subprocess.run(["avifenc", "-j", "1", "-s", str(opt["speed"]), "-y", "444", "-q", str(opt["q"]),
                    "--qalpha", str(opt["aq"]), png, dst], check=True, stdout=subprocess.DEVNULL)
    out = open(dst, "rb").read()
    for p in (src, png, dst):
        os.remove(p)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opt = {"q": 78, "aq": 80, "speed": 6}
    for a in sys.argv[1:]:
        for k in opt:
            if a.startswith("--%s=" % k):
                opt[k] = int(a.split("=")[1])
    src_dir, out_dir = args
    os.makedirs(out_dir, exist_ok=True)
    total_in = total_out = 0
    chunk = 1024
    with tempfile.TemporaryDirectory() as tmp, ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for fn in sorted(os.listdir(src_dir)):
            if not (fn.startswith("b") and fn.endswith(".bin")):
                continue
            src = os.path.join(src_dir, fn)
            dst = os.path.join(out_dir, fn)
            with open(src, "rb") as fi, open(dst, "wb") as fo:
                head, w, h, tab = read_head(fi)
                fo.write(head)
                fo.write(b"\0" * (w * h * 8))   # таблица — в конце
                out_tab = bytearray()
                pos = len(head) + w * h * 8
                for c0 in range(0, len(tab), chunk):
                    part = tab[c0:c0 + chunk]
                    jobs = {}
                    for j, (off, sz) in enumerate(part):
                        if sz > 0:
                            fi.seek(off)
                            jobs[j] = ex.submit(recode, fi.read(sz), opt, tmp, c0 + j)
                    for j, (off, sz) in enumerate(part):
                        if sz > 0:
                            b = jobs[j].result()
                            out_tab += struct.pack("<Ii", pos, len(b))
                            fo.write(b)
                            pos += len(b)
                        else:
                            out_tab += struct.pack("<Ii", 0, sz)
                fo.seek(len(head))
                fo.write(out_tab)
            sin = os.path.getsize(src)
            sout = os.path.getsize(dst)
            total_in += sin
            total_out += sout
            print("%s: %.1f → %.1f МБ" % (fn, sin / 1048576, sout / 1048576), flush=True)
    print("всего: %.1f → %.1f МБ" % (total_in / 1048576, total_out / 1048576))


if __name__ == "__main__":
    main()
