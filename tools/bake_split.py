#!/usr/bin/env python3
"""Пакеты заготовок ближних масштабов — не в APK, а на докачку (решение пользователя,
ноябрь 2026: ветка bake-data репозитория на GitHub, кнопка в «Настройках»).

  python3 tools/bake_split.py BAKE_DIR MOVE_DIR OUT_DIR [--min-k=7] [--part-mb=19]

Пакеты BAKE_DIR/b{s}_{k}.bin с k >= min-k переносятся в MOVE_DIR (build_apk.sh
возвращает их после экспорта — для проверки свежести пакетов), их части
(≤ part-mb МБ: GitHub не берёт файлы > 100 МБ, CDN jsDelivr — > 20 МБ) пишутся в OUT_DIR/<версия>/, а
список — в data/bake_remote.json (идёт в APK; читает scripts/view/bake_download.gd).
Версия — первые 12 знаков SHA-1 от метки пакета (шейдер и данные карты): новая
сборка карты — новая папка, старый APK не скачает чужие пакеты.
"""
import hashlib, json, os, shutil, struct, sys

REPO = "VioleGreys/meowq"
BRANCH = "bake-data"


def pack_version(path):
	with open(path, "rb") as f:
		if f.read(4) != b"MQB1":
			raise SystemExit("не пакет: " + path)
		n = struct.unpack("<I", f.read(4))[0]
		return f.read(n).decode()


def main():
	args = [a for a in sys.argv[1:] if not a.startswith("--")]
	opt = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--"))
	bake, move, out = args
	min_k = int(opt.get("min-k", 7))
	part = int(float(opt.get("part-mb", 19)) * 1048576)
	names = []
	for fn in sorted(os.listdir(bake)):
		if fn.startswith("b") and fn.endswith(".bin"):
			k = int(fn[:-4].split("_")[1])
			if k >= min_k:
				names.append((k, fn))
	names.sort()
	if not names:
		raise SystemExit("нет пакетов k >= %d" % min_k)
	vers = {pack_version(os.path.join(bake, fn)) for _, fn in names}
	if len(vers) != 1:
		raise SystemExit("пакеты разных версий: %s" % vers)
	vid = hashlib.sha1(vers.pop().encode()).hexdigest()[:12]
	vdir = os.path.join(out, vid)
	shutil.rmtree(out, ignore_errors=True)
	os.makedirs(vdir)
	os.makedirs(move, exist_ok=True)
	files = []
	total = 0
	for _, fn in names:
		src = os.path.join(bake, fn)
		size = os.path.getsize(src)
		parts = []
		with open(src, "rb") as f:
			i = 0
			while True:
				b = f.read(part)
				if not b:
					break
				pn = "%s.%03d" % (fn, i)
				with open(os.path.join(vdir, pn), "wb") as w:
					w.write(b)
				parts.append({"name": pn, "size": len(b), "sha256": hashlib.sha256(b).hexdigest()})
				i += 1
		files.append({"name": fn, "size": size, "parts": parts})
		total += size
		shutil.move(src, os.path.join(move, fn))
	# зеркала: GitHub напрямую и CDN jsDelivr (тот же GitHub; одно соединение с
	# raw на телефоне давало ~50–80 КБ/с) — игра берёт быстрейшее по замеру
	mirrors = ["https://raw.githubusercontent.com/%s/%s/%s/" % (REPO, BRANCH, vid),
		"https://cdn.jsdelivr.net/gh/%s@%s/%s/" % (REPO, BRANCH, vid)]
	man = {"base": mirrors[0], "mirrors": mirrors, "version": vid, "files": files}
	with open("data/bake_remote.json", "w") as f:
		json.dump(man, f, ensure_ascii=False, indent=1)
	print("bake_split: %d файлов, %.1f МБ на докачку → %s" % (len(files), total / 1048576, vdir))


main()
