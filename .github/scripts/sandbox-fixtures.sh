#!/usr/bin/env bash

set -euo pipefail

out=$1
webp=JuicyPixels-libwebp/cbits/libwebp
release=libwebp-1.6.0-linux-x86-64
url=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/$release.tar.gz
images=https://raw.githubusercontent.com/simplex-chat/simplex-chat/8f5dfa3d4e305ec73d55c864c98f01f5db9967ba/tests/fixtures
tmp=$RUNNER_TEMP/fixtures

rm -rf "$out" "$tmp"
mkdir -p "$out/workloads" "$out/largest" "$tmp"
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

{
  echo "### Sandbox workloads and the largest picked images"
  echo '```'
  for file in "$out"/workloads/* "$out"/largest/*; do
    echo "$(sha256sum "$file" | cut -c1-16) $(wc -c < "$file") $(basename "$file")"
  done
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
