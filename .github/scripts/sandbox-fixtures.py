import os
import shutil
import struct
import sys
import zlib

from PIL import Image

photo, logo, out, work = sys.argv[1:]
workloads = os.path.join(out, "workloads")
largest = os.path.join(out, "largest")


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def write_png(path, side, row_filter):
    compressor = zlib.compressobj(9)
    row = bytes([row_filter]) + bytes(side * 8)
    parts = [compressor.compress(row) for _ in range(side)]
    parts.append(compressor.flush())
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 16, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", b"".join(parts)))
        f.write(chunk(b"IEND", b""))


source = Image.open(photo).convert("RGB")
shutil.copy(photo, os.path.join(workloads, "photo-1280x720.jpg"))
source.resize((2560, 1440), Image.LANCZOS).save(os.path.join(workloads, "photo-2560x1440.jpg"), quality=90)
source.resize((2560, 1440), Image.LANCZOS).save(os.path.join(workloads, "photo-2560x1440-progressive.jpg"), quality=90, progressive=True)
source.resize((1024, 4096), Image.LANCZOS).save(os.path.join(workloads, "tall-1024x4096.jpg"), quality=90)
source.save(os.path.join(workloads, "photo-1280x720.png"))
source.resize((2560, 1440), Image.LANCZOS).save(os.path.join(workloads, "photo-2560x1440.png"))
shutil.copy(logo, os.path.join(workloads, "logo-1630x466.png"))
Image.open(logo).convert("RGBA").resize((1024, 4096), Image.LANCZOS).save(os.path.join(workloads, "tall-1024x4096-rgba.png"))

big = source.resize((16384, 16384), Image.BICUBIC)
big.save(os.path.join(largest, "largest-16384x16384.jpg"), quality=90)
big.save(os.path.join(largest, "largest-16384x16384-progressive.jpg"), quality=90, progressive=True)
source.resize((16383, 16383), Image.BICUBIC).save(os.path.join(work, "largest-16383x16383.ppm"))
write_png(os.path.join(largest, "largest-16384x16384-rgba16-paeth.png"), 16384, 4)
write_png(os.path.join(largest, "largest-16384x16384-rgba16.png"), 16384, 0)
write_png(os.path.join(largest, "paeth-8192x8192-rgba16.png"), 8192, 4)
write_png(os.path.join(largest, "paeth-4096x4096-rgba16.png"), 4096, 4)
