#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/png-check
package=JuicyPixels-spng
sources=$(sed -n '/^library$/,/^$/p' $package/$package.cabal | grep -oE 'cbits/[^ ]+\.c' | sed "s|^|$package/|")
options=$(sed -n '/^library$/,/^$/s/^  cc-options: //p' $package/$package.cabal)
flags="-O2 $options -I $package/cbits -I $package/cbits/libspng/spng -I $package/cbits/miniz"
suite=$package/cbits/libspng/tests/images
sides="16384 4320 16 5"

rm -rf "$out"
mkdir -p "$out/generated"
arm-linux-gnueabihf-gcc -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard -static $flags $sources .github/scripts/png.c -lm -o "$out/armv7.exe"
gcc $flags $sources .github/scripts/png.c -lm -o "$out/aarch64.exe"
clang-18 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined $flags $sources .github/scripts/png.c -lm -o "$out/sanitized.exe"
file "$out/armv7.exe" "$out/aarch64.exe"
"$out/aarch64.exe" encode "$out/generated"
inputs="$suite/*.png $out/generated/*.png"

for build in armv7 aarch64 sanitized; do
  for side in $sides; do
    mkdir -p "$out/$build-$side"
    "$out/$build.exe" check "$out/$build-$side" $side $inputs
  done
done
pairs=0
for side in $sides; do
  diff -r "$out/armv7-$side" "$out/aarch64-$side"
  diff -r "$out/aarch64-$side" "$out/sanitized-$side"
  for interlaced in "$out/aarch64-$side"/*i[0-9]*.png.* "$out/aarch64-$side"/noise-rgba-adam7.png.*; do
    name=$(basename "$interlaced")
    progressive=$(echo "$name" | sed -E 's/^(bas|s[0-9][0-9])i/\1n/; s/-adam7//')
    if [ "$progressive" != "$name" ] && [ -f "$out/aarch64-$side/$progressive" ]; then
      cmp "$interlaced" "$out/aarch64-$side/$progressive"
      pairs=$((pairs + 1))
    fi
  done
done
echo "$(ls "$out/aarch64-16384" | wc -l) decodes of $(ls $inputs | wc -l) PNGs, at sides of at most $sides, identical on armv7, aarch64 and with sanitizers"
echo "$pairs decodes of interlaced PNGs identical to the decodes of the same images without interlacing"

"$out/sanitized.exe" fuzz 16 $inputs
echo "$(ls $inputs | wc -l) PNGs truncated at 64 lengths and with 64 changed bytes each, decoded at sides of at most 16 with sanitizers"
