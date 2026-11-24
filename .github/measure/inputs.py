import csv
import hashlib
import os
import struct
import sys
import time
import urllib.request
import zlib

USER_AGENT = "hs-jpeg-turbo-measure/1.0 (https://github.com/evgeny-simplex/hs-jpeg-turbo)"
ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(name, body):
    return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body))


def write_png(path, width, height, depth, color_type, interlace, filter_type):
    channels = {2: 3, 6: 4}[color_type]
    pixel_bytes = channels * depth // 8
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    compressor = zlib.compressobj(9)
    idat = []
    pending = bytearray()
    for x0, y0, dx, dy in passes:
        w = (width - x0 + dx - 1) // dx
        h = (height - y0 + dy - 1) // dy
        if w <= 0 or h <= 0:
            continue
        row = bytes([filter_type]) + bytes(w * pixel_bytes)
        for _ in range(h):
            pending += compressor.compress(row)
            while len(pending) >= 1 << 20:
                idat.append(bytes(pending[: 1 << 20]))
                del pending[: 1 << 20]
    pending += compressor.flush()
    idat.append(bytes(pending))
    header = struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, interlace)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header))
        for body in idat:
            f.write(chunk(b"IDAT", body))
        f.write(chunk(b"IEND", b""))
    return os.path.getsize(path)


def generate(directory):
    from PIL import Image

    os.makedirs(directory, exist_ok=True)
    pngs = [
        ("zero-rgba16-16384x16384.png", 16384, 16384, 16, 6, 0, 0),
        ("zero-rgba16-16384x16384-paeth.png", 16384, 16384, 16, 6, 0, 4),
        ("zero-rgba8-16384x16384-paeth.png", 16384, 16384, 8, 6, 0, 4),
        ("zero-rgba8-8192x8192-paeth.png", 8192, 8192, 8, 6, 0, 4),
        ("zero-rgba8-8192x8192-adam7-paeth.png", 8192, 8192, 8, 6, 1, 4),
        ("zero-rgba8-16384x16384-adam7-paeth.png", 16384, 16384, 8, 6, 1, 4),
    ]
    for name, *params in pngs:
        size = write_png(os.path.join(directory, name), *params)
        print(f"{name}: {size} bytes")
    path = os.path.join(directory, "grey-16384x16384.jpg")
    Image.new("RGB", (16384, 16384), (128, 128, 128)).save(path, quality=90)
    print(f"grey-16384x16384.jpg: {os.path.getsize(path)} bytes")
    limit = 2097152
    size = os.path.getsize(os.path.join(directory, "zero-rgba16-16384x16384.png"))
    if size > limit:
        sys.exit(f"zero-rgba16-16384x16384.png: {size} bytes, above {limit}")


def download(corpus, directory):
    with open(corpus) as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    for row in rows:
        target = os.path.join(directory, row["set"])
        os.makedirs(target, exist_ok=True)
        extension = os.path.splitext(row["url"])[1].lower().replace(".jpeg", ".jpg")
        path = os.path.join(target, row["name"] + extension)
        if not (os.path.exists(path) and sha1(path) == row["sha1"]):
            fetch(row["url"], path)
        digest = sha1(path)
        if digest != row["sha1"]:
            sys.exit(f"{row['name']}: sha1 {digest}, expected {row['sha1']}")
        print(f"{row['set']}/{row['name']}{extension}: {os.path.getsize(path)} bytes, sha1 verified")


def fetch(url, path):
    for attempt in range(6):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=300) as response, open(path, "wb") as f:
                while block := response.read(1 << 20):
                    f.write(block)
            return
        except OSError as e:
            print(f"{url}: {e}, attempt {attempt + 1}")
            time.sleep(10 * (attempt + 1))
    sys.exit(f"{url}: download failed")


def sha1(path):
    digest = hashlib.sha1()
    with open(path, "rb") as f:
        while block := f.read(1 << 20):
            digest.update(block)
    return digest.hexdigest()


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"generate": generate, "download": download}[command](*args)
