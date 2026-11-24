#!/usr/bin/env bash

set -euo pipefail

out=$1
lib=webp-sandbox/cbits/libwebp
release=libwebp-1.6.0-linux-x86-64
url=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/$release.tar.gz
images=https://raw.githubusercontent.com/simplex-chat/simplex-chat/8f5dfa3d4e305ec73d55c864c98f01f5db9967ba/tests/fixtures
tmp=$RUNNER_TEMP/fixtures

rm -rf "$out" "$tmp"
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

"$bin/cwebp" -quiet -q 75 "$tmp/test.jpg" -o "$out/photo-1280x720-lossy.webp"
"$bin/cwebp" -quiet -q 75 -resize 2560 1440 "$tmp/test.jpg" -o "$out/photo-2560x1440-lossy.webp"
"$bin/cwebp" -quiet -lossless "$tmp/test.jpg" -o "$out/photo-1280x720-lossless.webp"
"$bin/cwebp" -quiet -q 75 "$tmp/logo-large-rgba.png" -o "$out/logo-1630x466-lossy-alpha.webp"
"$bin/cwebp" -quiet -lossless "$tmp/logo-large-rgba.png" -o "$out/logo-1630x466-lossless.webp"

gcc -O2 -I "$lib" -I "$lib/src" "$lib"/src/*/*.c "$lib"/sharpyuv/*.c .github/scripts/webp-encode.c -lm -o "$tmp/webp-encode.exe"
mkdir -p "$tmp/tall"
"$tmp/webp-encode.exe" "$tmp/tall"
cp "$tmp/tall/tall-lossless.webp" "$tmp/tall/tall-lossy-alpha.webp" "$out/"

{
  echo "### WebP fixtures, cwebp $("$bin/cwebp" -version), and the tall images of webp-encode.c"
  echo '```'
  for file in "$out"/*.webp; do
    echo "$(sha256sum "$file" | cut -c1-16) $(wc -c < "$file") $(basename "$file") $("$bin/webpinfo" "$file" | grep -E 'Format|Width|Height|Alpha:' | tr -s ' ' | tr '\n' ' ')"
  done
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
