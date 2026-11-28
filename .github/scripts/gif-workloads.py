import os
import random
import struct
import sys

out = sys.argv[1]
rng = random.Random(20261128)


def lzw(indices, min_size, clear_every=0):
    clear, end = 1 << min_size, (1 << min_size) + 1
    data, value, count = bytearray(), 0, 0
    table, next_code, size = {}, end + 1, min_size + 1

    def write(code):
        nonlocal value, count
        value |= code << count
        count += size
        while count >= 8:
            data.append(value & 0xFF)
            value >>= 8
            count -= 8

    write(clear)
    prefix, codes = None, 0
    for index in indices:
        if prefix is None:
            prefix = index
            continue
        code = table.get(prefix << 8 | index)
        if code is not None:
            prefix = code
            continue
        write(prefix)
        codes += 1
        if next_code < 4096:
            table[prefix << 8 | index] = next_code
            next_code += 1
            if next_code == (1 << size) + 1 and size < 12:
                size += 1
        if next_code == 4096 or (clear_every and codes % clear_every == 0):
            write(clear)
            table, next_code, size = {}, end + 1, min_size + 1
        prefix = index
    write(prefix)
    write(end)
    if count:
        data.append(value & 0xFF)
    return bytes([min_size]) + b"".join(bytes([len(data[i : i + 255])]) + data[i : i + 255] for i in range(0, len(data), 255)) + b"\x00"


def interlaced(pixels, width, height):
    rows = [pixels[y * width : (y + 1) * width] for y in range(height)]
    return b"".join(rows[y] for start, step in [(0, 8), (4, 8), (2, 4), (1, 2)] for y in range(start, height, step))


def write_gif(name, width, height, frames, colors=256):
    bits = (colors - 1).bit_length()
    palette = bytes((i * 37 + c * 91) & 0xFF for i in range(1 << bits) for c in range(3))
    with open(os.path.join(out, name), "wb") as f:
        f.write(b"GIF89a" + struct.pack("<HHBBB", width, height, 0x80 | 0x70 | (bits - 1), 0, 0) + palette)
        f.write(b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00")
        for x, y, w, h, pixels, transparent, disposal, interlace, clear_every in frames:
            flags = disposal << 2 | (transparent is not None)
            f.write(b"\x21\xf9\x04" + struct.pack("<BHB", flags, 4, transparent or 0) + b"\x00")
            f.write(b"\x2c" + struct.pack("<HHHHB", x, y, w, h, 0x40 if interlace else 0))
            f.write(lzw(interlaced(pixels, w, h) if interlace else pixels, max(bits, 2), clear_every))
        f.write(b"\x3b")


def noise(width, height, colors=256):
    return bytes(b % colors for b in rng.randbytes(width * height)) if colors < 256 else rng.randbytes(width * height)


def full(width, height, pixels, disposal=1, interlace=False, clear_every=0, transparent=None):
    return (0, 0, width, height, pixels, transparent, disposal, interlace, clear_every)


os.makedirs(out, exist_ok=True)
write_gif("noise-1920x1080.gif", 1920, 1080, [full(1920, 1080, noise(1920, 1080)) for _ in range(10)])
write_gif("noise-1920x1920.gif", 1920, 1920, [full(1920, 1920, noise(1920, 1920)) for _ in range(4)])
write_gif("still-4320x4320.gif", 4320, 4320, [full(4320, 4320, noise(4320, 4320))])
write_gif("interlaced-1920x1080.gif", 1920, 1080, [full(1920, 1080, noise(1920, 1080), interlace=True) for _ in range(4)])
write_gif("two-colors-1920x1080.gif", 1920, 1080, [full(1920, 1080, noise(1920, 1080, 2)) for _ in range(4)], colors=2)
write_gif("clears-1024x1024.gif", 1024, 1024, [full(1024, 1024, noise(1024, 1024), clear_every=1)])
write_gif("previous-1920x1920.gif", 1920, 1920, [full(1920, 1920, noise(1920, 1920), disposal=3) for _ in range(8)])
write_gif(
    "partial-480x270.gif",
    480,
    270,
    [(k * 6 % 360, k * 3 % 202, 120, 68, bytes((x + y + k) % 256 if (x * y + k) % 4 else 255 for y in range(68) for x in range(120)), 255, k % 4, False, 0) for k in range(60)],
)
write_gif("dots-1024x1024.gif", 1024, 1024, [(k % 1024, k // 1024, 1, 1, bytes([k % 256]), None, 1, False, 0) for k in range(1000)])
write_gif("flat-4320x4320.gif", 4320, 4320, [full(4320, 4320, bytes(4320 * 4320))])
write_gif("flat-1920x1920.gif", 1920, 1920, [full(1920, 1920, bytes([k]) * (1920 * 1920), disposal=k % 4) for k in range(10)])
write_gif("flat-interlaced-1920x1920.gif", 1920, 1920, [full(1920, 1920, bytes([k]) * (1920 * 1920), interlace=True, transparent=k) for k in range(10)])
