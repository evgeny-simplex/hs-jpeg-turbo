import os
import random
import struct
import sys
import zlib

from PIL import Image

work, calibration = sys.argv[1:]
rng = random.Random(20261127)
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def paeth_rows(width, height, pixel_bits):
    return [bytes([4]) + rng.randbytes((width * pixel_bits + 7) // 8) for _ in range(height)]


def write_png(name, width, height, depth, color_type, pixel_bits, interlaced=False, extra=(), idat_bytes=None):
    if interlaced:
        rows = []
        for x0, y0, dx, dy in ADAM7:
            w, h = (width - x0 + dx - 1) // dx, (height - y0 + dy - 1) // dy
            if w > 0 and h > 0:
                rows += paeth_rows(w, h, pixel_bits)
    else:
        rows = paeth_rows(width, height, pixel_bits)
    data = zlib.compress(b"".join(rows), 6)
    step = idat_bytes or len(data)
    with open(os.path.join(calibration, name), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 1 if interlaced else 0)))
        for kind, body in extra:
            f.write(chunk(kind, body))
        for i in range(0, len(data), step):
            f.write(chunk(b"IDAT", data[i : i + step]))
        f.write(chunk(b"IEND", b""))


def write_netpbm(name, width, height, channels):
    with open(os.path.join(work, name), "wb") as f:
        f.write(b"P6" if channels == 3 else b"P5")
        f.write(f"\n{width} {height}\n255\n".encode())
        f.write(rng.randbytes(width * height * channels))


def write_scans(name, components):
    lines = [" ".join(map(str, range(components))) + ": 0 0 0 10;"]
    lines += [" ".join(map(str, range(components))) + f": 0 0 {a} {a - 1};" for a in range(10, 0, -1)]
    for c in range(components):
        lines.append(f"{c}: 1 63 0 10;")
        lines += [f"{c}: 1 63 {a} {a - 1};" for a in range(10, 0, -1)]
    with open(os.path.join(work, name), "w") as f:
        f.write("\n".join(lines) + "\n")


write_png("worst-png-rgba16-paeth-1024x1024.png", 1024, 1024, 16, 6, 64)
write_png("worst-png-rgba16-adam7-1024x1024.png", 1024, 1024, 16, 6, 64, interlaced=True)
write_png("worst-png-rgba16-paeth-1x16384.png", 1, 16384, 16, 6, 64)
write_png("worst-png-rgba16-paeth-16384x1.png", 16384, 1, 16, 6, 64)
write_png("worst-png-rgba8-idat1-256x256.png", 256, 256, 8, 6, 32, idat_bytes=1)
write_png("worst-png-palette-trns-1024x1024.png", 1024, 1024, 8, 3, 8, extra=[(b"PLTE", rng.randbytes(768)), (b"tRNS", rng.randbytes(256))])
write_png("worst-png-grey1-adam7-4096x4096.png", 4096, 4096, 1, 0, 1, interlaced=True)

write_netpbm("noise-1024x1024.ppm", 1024, 1024, 3)
write_netpbm("noise-8x16384.ppm", 8, 16384, 3)
write_netpbm("noise-16384x8.ppm", 16384, 8, 3)
write_netpbm("noise-1024x1024.pgm", 1024, 1024, 1)
Image.frombytes("CMYK", (1024, 1024), rng.randbytes(1024 * 1024 * 4)).save(os.path.join(work, "noise-cmyk-1024x1024.jpg"), quality=100, subsampling=0)
write_scans("refine-3.txt", 3)
write_scans("refine-4.txt", 4)
with open(os.path.join(work, "scans-64-grey.txt"), "w") as f:
    f.write("0: 0 0 0 0;\n" + "".join(f"0: {k} {k} 0 0;\n" for k in range(1, 64)))

for width, height, name in [(1024, 1024, "1024x1024"), (1, 16383, "1x16383"), (16383, 1, "16383x1")]:
    Image.frombytes("RGBA", (width, height), rng.randbytes(width * height * 4)).save(os.path.join(work, f"noise-rgba-{name}.png"))
