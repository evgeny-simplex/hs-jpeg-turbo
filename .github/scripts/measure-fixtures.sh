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
for file in lossy lossless-alpha lossy-alpha; do
  echo "== $file.webp"
  "$bin/webpinfo" "$out/$file.webp" | grep -E 'Chunk|Width|Height|Format|Alpha|Animation|ICCP'
done
ls -l "$out"
{
  echo "### WebP fixtures, cwebp $("$bin/cwebp" -version)"
  echo '```'
  sha256sum "$out"/*.webp
  md5sum "$tmp"/*.ppm "$tmp"/*.pam
  echo '```'
} | tee -a "$GITHUB_STEP_SUMMARY"
cp "$tmp"/*.ppm "$tmp"/*.pam "$out"/
