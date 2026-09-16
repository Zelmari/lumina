#!/usr/bin/env python3
"""Write a simple gold-on-navy AppIcon.icns for Lumina Agent."""
import os
import struct
import subprocess
import sys
import tempfile
import zlib


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def png_rgba(width: int) -> bytes:
    gold = (242, 201, 76, 255)
    navy = (22, 28, 40, 255)
    cx = cy = width / 2
    radius = width * 0.33
    rows = []
    for y in range(width):
        row = bytearray()
        for x in range(width):
            dx = x - cx
            dy = y - cy
            row += bytes(gold if dx * dx + dy * dy <= radius * radius else navy)
        rows.append(b"\x00" + bytes(row))
    raw = b"".join(rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, width, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main() -> None:
    out = sys.argv[1]
    names = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        cache: dict[int, bytes] = {}
        for name, size in names.items():
            if size not in cache:
                cache[size] = png_rgba(size)
            with open(os.path.join(iconset, name), "wb") as fh:
                fh.write(cache[size])
        subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", out])


if __name__ == "__main__":
    main()
