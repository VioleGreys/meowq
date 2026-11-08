#!/bin/sh
# Сборка отладочного APK без Android SDK (когда dl.google.com недоступен).
# Нужны: Godot 4.3 (путь в $GODOT), Java 17+, шаблоны экспорта 4.3 в
# ~/.local/share/godot/export_templates/4.3.stable (android_debug.apk и др.).
# Подпись — библиотекой Google apksig 2.3.0 с Maven Central (только схема v2:
# APK ставится на Android 7+). Нативная библиотека (native/) в APK не входит —
# под Android её собирают с NDK; без неё игра работает на GDScript.
#   GODOT=/путь/к/godot sh tools/build_apk.sh  →  export/meowq.apk
set -e
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
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
CFG="$HOME/.config/godot/editor_settings-4.3.tres"
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
"$GODOT" --headless --editor --quit --path . >/dev/null 2>&1 || true
"$GODOT" --headless --path . --export-debug "Android" export/meowq.apk 2>&1 | grep -E "Signed|ERROR|export: end" || true
if [ "$MANIFEST_MOVED" = 1 ]; then mv "$WORK/meowq.gdextension" meowq.gdextension; fi
ls -la export/meowq.apk
