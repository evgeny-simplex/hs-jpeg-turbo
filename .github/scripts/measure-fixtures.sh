#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/measure/fixtures
release=libwebp-1.6.0-linux-x86-64
url=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/$release.tar.gz
images=https://raw.githubusercontent.com/simplex-chat/simplex-chat/8f5dfa3d4e305ec73d55c864c98f01f5db9967ba/tests/fixtures
tmp=$RUNNER_TEMP/fixtures

mkdir -p "$out" "$tmp"
curl -fsSL -o "$tmp/$release.tar.gz" "$url"
curl -fsSL -o "$tmp/$release.tar.gz.asc" "$url.asc"
curl -fsSL -o "$tmp/key.asc" "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x6B0E6B70976DE303EDF2F601F9C3D6BDB8232B5D"
gpg --import "$tmp/key.asc"
gpg --verify "$tmp/$release.tar.gz.asc" "$tmp/$release.tar.gz"
echo "1c5ffab71efecefa0e3c23516c3a3a1dccb45cc310ae1095c6f14ae268e38067  $tmp/$release.tar.gz" | sha256sum --check
tar -xzf "$tmp/$release.tar.gz" -C "$tmp"
bin=$tmp/$release/bin
curl -fsSL -o "$tmp/test.jpg" "$images/test.jpg"
curl -fsSL -o "$tmp/logo-large-rgba.png" "$images/logo-large-rgba.png"
sha256sum "$tmp/test.jpg" "$tmp/logo-large-rgba.png"
"$bin/cwebp" -version

"$bin/cwebp" -quiet -q 75 -crop 80 152 128 128 "$tmp/test.jpg" -o "$out/lossy.webp"
"$bin/cwebp" -quiet -lossless -exact -crop 315 80 1000 307 "$tmp/logo-large-rgba.png" -o "$out/lossless-alpha.webp"
"$bin/cwebp" -quiet -q 75 -crop 315 80 1000 307 "$tmp/logo-large-rgba.png" -o "$out/lossy-alpha.webp"
"$bin/dwebp" -quiet "$out/lossy.webp" -ppm -o "$tmp/lossy.webp.ppm"
"$bin/dwebp" -quiet "$out/lossless-alpha.webp" -pam -o "$tmp/lossless-alpha.webp.pam"
"$bin/dwebp" -quiet "$out/lossy-alpha.webp" -pam -o "$tmp/lossy-alpha.webp.pam"
python3 -I .github/scripts/measure-crop.py "$tmp/logo-large-rgba.png" 315 80 1000 307 "$tmp/lossless-alpha.webp.pam"
uniform() {
  python3 -I - "$@" <<'PY'
import sys
path, w, h, *px = sys.argv[1:]
w, h, px = int(w), int(h), bytes(map(int, px))
rgb = b"P6\n%d %d\n255\n" % (w, h)
rgba = b"P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" % (w, h)
open(path, "wb").write((rgb if len(px) == 3 else rgba) + px * (w * h))
PY
}
samples() {
  python3 -I - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
depth = 4 if data.startswith(b"P7") else 3
pixels = data[data.index(b"ENDHDR\n") + 7:] if depth == 4 else data.split(b"\n", 3)[3]
print(sys.argv[1].rsplit("/", 1)[-1], [(min(pixels[c::depth]), max(pixels[c::depth])) for c in range(depth)])
PY
}
uniform "$tmp/uniform-8641x16.ppm" 8641 16 200 100 50
uniform "$tmp/uniform-alpha-16384x16.pam" 16384 16 200 100 50 128
uniform "$tmp/uniform-alpha-4321x16.pam" 4321 16 200 100 50 128
"$bin/cwebp" -quiet -q 100 "$tmp/uniform-8641x16.ppm" -o "$out/lossy-8641x16.webp"
"$bin/cwebp" -quiet -lossless "$tmp/uniform-alpha-16384x16.pam" -o "$out/lossless-alpha-16384x16.webp"
"$bin/cwebp" -quiet -q 100 "$tmp/uniform-alpha-4321x16.pam" -o "$out/lossy-alpha-4321x16.webp"
"$bin/dwebp" -quiet "$out/lossy-8641x16.webp" -scale 4320 8 -ppm -o "$tmp/lossy-8641x16-scaled.ppm"
"$bin/dwebp" -quiet "$out/lossless-alpha-16384x16.webp" -scale 4096 4 -pam -o "$tmp/lossless-alpha-16384x16-scaled.pam"
"$bin/dwebp" -quiet "$out/lossy-alpha-4321x16.webp" -scale 2160 8 -pam -o "$tmp/lossy-alpha-4321x16-scaled.pam"
lib=JuicyPixels-libwebp/cbits/libwebp
gcc -O2 -I "$lib" -I "$lib/src" "$lib"/src/*/*.c "$lib"/sharpyuv/*.c .github/scripts/measure-craft.c -lm -o "$tmp/craft.exe"
"$tmp/craft.exe" "$out/lossless-16384x16384.webp" lossless 16384 16384 0 0
for file in lossy lossless-alpha lossy-alpha lossy-8641x16 lossless-alpha-16384x16 lossy-alpha-4321x16 lossless-16384x16384; do
  echo "== $file.webp"
  "$bin/webpinfo" "$out/$file.webp" | grep -E 'Chunk|Width|Height|Format|Alpha|Animation|ICCP'
done
ls -l "$out"
{
  echo "### WebP fixtures, cwebp $("$bin/cwebp" -version)"
  echo '```'
  sha256sum "$out"/*.webp
  md5sum "$tmp"/lossy.webp.ppm "$tmp"/lossless-alpha.webp.pam "$tmp"/lossy-alpha.webp.pam
  echo "minimum and maximum of each sample, dwebp scaled to the display size"
  for file in "$tmp"/*-scaled.p?m; do
    samples "$file"
  done
  echo '```'
} | tee -a "$GITHUB_STEP_SUMMARY"
cp "$tmp"/*.ppm "$tmp"/*.pam "$out"/
