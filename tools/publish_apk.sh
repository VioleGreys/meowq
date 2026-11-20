#!/bin/sh
# APK — в ветку apk репозитория (решение пользователя, ноябрь 2026): GitHub не берёт
# файлы > 100 МБ, релиз отсюда не создать — поэтому разделённый ZIP по 70 МБ
# (meowq_apk.zip + meowq_apk.z01 …; ZArchiver на телефоне открывает сразу).
# Ветка без истории кода, заменяется целиком.
#   sh tools/publish_apk.sh [export/meowq.apk]
set -e
APK=${1:-export/meowq.apk}
[ -f "$APK" ] || { echo "Нет $APK — сначала sh tools/build_apk.sh"; exit 1; }
URL=$(git remote get-url origin)
NAME=$(git config user.name)
MAIL=$(git config user.email)
REV=$(git rev-parse --short HEAD)
OUT=export/apk-branch
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$APK" "$OUT/meowq.apk"
(cd "$OUT" && zip -q -0 -s 70m meowq_apk.zip meowq.apk && rm meowq.apk)
SIZE=$(du -m "$APK" | cut -f1)
cat > "$OUT/README.md" <<EOF
# Meowq: Фронты — APK

Сборка из коммита $REV ветки разработки, $(date -u +%Y-%m-%d), APK ${SIZE} МБ.
Файл больше предела GitHub (100 МБ), поэтому лежит разделённым ZIP-архивом:

1. Скачать **все** части: \`meowq_apk.zip\`, \`meowq_apk.z01\` (и следующие, если есть) —
   в одну папку.
2. Открыть \`meowq_apk.zip\` в ZArchiver (или другом архиваторе с поддержкой
   разделённых ZIP), распаковать \`meowq.apk\` и установить.

Карта высокого качества докачивается в игре: «Настройки» → «Карта высокого качества».
EOF
cd "$OUT"
git init -q -b apk
git add -A
git -c user.name="$NAME" -c user.email="$MAIL" commit -q -m "APK из $REV"
n=0
until git push -q --force "$URL" apk:apk; do
	n=$((n + 1)); [ $n -ge 4 ] && exit 1
	sleep $((n * 5))
done
rm -rf .git
ls -la
echo "apk: отправлено"
