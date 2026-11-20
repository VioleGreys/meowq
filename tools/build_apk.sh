#!/bin/sh
# Сборка отладочного APK без Android SDK (когда dl.google.com недоступен).
# Нужны: Godot 4.7.2 (путь в $GODOT), Java 17+, шаблоны экспорта 4.7.2 в
# ~/.local/share/godot/export_templates/4.7.2.stable (android_debug.apk и др.).
# Подпись — библиотекой Google apksig 2.3.0 с Maven Central (только схема v2:
# APK ставится на Android 7+). Нативная библиотека (native/) в APK не входит —
# под Android её собирают с NDK; без неё игра работает на GDScript.
#   GODOT=/путь/к/godot sh tools/build_apk.sh  →  export/meowq.apk
# По умолчанию — release (GDScript быстрее на ~30%; подпись тем же отладочным
# ключом, чтобы ставилось поверх); MODE=debug — отладочный. Рендерер и поток
# отрисовки на телефоне заданы в project.godot (метка .mobile: Compatibility,
# отдельный поток); для сравнения: RENDERER=compat — принудительно GLES3,
# THREADS=separate (отрисовка в отдельном потоке — разгружает главный поток),
# OUT=export/имя.apk.
set -e
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
MODE=${MODE:-release}
RENDERER=${RENDERER:-mobile}
THREADS=${THREADS:-safe}
OUT=${OUT:-export/meowq.apk}
WORK=${WORK:-/tmp/meowq-apk}
SDK="$WORK/android-sdk"
BT="$SDK/build-tools/34.0.0"
mkdir -p "$BT/classes" "$SDK/platform-tools" export
if [ ! -f "$BT/apksig.jar" ]; then
	curl -sSL -o "$BT/apksig.jar" https://repo1.maven.org/maven2/com/android/tools/build/apksig/2.3.0/apksig-2.3.0.jar
	echo "$(curl -sSL https://repo1.maven.org/maven2/com/android/tools/build/apksig/2.3.0/apksig-2.3.0.jar.sha1)  $BT/apksig.jar" | sha1sum -c
fi
javac -cp "$BT/apksig.jar" -d "$BT/classes" tools/apk/MiniApkSigner.java
cat > "$BT/apksigner" <<'EOS'
#!/bin/sh
D=$(dirname "$0")
case "$1" in --version|version) echo "0.9"; exit 0;; esac
exec java --add-exports java.base/sun.security.x509=ALL-UNNAMED --add-exports java.base/sun.security.pkcs=ALL-UNNAMED \
	--add-exports java.base/sun.security.util=ALL-UNNAMED -cp "$D/apksig.jar:$D/classes" MiniApkSigner "$@"
EOS
chmod +x "$BT/apksigner"
printf '#!/bin/sh\nexit 0\n' > "$SDK/platform-tools/adb"
chmod +x "$SDK/platform-tools/adb"
# путь к «SDK» — в настройки редактора Godot
CFG=$(ls -t "$HOME"/.config/godot/editor_settings-4.*.tres 2>/dev/null | head -1)
if [ -f "$CFG" ]; then
	sed -i "s#^export/android/android_sdk_path = .*#export/android/android_sdk_path = \"$SDK\"#" "$CFG"
fi
# C++-ядро (native/bin/libmeowq.android.*.arm64.so) попадает в APK, если собрано
# (scons platform=android arch=arm64, нужен NDK 23.2); иначе манифест убираем —
# без библиотеки Godot выдал бы ошибку загрузки, игра идёт на GDScript
MANIFEST_MOVED=0
if [ -f native/bin/libmeowq.android.template_debug.arm64.so ]; then
	cp native/meowq.gdextension.in meowq.gdextension
	echo "C++-ядро: включено"
elif [ -f meowq.gdextension ]; then
	mv meowq.gdextension "$WORK/meowq.gdextension"; MANIFEST_MOVED=1
	echo "C++-ядро: нет сборки под Android, APK на GDScript"
fi
cp project.godot "$WORK/project.godot.bak"
cp export_presets.cfg "$WORK/export_presets.cfg.bak"
if [ "$THREADS" = separate ]; then
	# пробная сборка — отдельное приложение рядом с основным: если не запустится,
	# основное остаётся как было
	sed -i 's#^package/unique_name=.*#package/unique_name="com.meowq.fronts.thread"#; s#^package/name=.*#package/name="Meowq (поток)"#' export_presets.cfg
	sed -i 's#^\[rendering\]$#[rendering]\n\ndriver/threads/thread_model=2\ndriver/threads/thread_model.mobile=2#' project.godot
	echo "Отрисовка: отдельный поток"
fi
if [ "$RENDERER" = compat ]; then
	sed -i 's#^renderer/rendering_method=.*#renderer/rendering_method="gl_compatibility"#; s#^renderer/rendering_method.mobile=.*#renderer/rendering_method.mobile="gl_compatibility"#' project.godot
	echo "Рендерер: Compatibility (OpenGL ES 3)"
fi
"$GODOT" --headless --editor --quit --path . >/dev/null 2>&1 || true
# графика карты (assets/map, 4 × 40 МБ .ctex — Godot кладёт их в APK без сжатия) —
# в APK упакованной zstd (~51 МБ, data/art; tools/pack_art.gd); assets/map
# исключён из экспорта (export_presets.cfg)
"$GODOT" --headless --path . --script res://tools/pack_art.gd 2>&1 | grep -E "pack_art: всего|ERROR"
for k in colormap_w.webp colormap_e.webp normal_w.png normal_e.png; do
	[ -s "data/art/$k.etc2.zst" ] || { echo "Нет data/art/$k.etc2.zst — APK без графики карты не собираем"; exit 1; }
	[ "data/art/$k.etc2.zst" -nt "assets/map/$k" ] || { echo "data/art/$k.etc2.zst старее assets/map/$k"; exit 1; }
done
# заготовки карты для всех масштабов до ×5.6 (MapBake, docs/notes/ui.md): рисует
# сама игра (нужен экран — xvfb-run) без потерь, по уровню за раз (ближние без потерь —
# гигабайты), tools/bake_compress.py сразу пережимает в AVIF (нужен avifenc:
# apt-get install libavif-bin). Читает их ядро C++ (декодер AVIF) — без него игра
# пакеты не берёт. Пересобираются, если шейдер, модуль или данные карты новее
# пакетов; BAKE=0 — без заготовок (карта рисуется вживую)
if [ "${BAKE:-1}" = 1 ]; then
	[ -f native/bin/libmeowq.android.template_release.arm64.so ] || { echo "Нет ядра C++ под Android (декодер AVIF для заготовок): docs/notes/build.md"; exit 1; }
	STALE=0
	[ -f data/bake/b0_11.bin ] || STALE=1
	for f in shaders/map_core.gdshaderinc scripts/view/map_bake.gd tools/bake_compress.py data/world1936/*.bin assets/map/*; do
		[ "$STALE" = 1 ] || [ ! "$f" -nt data/bake/b0_11.bin ] || STALE=1
	done
	if [ "$STALE" = 1 ]; then
		echo "Заготовки карты: рисуются..."
		rm -rf data/bake
		for k in 0 1 2 3 4 5 6 7 8 9 10 11; do
			rm -rf "$WORK/bake_raw" && mkdir -p "$WORK/bake_raw"
			xvfb-run -a "$GODOT" --rendering-driver opengl3 --path . -- --screenshot="$WORK/bake.png" --nation=GER --days=1 \
				--bake_pack="$WORK/bake_raw" --bake_levels=$k 2>&1 | grep -E "^bake: всего|SCRIPT ERROR" || true
			python3 tools/bake_compress.py "$WORK/bake_raw" data/bake | tail -1
		done
		rm -rf "$WORK/bake_raw"
	fi
	du -sh data/bake
	# ближние уровни (k ≥ 7, ×1.4 и ближе) — не в APK, а на докачку: части в
	# export/bake-data (отправка — sh tools/publish_bake.sh), список —
	# data/bake_remote.json в APK (решение пользователя, ноябрь 2026); REMOTE=0 — всё в APK
	if [ "${REMOTE:-1}" = 1 ]; then
		python3 tools/bake_split.py data/bake "$WORK/bake_remote" export/bake-data --min-k=7
	fi
else
	mv data/bake "$WORK/bake_off" 2>/dev/null || true
fi
if [ "$MODE" = release ]; then
	KS="$HOME/.local/share/godot/keystores/debug.keystore"
	export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS"
	export GODOT_ANDROID_KEYSTORE_RELEASE_USER=androiddebugkey
	export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=android
	"$GODOT" --headless --path . --export-release "Android" "$OUT" 2>&1 | grep -E "Signed|ERROR|export: end" || true
else
	"$GODOT" --headless --path . --export-debug "Android" "$OUT" 2>&1 | grep -E "Signed|ERROR|export: end" || true
fi
cp "$WORK/project.godot.bak" project.godot
cp "$WORK/export_presets.cfg.bak" export_presets.cfg
if [ "$MANIFEST_MOVED" = 1 ]; then mv "$WORK/meowq.gdextension" meowq.gdextension; fi
if [ -d "$WORK/bake_off" ]; then mv "$WORK/bake_off" data/bake; fi
if [ -d "$WORK/bake_remote" ]; then mv "$WORK/bake_remote"/* data/bake/ && rmdir "$WORK/bake_remote"; fi
rm -f data/bake_remote.json
ls -la "$OUT"
