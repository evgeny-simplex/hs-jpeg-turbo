#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/webp-check
package=JuicyPixels-libwebp
sources=$(sed -n '/^library$/,/^$/p' $package/$package.cabal | grep -oE 'cbits/[^ ]+\.c' | sed "s|^|$package/|")
options=$(sed -n '/^library$/,/^$/s/^  cc-options: //p' $package/$package.cabal)
flags="-O2 $options -I $package/cbits/libwebp"
armv7="-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard"
md5s="$WEBP_TEST_DATA/libwebp_tests.md5"
files=$(sed -n 's|^[0-9a-f]*  \(.*\.webp\)\.pam$|'"$WEBP_TEST_DATA"'/\1|p' "$md5s")
tall="$WEBP_TEST_DATA/tall-lossless.webp $WEBP_TEST_DATA/tall-lossy-alpha.webp"

objects() {
  mkdir -p "$out/$1"
  for source in $sources; do
    $2 $flags $3 -c "$source" -o "$out/$1/$(basename "$source" .c).o"
  done
}

rm -rf "$out"
mkdir -p "$out/armv7" "$out/aarch64"
arm-linux-gnueabihf-gcc $armv7 -static $flags $sources .github/scripts/webp.c -lpthread -lm -o "$out/armv7.exe"
gcc $flags $sources .github/scripts/webp.c -lpthread -lm -o "$out/aarch64.exe"
clang-18 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined $flags $sources .github/scripts/webp.c -lpthread -lm -o "$out/sanitized.exe"
file "$out/armv7.exe" "$out/aarch64.exe"

"$out/armv7.exe" check "$out/armv7" 16384 $files
"$out/aarch64.exe" check "$out/aarch64" 16384 $files
diff -r "$out/armv7" "$out/aarch64"
ls "$out/aarch64" > "$out/outputs.txt"
awk 'NR == FNR {outputs[$1]; next} $2 in outputs' "$out/outputs.txt" "$md5s" > "$out/expected.md5"
[ "$(wc -l < "$out/outputs.txt")" -eq 96 ]
[ "$(wc -l < "$out/expected.md5")" -eq 96 ]
(cd "$out/aarch64" && md5sum --check --quiet ../expected.md5)
echo "$(wc -l < "$out/outputs.txt") WebP files decoded identically on armv7 and aarch64, equal to libwebp_tests.md5"

for side in 16384 64; do
  for build in armv7 aarch64 sanitized; do
    mkdir -p "$out/$side-$build"
    "$out/$build.exe" check "$out/$side-$build" $side $tall
  done
  diff -r "$out/$side-armv7" "$out/$side-aarch64"
  diff -r "$out/$side-aarch64" "$out/$side-sanitized"
done
cmp "$out/16384-aarch64/tall-lossless.webp.pam" "$WEBP_TEST_DATA/tall-lossless.pam"
echo "$(ls "$out/16384-aarch64" | wc -l) tall WebP files decoded identically on armv7, aarch64 and with sanitizers, at full size and with sides of at most 64, the lossless one at full size equal to its source pixels"

for build in armv7 aarch64 sanitized; do
  mkdir -p "$out/64-$build-conformance"
  "$out/$build.exe" check "$out/64-$build-conformance" 64 $files
done
diff -r "$out/64-armv7-conformance" "$out/64-aarch64-conformance"
diff -r "$out/64-aarch64-conformance" "$out/64-sanitized-conformance"
echo "$(ls "$out/64-aarch64-conformance" | wc -l) WebP files decoded with sides of at most 64 identically on armv7, aarch64 and with sanitizers"

for side in 16384 64; do
  "$out/sanitized.exe" fuzz $side $files $tall
done

objects armv7-objects arm-linux-gnueabihf-gcc "$armv7"
objects aarch64-objects gcc ""
{
  echo "### WebP decoder objects, $(echo "$sources" | wc -w) files"
  echo '```'
  echo armv7
  arm-linux-gnueabihf-size -t "$out/armv7-objects"/*.o | sed -n '1p;$p'
  echo aarch64
  size -t "$out/aarch64-objects"/*.o | sed -n '1p;$p'
  echo '```'
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
