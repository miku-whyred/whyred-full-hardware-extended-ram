#!/bin/bash
# Build the separate, read-only HFS+ disk that the FD509 profile carries in boot.
set -euo pipefail
upstream=$(cd "${1:?pinned upstream checkout}" && pwd)
dest=${2:?output directory}
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
suite=$tmp/volume
mkdir -p "$suite" "$tmp/bin"
cd "$upstream"
test "$(git rev-parse HEAD)" = 9b18976b9022fd244eda02071a342a3621b7862b
cc=(xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2)
artifact=15213362248
digest=d57752d3c75820e45b643b34ce0a28cf6b1e652c51b8870f0eb7837ce26239cd
# Prefer the authors' byte-verified Mesa build. Rebuild from the pinned tree after artifact expiry.
if gh api "repos/m-obeid/ios-whyred/actions/artifacts/$artifact/zip" > "$tmp/gl.zip" &&
    echo "$digest  $tmp/gl.zip" | shasum -a 256 -c --status; then
    unzip -q "$tmp/gl.zip" -d "$tmp/bin"
    (cd "$tmp/bin" && shasum -a 256 -c SHA256SUMS)
    cp "$tmp/bin/topaz/lib/libOSMesa.8.dylib" "$tmp/bin/topaz/lib/libtopaz-gl.dylib" "$tmp/bin/bin/gltest" "$suite/"
else
    brew install bison flex
    bash userland/mesa/mk-mesa-mac.sh
    mesa=userland/mesa/build-mesa
    python3 userland/gpu/mkeagl.py userland/gpu/eagl_slots.txt "$mesa/out/gl.xml" \
        "$mesa/out/exported-gl.txt" userland/gpu/eagl.c > "$tmp/eagl_gen.h"
    cp "$mesa/out/libOSMesa.8.dylib" "$suite/"
    "${cc[@]}" -dynamiclib -install_name /dev/wgl/libtopaz-gl.dylib -I "$tmp" -I userland/gpu \
        -I "$mesa/mesa-25.0.7/include" -framework CoreFoundation -framework IOKit -framework IOSurface \
        -lobjc "$suite/libOSMesa.8.dylib" -o "$suite/libtopaz-gl.dylib" userland/gpu/{eagl,gl_osmesa}.c
    "${cc[@]}" -I "$mesa/mesa-25.0.7/include" -o "$suite/gltest" userland/gpu/gltest.c "$suite/libOSMesa.8.dylib"
fi
# Point the two runtime dlopen calls at the mounted disk. Keep their ABI and symbol table.
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
for source, old, new in [
    ("whyred/userland/whyred_ui.c", 'dlopen("/topaz/lib/libtopaz-inject.dylib"', 'dlopen("/dev/wgl/libtopaz-inject.dylib"'),
    ("userland/gpu/topaz_inject.c", '#define TOPAZ_GL "/topaz/lib/libtopaz-gl.dylib"', '#define TOPAZ_GL "/dev/wgl/libtopaz-gl.dylib"'),
]:
    data = Path(source).read_text()
    if data.count(old) != 1:
        raise ValueError(source)
    (out / Path(source).name).write_text(data.replace(old, new))
PY
"${cc[@]}" -dynamiclib -ffreestanding -fno-stack-protector -fvisibility=hidden \
    -install_name /dev/wgl/whyred_ui.dylib -framework IOKit -framework CoreFoundation -framework AudioToolbox \
    -lobjc "$tmp/whyred_ui.c" -o "$suite/whyred_ui.dylib"
"${cc[@]}" -dynamiclib -install_name /dev/wgl/libtopaz-inject.dylib -framework CoreFoundation -framework IOKit \
    -lobjc "$tmp/topaz_inject.c" -o "$suite/libtopaz-inject.dylib"
xcrun install_name_tool -id /dev/wgl/libOSMesa.8.dylib "$suite/libOSMesa.8.dylib"
xcrun install_name_tool -id /dev/wgl/libtopaz-gl.dylib -change /topaz/lib/libOSMesa.8.dylib \
    /dev/wgl/libOSMesa.8.dylib "$suite/libtopaz-gl.dylib"
xcrun install_name_tool -change /topaz/lib/libOSMesa.8.dylib /dev/wgl/libOSMesa.8.dylib "$suite/gltest"
for f in "$suite"/*; do
    chmod 0555 "$f"
    codesign --force --sign - "$f"
    codesign --verify --strict "$f"
    deps=$(otool -L "$f")
    if [[ "$deps" == *"/topaz/lib/"* ]]; then echo "$deps" >&2; exit 1; fi
done
(cd "$suite" && shasum -a 256 *.dylib gltest > "$dest/graphics-files.sha256")
hdiutil create -quiet -size 28m -layout NONE -fs HFS+ -volname WHYREDGL -srcfolder "$suite" -format UDRW "$tmp/graphics.dmg"
hdiutil convert -quiet "$tmp/graphics.dmg" -format UDTO -o "$tmp/graphics.cdr"
mv "$tmp/graphics.cdr" "$dest/whyred-graphics.hfs"
python3 - "$dest/whyred-graphics.hfs" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
with p.open('rb') as f:
    f.seek(1024)
    assert f.read(2) in (b'H+', b'HX')
assert 15 << 20 < p.stat().st_size <= 32 << 20
PY
# Confirm the final conversion contains each signed binary at its expected absolute path.
mkdir "$tmp/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$tmp/mounted" "$dest/whyred-graphics.hfs"
(cd "$tmp/mounted" && shasum -a 256 -c "$dest/graphics-files.sha256")
hdiutil detach "$tmp/mounted"
(cd "$dest" && shasum -a 256 whyred-graphics.hfs > SHA256SUMS)
