#!/bin/bash
# Build a whyred fastboot image that boots XNU.
#
#   whyred/mkboot.sh --ios KERNEL             iOS root on userdata, Synaptics HID, A509 opaque 2D
#   whyred/mkboot.sh --ios --run RUN_ID       same, downloading the matching CI kernel
#   whyred/mkboot.sh KERNEL [RAMDISK]          boot with the default boot-args below
#   whyred/mkboot.sh KERNEL none               no RAM disk (pass rd=emmcroot0 in CMDLINE)
#   CMDLINE="..." whyred/mkboot.sh KERNEL       override the boot-args
#   whyred/mkboot.sh --fetch RUN_ID             download the xnu-kernel artifact of a CI run
#
# RAMDISK defaults to whyred/out/sweet-init (tools/sweet-init.S): mockfs serves it as
# /sbin/launchd, so XNU boots to a PID 1 that prints a heartbeat. Output: whyred/out/xnu-boot.img
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/whyred/out
mkdir -p "$OUT"

REPO=${GH_REPO:-miku-whyred/whyred-full-hardware-extended-ram}

fetch_kernel() {
	local run=$1 dest=$2
	[[ $run =~ ^[0-9]+$ ]] || { echo "Expected a numeric GitHub Actions run ID" >&2; return 1; }
	gh run download "$run" -R "$REPO" -n xnu-kernel -D "$dest"
	(cd "$dest" && sha256sum --check --status SHA256SUMS && test -s kernel.development.sweet)
}

if [[ ${1:-} == --ios ]]; then
	shift
	work=$(mktemp -d "$OUT/.ios-build.XXXXXXXX")
	trap 'rm -rf -- "$work"' EXIT
	if [[ $# == 2 && $1 == --run ]]; then
		fetch_kernel "$2" "$work/kernel"
		kernel=$work/kernel/kernel.development.sweet
	elif [[ $# == 1 && -f $1 ]]; then
		kernel=$1
	else
		echo "Usage: whyred/mkboot.sh --ios KERNEL | --ios --run RUN_ID" >&2
		exit 2
	fi

	# Keep diagnostic shim modes and memory ranges from another build out of this profile.
	unset WHYRED_NODISP WHYRED_EXTRA_RAM WHYRED_EXTENTS EMMC OSM OSM_TARGET MSS GOLD_ROW CPRH_OL SCALE
	export WHYRED_NATIVE=1
	export WHYRED_GPU_FIRMWARE=${WHYRED_GPU_FIRMWARE:-"$ROOT/whyred/firmware/gpu"}
	python3 "$ROOT/whyred/tools/display_inputs.py" --gpu-dir "$WHYRED_GPU_FIRMWARE" \
		--tree "$ROOT/research/ipsw-x/d22ap.adt"

	args=(
		debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress
		rd=emmcroot0 emmcroot=userdata emmcrw=1 rootrw=1
		unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1
		sweetcpufreq=0 sweettherm=1 sweetbattery=2 panicreset=60 sweetusb=2
		sweetfb_native=1 sweetkeys=1 sweetsyna=2 sweetfb_noconsole=1 sweetfb_hz=30
		modem=1 wifi=1 wifi_smmu=2 adsp=1 'topaz_inject=/usr/lib/whyred_ui.dylib,*app,backboardd'
		whyred_gpu=1 whyred_gpu_power=1 whyred_gpu_cp=5 a509clk=1 a509fb=2
	)
	python3 "$ROOT/whyred/tools/mkadt_whyred.py" "$work/whyred.adt"
	python3 "$ROOT/tools/mkpayload.py" "$kernel" "$work/whyred.adt" "$work/payload.bin" --cmdline "${args[*]}"
	WHYRED_SHIM_OUT="$work/shim" "$ROOT/whyred/shim/build.sh" "$work/payload.bin"
	mv -f -- "$work/shim/shim-boot.img" "$OUT/whyred-ios16-a509.img"
	sha256sum "$OUT/whyred-ios16-a509.img"
	exit 0
fi

if [[ ${1:-} == --fetch ]]; then
	[[ $# == 2 && $2 =~ ^[0-9]+$ ]] || { echo "Usage: whyred/mkboot.sh --fetch RUN_ID" >&2; exit 2; }
	dir=$OUT/kernel-$2
	if [[ ! -s "$dir/kernel.development.sweet" ]] || ! (cd "$dir" && sha256sum --check --status SHA256SUMS); then
		work=$(mktemp -d "$OUT/.kernel-download.XXXXXXXX")
		trap 'rm -rf -- "$work"' EXIT
		fetch_kernel "$2" "$work"
		mkdir -p "$dir"
		cp -a "$work/." "$dir/"
	fi
	ls -l "$dir"
	exit 0
fi

KERNEL=${1:?usage: mkboot.sh KERNEL [RAMDISK]}
RAMDISK=${2:-$OUT/sweet-init}
# sweetcpufreq=0 sweetbattery=0: SweetBattery otherwise writes SM6225 clock and cpufreq registers.
CMDLINE=${CMDLINE:-debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress -enable_kprintf_spam rd=md0 sweetcpufreq=0 sweetbattery=0}

if [ ! -f "$RAMDISK" ] && [ "$RAMDISK" = "$OUT/sweet-init" ]; then
	clang -target arm64-apple-ios16.0 -c "$ROOT/tools/sweet-init.S" -o "$OUT/sweet-init.o"
	python3 "$ROOT/tools/mkinit.py" "$OUT/sweet-init.o" "$OUT/sweet-init"
fi

python3 "$ROOT/whyred/tools/mkadt_whyred.py" "$OUT/whyred.adt"
rdargs=()
[ "$RAMDISK" = none ] || rdargs=(--ramdisk "$RAMDISK")
python3 "$ROOT/tools/mkpayload.py" "$KERNEL" "$OUT/whyred.adt" "$OUT/payload.bin" \
	--cmdline "$CMDLINE" "${rdargs[@]}"
"$ROOT/whyred/shim/build.sh" "$OUT/payload.bin"
cp "$ROOT/whyred/shim/out/shim-boot.img" "$OUT/xnu-boot.img"
echo "boot-args: $CMDLINE"
echo "fastboot boot $OUT/xnu-boot.img"
