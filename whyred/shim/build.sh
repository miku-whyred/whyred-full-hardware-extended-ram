#!/bin/bash
# Build the whyred shim as an Android boot image (header v0, gzip Image + appended DTB),
# the same layout as the stock whyred boot.img. Run with: fastboot boot out/shim-boot.img
# ./build.sh                 diagnostics only (milestone 1)
# ./build.sh PAYLOAD.bin     boot XNU: the payload (tools/mkpayload.py) becomes the ramdisk
# EMMC=1 ./build.sh          read-only eMMC probe instead of the diagnostics
# OSM=1 ./build.sh           read-only Gold clock/voltage probe (OSM, CPRH, PLL)
# OSM=1 OSM_TARGET=n          also bring up CPRH (open loop) + OSM and request table row n
# CPRH_OL=1                   CPRH open loop (fused ceiling voltages) instead of the hardware closed loop
# MSS=1 ./build.sh ../firmware/modem/mba.mbn   modem MBA boot probe (step 1a), ramdisk = mba.mbn
# GOLD_ROW=n ./build.sh PAYLOAD   Gold OSM row before XNU (default 4 = 1804.8 MHz, 0 = leave at 600 MHz)
set -euo pipefail
cd "$(dirname "$0")"

CC=${CROSS:-aarch64-linux-gnu-}gcc
OBJCOPY=${CROSS:-aarch64-linux-gnu-}objcopy
NM=${CROSS:-aarch64-linux-gnu-}nm
READELF=${CROSS:-aarch64-linux-gnu-}readelf
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -fno-pie -mgeneral-regs-only -mstrict-align \
	-fno-stack-protector -fno-tree-loop-distribute-patterns -Wall -Wextra -Werror"
DTB=dtb/whyred.dtb
FONT=${FONT:-/usr/share/kbd/consolefonts/default8x16.psfu.gz}

OUT=${WHYRED_SHIM_OUT:-out}
mkdir -p "$OUT"
[ -f font.h ] || python3 gen_font.py "$FONT"

$CC $CFLAGS -c start.S -o "$OUT/start.o"
$CC $CFLAGS ${EMMC:+-DEMMC_PROBE} ${OSM:+-DOSM_PROBE} ${MSS:+-DMSS_PROBE} ${SCALE:+-DSCALE=$SCALE} ${OSM_TARGET:+-DOSM_TARGET=$OSM_TARGET} ${GOLD_ROW:+-DGOLD_ROW=$GOLD_ROW} -c main.c -o "$OUT/main.o"
$CC $CFLAGS ${CPRH_OL:+-DCPRH_OL} -c osm.c -o "$OUT/osm.o"
$CC $CFLAGS -c xnu.c -o "$OUT/xnu.o"
$CC $CFLAGS -c emmc.c -o "$OUT/emmc.o"
$CC $CFLAGS -c mss.c -o "$OUT/mss.o"
$CC $CFLAGS -c fat.c -o "$OUT/fat.o"

# The image runs wherever ABL loads it. Only the header's image_size may be absolute.
abs=$($READELF -r "$OUT/main.o" "$OUT/xnu.o" "$OUT/emmc.o" "$OUT/osm.o" "$OUT/mss.o" "$OUT/fat.o" | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }

$CC $CFLAGS -static -no-pie -T shim.ld -Wl,--build-id=none -Wl,-N -Wl,--no-warn-rwx-segments \
	"$OUT/start.o" "$OUT/main.o" "$OUT/xnu.o" "$OUT/emmc.o" "$OUT/osm.o" "$OUT/mss.o" "$OUT/fat.o" -o "$OUT/shim.elf"
$OBJCOPY -O binary "$OUT/shim.elf" "$OUT/Image"
# Pad to image_size so .bss and the stacks are part of the loaded file.
size=$((16#$($NM "$OUT/shim.elf" | awk '$3=="_end"{print $1}')))
truncate -s "$size" "$OUT/Image"

gzip -9 -n -c "$OUT/Image" > "$OUT/Image.gz"
cat "$OUT/Image.gz" "$DTB" > "$OUT/Image.gz-dtb"

# Ramdisk: the XNU payload if given, else an empty newc cpio (ABL wants one).
if [ -n "${1:-}" ]; then
	cp "$1" "$OUT/ramdisk.bin"
else
	(cd "$OUT" && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 -n > ../ramdisk.bin)
fi

mkbootimg --header_version 0 --pagesize 4096 \
	--base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x01000000 --tags_offset 0x100 \
	--os_version 14.0.0 --os_patch_level 2026-09 \
	--kernel "$OUT/Image.gz-dtb" --ramdisk "$OUT/ramdisk.bin" \
	--cmdline "console=null" -o "$OUT/shim-boot.img"

ls -l "$OUT/Image" "$OUT/shim-boot.img"
sha256sum "$OUT/shim-boot.img"
