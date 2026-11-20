#!/bin/sh
# Пакеты заготовок на докачку (export/bake-data/<версия>/, пишет tools/bake_split.py
# при сборке APK) — в ветку bake-data репозитория (решение пользователя, ноябрь 2026).
# Ветка без истории кода и заменяется целиком: каждая сборка карты — одна новая
# версия, прежние APK с новой веткой не скачают (их пакеты удалены).
#   sh tools/publish_bake.sh
set -e
SRC=${SRC:-export/bake-data}
[ -d "$SRC" ] || { echo "Нет $SRC — сначала BAKE=1 sh tools/build_apk.sh"; exit 1; }
URL=$(git remote get-url origin)
cd "$SRC"
rm -rf .git
git init -q -b bake-data
cat > README.md <<'EOF'
Пакеты заготовок карты Meowq ближних масштабов (AVIF), части ≤ 50 МБ.
Скачивает игра: «Настройки» → «Карта высокого качества». Ветка заменяется целиком
при каждой сборке карты (tools/publish_bake.sh в основной ветке).
EOF
git add -A
git -c user.name="$(git -C "$OLDPWD" config user.name)" -c user.email="$(git -C "$OLDPWD" config user.email)" \
	commit -q -m "Пакеты заготовок карты: $(ls -d */ | tr -d /)"
n=0
until git push -q --force "$URL" bake-data:bake-data; do
	n=$((n + 1)); [ $n -ge 4 ] && exit 1
	sleep $((n * 5))
done
rm -rf .git
echo "bake-data: отправлено $(du -sh . | cut -f1)"
