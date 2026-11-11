# Сборка: C++ (GDExtension) и APK

Заметки для Claude (вынесены из `CLAUDE.md`; указатель — там). Дополнять здесь.

- C++: `native/` — GDExtension `MeowqCore`. Сборка: `pip install scons`,
  godot-cpp (master, `api_version=4.7` задан в native/SConstruct) в `native/godot-cpp`, `cd native && scons
  platform=linux|windows|android [arch=arm64] target=template_debug|template_release`;
  после сборки манифест `meowq.gdextension` копируется в корень (в git не
  попадают ни библиотека, ни манифест). Обёртка `scripts/sim/native.gd`: без
  библиотеки игра работает на GDScript. `-- --no-native` — принудительно без
  библиотеки; perf_bench печатает «Подпись» — с C++ и без она обязана совпадать.
- APK (release, arm64, Android 7+): `GODOT=<путь к godot> sh tools/build_apk.sh` →
  `export/meowq.apk` (`MODE=debug` — отладочный). На телефоне (метка `.mobile` в
  project.godot): рендерер Compatibility (GLES3). Отдельный поток отрисовки
  (`thread_model=2`): на 4.3 телефон не запускался; на 4.7.2 на ПК игра в этом
  режиме падает при запуске примерно в половине случаев (ошибка движка, режим
  экспериментальный). Пробная сборка — `THREADS=separate` (отдельное приложение
  «Meowq (поток)», com.meowq.fronts.thread — ставится рядом с основным). Release-движок: тик без C++ −29%, с C++ −13% (ПК). Нужны шаблоны экспорта 4.7.2 (с GitHub-релиза Godot, в
  `~/.local/share/godot/export_templates/4.7.2.stable`). Android SDK не нужен:
  скрипт делает минимальный «SDK» с обёрткой apksigner на Google apksig 2.3.0
  (Maven Central, подпись v2). C++ под Android: NDK r28b (28.1.13356709, dl.google.com
  открыт) в `/opt/ndk/ndk/28.1.13356709`, `ANDROID_HOME=/opt/ndk scons platform=android
  arch=arm64 target=template_release`; `build_apk.sh` кладёт ядро в APK, если библиотека
  собрана (иначе APK на GDScript). В нижней строке игры — «C++» или «GDScript».
