import struct
import sys

path, size = sys.argv[1], int(sys.argv[2])
vp8x = b"VP8X" + struct.pack("<I", 10) + bytes(10)
count = (size - 12 - len(vp8x)) // 8
block = b"ABCD" + bytes(4)
with open(path, "wb") as out:
    out.write(b"RIFF" + struct.pack("<I", 4 + len(vp8x) + 8 * count) + b"WEBP" + vp8x)
    while count > 0:
        n = min(count, 1 << 16)
        out.write(block * n)
        count -= n
