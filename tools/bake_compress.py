#!/usr/bin/env python3
"""Сжатие пакетов заготовок карты для APK (MapBake, docs/notes/ui.md).

Игра рисует пакеты без потерь (`--bake_pack=DIR`, WebP lossless, ~110 МБ);
здесь каждый тайл пережимается cwebp с потерями: цвет V — q95 с точным
пересчётом цвета (-sharp_yuv), альфа (1 − S/2) — без потерь, цвет под
прозрачным не трогается (-exact). Ошибка цвета карты — в среднем ~2 уровня
из 255, на глаз не видна; объём — в ~3 раза меньше. Ссылки «зима как лето»
сохраняются.

  sudo apt-get install webp
  python3 tools/bake_compress.py RAW_DIR data/bake [--q=95]
"""
import os
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor


def read_pack(path):
    d = open(path, "rb").read()
    assert d[:4] == b"MQB1", path
    o = 4
    n = struct.unpack_from("<I", d, o)[0]
    head_end = o + 4 + n + 4 + 8
    w, h = struct.unpack_from("<II", d, head_end - 8)
    tab = [struct.unpack_from("<Ii", d, head_end + i * 8) for i in range(w * h)]
    tiles = [d[off:off + sz] if sz > 0 else sz for off, sz in tab]
    return d[:head_end], w, h, tiles


def recode(blob, q, tmp, i):
    src = os.path.join(tmp, "%d.webp" % i)
    png = os.path.join(tmp, "%d.png" % i)
    dst = os.path.join(tmp, "%d_o.webp" % i)
    open(src, "wb").write(blob)
    subprocess.run(["dwebp", "-quiet", src, "-o", png], check=True)
    subprocess.run(["cwebp", "-quiet", "-q", str(q), "-sharp_yuv", "-alpha_q", "100",
                    "-exact", "-m", "6", png, "-o", dst], check=True)
    out = open(dst, "rb").read()
    for p in (src, png, dst):
        os.remove(p)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    q = 95
    for a in sys.argv[1:]:
        if a.startswith("--q="):
            q = int(a.split("=")[1])
    src_dir, out_dir = args
    os.makedirs(out_dir, exist_ok=True)
    total_in = total_out = 0
    with tempfile.TemporaryDirectory() as tmp, ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        for fn in sorted(os.listdir(src_dir)):
            if not (fn.startswith("b") and fn.endswith(".bin")):
                continue
            head, w, h, tiles = read_pack(os.path.join(src_dir, fn))
            jobs = {i: ex.submit(recode, t, q, tmp, i) for i, t in enumerate(tiles) if isinstance(t, bytes)}
            body = bytearray()
            tab = bytearray()
            base = len(head) + w * h * 8
            for i, t in enumerate(tiles):
                if isinstance(t, bytes):
                    b = jobs[i].result()
                    tab += struct.pack("<Ii", base + len(body), len(b))
                    body += b
                else:
                    tab += struct.pack("<Ii", 0, t)
            with open(os.path.join(out_dir, fn), "wb") as f:
                f.write(head)
                f.write(tab)
                f.write(body)
            sin = os.path.getsize(os.path.join(src_dir, fn))
            sout = os.path.getsize(os.path.join(out_dir, fn))
            total_in += sin
            total_out += sout
            print("%s: %.1f → %.1f МБ" % (fn, sin / 1048576, sout / 1048576), flush=True)
    print("всего: %.1f → %.1f МБ" % (total_in / 1048576, total_out / 1048576))


if __name__ == "__main__":
    main()
