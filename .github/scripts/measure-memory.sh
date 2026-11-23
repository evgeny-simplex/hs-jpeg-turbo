#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/measure
package=JuicyPixels-webp
sources=$(sed -n '/^library$/,/^$/p' $package/$package.cabal | grep -oE 'cbits/libwebp/[^ ]+\.c' | sed 's|^cbits/libwebp/||')
options=$(sed -n '/^library$/,/^$/s/^  cc-options: //p' $package/$package.cabal)
main=$package/cbits/libwebp
old=$RUNNER_TEMP/libwebp-1.6.0
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

build() {
  gcc -O2 $options $3 -I "$2" $(for source in $sources; do echo "$2/$source"; done) .github/scripts/webp.c -lpthread -lm -o "$out/$1.exe"
}

measure() {
  rm -rf "$out/decoded"
  mkdir -p "$out/decoded"
  /usr/bin/time -f %M -o "$out/rss.txt" "$out/$1.exe" check "$out/decoded" "$2" 2> "$out/heap.txt"
  result=$(ls "$out/decoded")
  heap=$(sed -n 's/^high-water mark: //p' "$out/heap.txt")
  echo "${heap:--} $(cat "$out/rss.txt") ${result##*.}"
}

rm -rf "$out/images" "$out/decoded"
mkdir -p "$out/images"
git clone --quiet --depth 1 --branch v1.6.0 https://github.com/webmproject/libwebp "$old"
echo "v1.6.0 at $(git -C "$old" rev-parse HEAD), main at $(git -C "$main" rev-parse HEAD)"
echo "$(echo "$sources" | wc -w) C files, cc-options: $options"
build heap-v1.6.0 "$old" -DPRINT_MEM_INFO
build heap-f054d0c3 "$main" -DPRINT_MEM_INFO
build rss-v1.6.0 "$old" ""
build rss-f054d0c3 "$main" ""
gcc -O2 -I "$main" "$main"/src/*/*.c "$main"/sharpyuv/*.c .github/scripts/measure-encode.c -lm -o "$out/encode.exe"

{
  echo "### libwebp heap high-water mark (PRINT_MEM_INFO) and process maximum RSS while decoding, as decodeWebp decodes"
  echo
  echo "| Image | Decoded bytes | Heap v1.6.0 | Heap f054d0c3 | RSS KiB v1.6.0 | RSS KiB f054d0c3 | Output v1.6.0 | Output f054d0c3 |"
  echo "|---|---|---|---|---|---|---|---|"
} | tee -a "$summary"
while read -r name width height lossless alpha; do
  image=$out/images/$name.webp
  "$out/encode.exe" "$image" "$width" "$height" "$lossless" "$alpha"
  read -r old_heap old_rss old_out <<< "$(measure heap-v1.6.0 "$image")"
  read -r new_heap new_rss new_out <<< "$(measure heap-f054d0c3 "$image")"
  channels=$([ "$alpha" = 1 ] && echo 4 || echo 3)
  echo "| $name ${width}x${height} | $((width * height * channels)) | $old_heap | $new_heap | $old_rss | $new_rss | $old_out | $new_out |" | tee -a "$summary"
  rm -f "$image"
done <<'EOF'
lossless-opaque-mobile 16383 5461 1 0
lossless-alpha-mobile 16383 4096 1 1
lossy-alpha-mobile 16383 4096 0 1
lossy-opaque-mobile 16383 5461 0 0
lossless-opaque-desktop 16383 10922 1 0
lossless-alpha-desktop 16383 8192 1 1
EOF

{
  echo
  echo "### Process maximum RSS while demuxing a file of empty unknown chunks after VP8X"
  echo
  echo "| File bytes | Chunks | RSS KiB v1.6.0 | RSS KiB f054d0c3 | Output v1.6.0 | Output f054d0c3 |"
  echo "|---|---|---|---|---|---|"
} | tee -a "$summary"
for size in 5242880 536870912 1073741824; do
  image=$out/images/flood.webp
  python3 -I .github/scripts/measure-flood.py "$image" "$size"
  read -r _ old_rss old_out <<< "$(measure rss-v1.6.0 "$image")"
  read -r _ new_rss new_out <<< "$(measure rss-f054d0c3 "$image")"
  echo "| $size | $(((size - 30) / 8)) | $old_rss | $new_rss | $old_out | $new_out |" | tee -a "$summary"
  rm -f "$image"
done
