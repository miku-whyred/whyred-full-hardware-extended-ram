#!/usr/bin/env python3
"""Acquire the pinned D22AP tree and public whyred GPU firmware for the iOS profile."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen
import zlib

GPU_FIRMWARE_SHA256 = {
    "a512_zap.b00": "5302ecf8978c825bdc9d8455a828a4ac1e1d762cf09ff821f9f506fb89a549e5",
    "a512_zap.b01": "d96c83059cccd4220cee069ac58d5883f7fda667c879f01c69b1c0343e4f8525",
    "a512_zap.b02": "668cbf86efe383d86ab7821ae4c5cbe4d1bcd145df454a31d3a68dbfc7ae49a4",
    "a512_zap.mdt": "3ee9e6ec51b205894340a41fa4d335794c256952f3bf028e82a76d6f8efc7fe7",
    "a530_pfp.fw": "2a51c25b1f7299cb84c3685d3d1fb88bf0504494456345b2dfde32816e13bc8e",
    "a530_pm4.fw": "a02c9be11787472d4ab0173ed8552afbde1f31b1e81bcd87adf1fcea97b6115f",
}

VENDOR = (
    "https://raw.githubusercontent.com/TheMuppets/proprietary_vendor_xiaomi_whyred/"
    "59e6cff428b177a448dc5952089a9aad0c362295/proprietary/vendor/firmware/"
)
IPSW = (
    "https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/"
    "1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw"
)
# Deflated Firmware/all_flash/DeviceTree.d22ap.im4p in this exact ZIP64 archive.
DT_OFFSET, DT_LENGTH, IPSW_LENGTH = 6138468867, 33720, 6171035648
DT_COMPRESSED_SHA = "ba6959dae8d735a02ea65ad0da4d438acb43a606f7a9890bd6cab9a0a445eaec"
DT_SHA = "9e670987c80493bd69aba7be62e3179c04663324d9249b0973675baac175dbf1"


def verify(data, expected, name):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"SHA-256 mismatch for {name}")


def get_firmware(name):
    with urlopen(VENDOR + name, timeout=30) as response:
        return response.read(256 * 1024 + 1)


def get_tree():
    last = DT_OFFSET + DT_LENGTH - 1
    request = Request(IPSW, headers={"Range": f"bytes={DT_OFFSET}-{last}"})
    with urlopen(request, timeout=30) as response:
        if response.status != 206 or response.headers.get("Content-Range") != f"bytes {DT_OFFSET}-{last}/{IPSW_LENGTH}":
            raise ValueError("Apple CDN did not return the requested device-tree byte range")
        compressed = response.read(DT_LENGTH + 1)
    verify(compressed, DT_COMPRESSED_SHA, "compressed D22AP IM4P")
    im4p = zlib.decompress(compressed, -15)
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
    import adt
    _, pos, end = adt.der(im4p, 0)
    fields = []
    while pos < end:
        tag, start, pos = adt.der(im4p, pos)
        fields.append((tag, im4p[start:pos]))
    if fields[0][1] != b"IM4P" or fields[1][1] != b"dtre" or fields[3][0] != 4:
        raise ValueError("Unexpected device-tree container")
    try:
        import lzfse
    except ImportError:
        if not shutil.which("lzfse"):
            raise ValueError("Install lzfse (CLI or Python module), or supply the unpacked D22AP tree")
        return subprocess.run(["lzfse", "-decode"], input=fields[3][1],
                              stdout=subprocess.PIPE, check=True).stdout
    return lzfse.decompress(fields[3][1])


def ensure_file(path, checksum, download):
    if path.exists():
        verify(path.read_bytes(), checksum, path)
        return
    data = download()
    verify(data, checksum, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        try:
            tmp.write(data)
            tmp.close()
            os.replace(tmp.name, path)
        finally:
            Path(tmp.name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpu-dir", type=Path, required=True)
    parser.add_argument("--tree", type=Path, required=True)
    args = parser.parse_args()
    ensure_file(args.tree, DT_SHA, get_tree)
    for name, checksum in GPU_FIRMWARE_SHA256.items():
        ensure_file(args.gpu_dir / name, checksum, lambda: get_firmware(name))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
