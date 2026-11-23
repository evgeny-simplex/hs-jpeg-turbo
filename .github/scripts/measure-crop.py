import struct
import sys
import zlib

png, x0, y0, w, h, pam = sys.argv[1], *map(int, sys.argv[2:6]), sys.argv[6]
data = open(png, "rb").read()
pos, idat = 8, b""
while pos < len(data):
    size, kind = struct.unpack(">I4s", data[pos:pos + 8])
    body = data[pos + 8:pos + 8 + size]
    if kind == b"IHDR":
        width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        assert (depth, colour, interlace) == (8, 6, 0), (depth, colour, interlace)
    if kind == b"IDAT":
        idat += body
    pos += 12 + size
raw = zlib.decompress(idat)
stride = width * 4
rows, prev = [], bytearray(stride)
for y in range(height):
    line = raw[y * (stride + 1):(y + 1) * (stride + 1)]
    kind, cur = line[0], bytearray(line[1:])
    for i in range(stride):
        a = cur[i - 4] if i >= 4 else 0
        b = prev[i]
        c = prev[i - 4] if i >= 4 else 0
        if kind == 1:
            cur[i] = (cur[i] + a) & 255
        elif kind == 2:
            cur[i] = (cur[i] + b) & 255
        elif kind == 3:
            cur[i] = (cur[i] + (a + b) // 2) & 255
        elif kind == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            cur[i] = (cur[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(bytes(cur))
    prev = cur
crop = b"".join(row[x0 * 4:(x0 + w) * 4] for row in rows[y0:y0 + h])
decoded = open(pam, "rb").read()
header = b"P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" % (w, h)
assert decoded == header + crop, "the lossless fixture differs from the crop of its source image"
print("%s equals the %dx%d crop at (%d, %d) of %s" % (pam, w, h, x0, y0, png))
