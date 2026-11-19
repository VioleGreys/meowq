#!/bin/sh
# Декодер AVIF для ядра C++ (тайлы заготовок карты в APK; docs/notes/build.md):
# dav1d 1.4.3 (meson) + libavif 1.0.4 (cmake), статические, только декодер, 8 бит.
# Кладёт в $AVIF_ROOT/linux и $AVIF_ROOT/android (arm64, API 24); затем
# `cd native && scons ...` подхватывает их сам (без них — заглушка: пакеты AVIF
# игра не берёт и рисует тайлы на устройстве).
#   pip install meson; apt-get install cmake ninja-build nasm
#   NDK=/opt/ndk/ndk/28.1.13356709 sh tools/build_avif.sh
set -e
R=${AVIF_ROOT:-/opt/avif}
NDK=${NDK:-/opt/ndk/ndk/28.1.13356709}
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
mkdir -p "$R" && cd "$R"
[ -d dav1d ] || git clone -q --depth 1 -b 1.4.3 https://github.com/videolan/dav1d.git
[ -d libavif ] || git clone -q --depth 1 -b v1.0.4 https://github.com/AOMediaCodec/libavif.git
cat > android.txt <<EOT
[binaries]
c = '$TC/bin/aarch64-linux-android24-clang'
cpp = '$TC/bin/aarch64-linux-android24-clang++'
ar = '$TC/bin/llvm-ar'
strip = '$TC/bin/llvm-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOT
O="-Ddefault_library=static -Denable_tools=false -Denable_tests=false -Denable_examples=false -Dbitdepths=8 --buildtype=release --libdir=lib"
(cd dav1d && meson setup --reconfigure build-linux $O --prefix="$R/linux" >/dev/null && ninja -C build-linux install >/dev/null)
(cd dav1d && meson setup --reconfigure build-android $O --cross-file "$R/android.txt" --prefix="$R/android" >/dev/null && ninja -C build-android install >/dev/null)
C="-DBUILD_SHARED_LIBS=OFF -DAVIF_CODEC_DAV1D=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_BUILD_TYPE=Release -DAVIF_BUILD_APPS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_libyuv=ON"
(cd libavif && cmake -S . -B build-linux $C -DDAV1D_INCLUDE_DIR="$R/linux/include" -DDAV1D_LIBRARY="$R/linux/lib/libdav1d.a" \
	-DCMAKE_INSTALL_PREFIX="$R/linux" >/dev/null && cmake --build build-linux -j4 --target install >/dev/null)
(cd libavif && cmake -S . -B build-android $C -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
	-DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=24 -DDAV1D_INCLUDE_DIR="$R/android/include" \
	-DDAV1D_LIBRARY="$R/android/lib/libdav1d.a" -DCMAKE_INSTALL_PREFIX="$R/android" >/dev/null && cmake --build build-android -j4 --target install >/dev/null)
ls -la "$R"/linux/lib/*.a "$R"/android/lib/*.a
