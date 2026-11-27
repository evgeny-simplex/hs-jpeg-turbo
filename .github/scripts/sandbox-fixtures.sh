#!/usr/bin/env bash

set -euo pipefail

out=$1
webp=JuicyPixels-libwebp/cbits/libwebp
release=libwebp-1.6.0-linux-x86-64
url=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/$release.tar.gz
images=https://raw.githubusercontent.com/simplex-chat/simplex-chat/8f5dfa3d4e305ec73d55c864c98f01f5db9967ba/tests/fixtures
tmp=$RUNNER_TEMP/fixtures

rm -rf "$out" "$tmp"
mkdir -p "$out/workloads" "$out/largest" "$out/calibration" "$tmp/calibration"
curl -fsSL -o "$tmp/$release.tar.gz" "$url"
echo "1c5ffab71efecefa0e3c23516c3a3a1dccb45cc310ae1095c6f14ae268e38067  $tmp/$release.tar.gz" | sha256sum --check
tar -xzf "$tmp/$release.tar.gz" -C "$tmp"
bin=$tmp/$release/bin
curl -fsSL -o "$tmp/test.jpg" "$images/test.jpg"
curl -fsSL -o "$tmp/logo-large-rgba.png" "$images/logo-large-rgba.png"
sha256sum "$tmp/test.jpg" "$tmp/logo-large-rgba.png"

"$bin/cwebp" -quiet -q 75 "$tmp/test.jpg" -o "$out/workloads/photo-1280x720-lossy.webp"
"$bin/cwebp" -quiet -q 75 -resize 2560 1440 "$tmp/test.jpg" -o "$out/workloads/photo-2560x1440-lossy.webp"
"$bin/cwebp" -quiet -lossless "$tmp/test.jpg" -o "$out/workloads/photo-1280x720-lossless.webp"
"$bin/cwebp" -quiet -q 75 "$tmp/logo-large-rgba.png" -o "$out/workloads/logo-1630x466-lossy-alpha.webp"
"$bin/cwebp" -quiet -lossless "$tmp/logo-large-rgba.png" -o "$out/workloads/logo-1630x466-lossless.webp"
gcc -O2 -I "$webp" -I "$webp/src" "$webp"/src/*/*.c "$webp"/sharpyuv/*.c .github/scripts/webp-encode.c -lm -o "$tmp/webp-encode.exe"
mkdir -p "$tmp/tall"
"$tmp/webp-encode.exe" "$tmp/tall"
cp "$tmp/tall/tall-lossless.webp" "$tmp/tall/tall-lossy-alpha.webp" "$out/workloads/"

python3 -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install --quiet pillow==11.3.0
"$tmp/venv/bin/python" -I .github/scripts/sandbox-fixtures.py "$tmp/test.jpg" "$tmp/logo-large-rgba.png" "$out"

work=$tmp/calibration
calibration=$out/calibration
"$tmp/venv/bin/python" -I .github/scripts/sandbox-calibration.py "$work" "$calibration"
cmake -S jpeg-turbo/cbits/mozjpeg -B "$tmp/mozjpeg" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DPNG_SUPPORTED=OFF -DWITH_SIMD=0 \
  -DWITH_ARITH_ENC=1 -DWITH_ARITH_DEC=1 -DWITH_TURBOJPEG=0 > /dev/null
cmake --build "$tmp/mozjpeg" --target cjpeg-static jpegtran-static --parallel > /dev/null
cjpeg=$tmp/mozjpeg/cjpeg-static
jpegtran=$tmp/mozjpeg/jpegtran-static
for coding in huffman arithmetic; do
  flag=
  if [ $coding = arithmetic ]; then
    flag=-arithmetic
  fi
  for size in 1024x1024 8x16384 16384x8; do
    "$cjpeg" -revert -quality 100 -sample 1x1 $flag -scans "$work/refine-3.txt" -outfile "$calibration/worst-jpeg-refine-444-$coding-$size.jpg" "$work/noise-$size.ppm"
  done
  "$jpegtran" -revert $flag -scans "$work/refine-4.txt" -outfile "$calibration/worst-jpeg-refine-cmyk-$coding-1024x1024.jpg" "$work/noise-cmyk-1024x1024.jpg"
  "$cjpeg" -revert -quality 100 -sample 1x1 $flag -scans "$work/refine-3.txt" -outfile "$calibration/worst-jpeg-refine-444-flat-$coding-1024x1024.jpg" "$work/flat-1024x1024.ppm"
  "$jpegtran" -revert $flag -scans "$work/refine-4.txt" -outfile "$calibration/worst-jpeg-refine-cmyk-flat-$coding-1024x1024.jpg" "$work/flat-cmyk-1024x1024.jpg"
  "$cjpeg" -revert -quality 100 $flag -scans "$work/scans-64-grey.txt" -outfile "$calibration/worst-jpeg-scans64-grey-$coding-1024x1024.jpg" "$work/noise-1024x1024.pgm"
done
"$cjpeg" -revert -quality 100 -restart 1B -outfile "$calibration/worst-jpeg-restart1-420-1024x1024.jpg" "$work/noise-1024x1024.ppm"
"$bin/cwebp" -quiet -lossless -z 9 "$work/noise-rgba-1024x1024.png" -o "$calibration/worst-webp-lossless-1024x1024.webp"
"$bin/cwebp" -quiet -q 100 -alpha_q 100 -exact "$work/noise-rgba-1024x1024.png" -o "$calibration/worst-webp-lossy-alpha-1024x1024.webp"
"$bin/cwebp" -quiet -lossless -z 9 "$work/flat-rgba-1024x1024.png" -o "$calibration/worst-webp-lossless-flat-1024x1024.webp"
"$bin/cwebp" -quiet -q 100 -alpha_q 100 -exact "$work/flat-rgba-1024x1024.png" -o "$calibration/worst-webp-lossy-alpha-flat-1024x1024.webp"
for size in 1x16383 16383x1; do
  "$bin/cwebp" -quiet -lossless -z 9 "$work/noise-rgba-$size.png" -o "$calibration/worst-webp-lossless-$size.webp"
  "$bin/cwebp" -quiet -q 100 -alpha_q 100 -exact "$work/noise-rgba-$size.png" -o "$calibration/worst-webp-lossy-alpha-$size.webp"
done
gcc -O2 -I "$webp" -I "$webp/src" "$webp"/src/*/*.c "$webp"/sharpyuv/*.c .github/scripts/webp-craft.c -lm -o "$tmp/webp-craft.exe"
"$tmp/webp-craft.exe" "$calibration/crafted-webp-huffman-2600-lossless-1024x1024.webp" lossless 1024 1024 2600 0
"$tmp/webp-craft.exe" "$calibration/crafted-webp-huffman-5679-lossless-1024x1024.webp" lossless 1024 1024 5679 0
"$tmp/webp-craft.exe" "$calibration/crafted-webp-huffman-5679-alpha-1024x1024.webp" alpha 1024 1024 5679 0
"$tmp/webp-craft.exe" "$calibration/crafted-webp-huffman-65536-lossless-1024x1024.webp" lossless 1024 1024 65536 0
"$tmp/webp-craft.exe" "$calibration/crafted-webp-chunks-1MiB-16x16.webp" lossless 16 16 0 1048576

{
  echo "### Sandbox workloads, the largest picked images and the budget calibration"
  echo '```'
  for file in "$out"/workloads/* "$out"/largest/* "$out"/calibration/*; do
    echo "$(sha256sum "$file" | cut -c1-16) $(wc -c < "$file") $(basename "$file")"
  done
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
