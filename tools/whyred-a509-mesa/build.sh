#!/usr/bin/env bash
# Separate build experiment. Does NOT install into iOS or activate old GPU backend.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
V=25.0.7
SHA=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
WORK=${WHYRED_MESA_WORK:-$(mktemp -d)}
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
cd "$WORK"
A="mesa-$V.tar.xz"
if [ ! -s "$A" ]; then curl --fail --location --retry 3 -o "$A.part" "https://archive.mesa3d.org/$A"; mv "$A.part" "$A"; fi
printf '%s  %s\n' "$SHA" "$A" | shasum -a 256 -c
if [ -e "mesa-$V" ]; then echo 'Use a fresh WHYRED_MESA_WORK; refusing to modify an existing source tree';exit 1;fi
tar -xJf "$A"
python3 "$HERE/prepare.py" --repo "$ROOT" --source "$WORK/mesa-$V"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang);CXX=$(xcrun --sdk iphoneos -f clang++)
python3 -m venv "$WORK/venv";source "$WORK/venv/bin/activate"
python -m pip install 'meson>=1.4,<2' ninja mako pyyaml packaging
cat > cross.ini <<INI
[binaries]
c = ['$CC', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK']
cpp = ['$CXX', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK', '-fuse-cxa-atexit']
objc = ['$CC', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK']
ar = '$(xcrun -f ar)'
ranlib = '$(xcrun -f ranlib)'
strip = '$(xcrun -f strip)'
pkg-config = 'false'
[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
INI
export PATH="$(brew --prefix bison)/bin:$PATH"
meson setup build "mesa-$V" --cross-file cross.ini --wrap-mode=nofallback \
 --prefix=/topaz --libdir=lib --buildtype=release -Db_ndebug=true \
 -Dplatforms= -Dgallium-drivers=softpipe,freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers= \
 -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dosmesa=true -Dllvm=disabled \
 -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
 -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dshader-cache=disabled \
 -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= -Dtools= \
 -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled -Dlmsensors=disabled -Dbuild-tests=false
ninja -C build
OUT="$HERE/out";mkdir -p "$OUT"
LIB=build/src/gallium/targets/osmesa/libOSMesa.8.dylib
test -s "$LIB"
# Verify actual A5xx compilation rather than just building software rasterizer.
grep -q 'freedreno/a5xx/' build/compile_commands.json
cp -L "$LIB" "$OUT/libOSMesa.8.dylib"
install_name_tool -id /topaz/lib/libOSMesa.8.dylib "$OUT/libOSMesa.8.dylib"
codesign --force --sign - "$OUT/libOSMesa.8.dylib"
xcrun nm -gU "$OUT/libOSMesa.8.dylib" > "$OUT/symbols.txt"
xcrun vtool -show-build "$OUT/libOSMesa.8.dylib" > "$OUT/platform.txt"
cp "mesa-$V/src/mapi/glapi/registry/gl.xml" "$OUT/gl.xml"
(cd "$OUT";shasum -a 256 libOSMesa.8.dylib symbols.txt platform.txt gl.xml > SHA256SUMS)
echo MESA_SOURCE_BUILD_PASS_NOT_RUNTIME_READY
