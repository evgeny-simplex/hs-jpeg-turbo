#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/measure
package=JuicyPixels-libwebp
lib=$package/cbits/libwebp
sources=$(sed -n '/^library$/,/^$/p' $package/$package.cabal | grep -oE 'cbits/[^ ]+\.c' | sed "s|^|$package/|")
options=$(sed -n '/^library$/,/^$/s/^  cc-options: //p' $package/$package.cabal)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

mib() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'
}

field() {
  echo "$2" | sed -E "s/.*$1 ([0-9]+).*/\\1/"
}

measure() {
  local name=$1 frame=$2 kind=$3 image=$4 side limit line result rss row
  for side in 16384 4320; do
    row="| $name | $frame | $kind | $side |"
    for limit in 256 4096; do
      line=$(/usr/bin/time -f %M -o "$out/rss.txt" "$out/webp.exe" memory "$limit" "$side" "$image")
      echo "$line"
      result=$(echo "$line" | sed -E 's/^[^ ]+ ([^,]+),.*/\1/')
      rss=$(($(cat "$out/rss.txt") * 1024))
      if [ "$limit" = 256 ]; then
        row="$row $(mib "$(field output "$line")") | $(mib "$(field demuxer "$line")") | $result | $(mib "$(field peak "$line")") | $(mib "$rss") |"
      else
        row="$row $result | $(mib "$(field peak "$line")") | $(mib "$rss") |"
      fi
    done
    echo "$row" >> "$out/table.md"
  done
  rm -f "$image"
}

rm -rf "$out/images" "$out/table.md"
mkdir -p "$out/images"
echo "libwebp $(git -C "$lib" rev-parse HEAD); $(echo "$sources" | wc -w) C files; cc-options: $options"
gcc -O2 $options -I "$package/cbits" -I "$lib" $sources .github/scripts/webp.c -lpthread -lm -o "$out/webp.exe"
gcc -O2 -I "$lib" -I "$lib/src" "$lib"/src/*/*.c "$lib"/sharpyuv/*.c .github/scripts/measure-encode.c -lm -o "$out/encode.exe"
gcc -O2 -I "$lib" -I "$lib/src" "$lib"/src/*/*.c "$lib"/sharpyuv/*.c .github/scripts/measure-craft.c -lm -o "$out/craft.exe"

while read -r name frame kind width height lossless alpha method; do
  "$out/encode.exe" "$out/images/$name.webp" "$width" "$height" "$lossless" "$alpha" "$method"
  measure "$name" "$frame" "$kind" "$out/images/$name.webp"
done <<'EOF'
lossy-16383x8191 16383x8191 lossy 16383 8191 0 0 4
lossy-alpha-16383x8191 16383x8191 lossy,alpha 16383 8191 0 1 4
lossy-alpha-unfiltered-16383x8191 16383x8191 lossy,alpha 16383 8191 0 2 4
lossless-16383x16383 16383x16383 lossless 16383 16383 1 0 4
lossless-alpha-16383x16383 16383x16383 lossless,alpha 16383 16383 1 1 4
lossless-alpha-method6-4320x4320 4320x4320 lossless,alpha 4320 4320 1 1 6
EOF

while read -r name frame kind width height groups pattern bits bytes; do
  "$out/craft.exe" "$out/images/$name.webp" "$kind" "$width" "$height" "$groups" "$pattern" "$bits" "$bytes"
  measure "$name" "$frame" "$kind" "$out/images/$name.webp"
done <<'EOF'
transforms-lossless-16384x16384 16384x16384 lossless 16384 16384 2 last 2 0
transforms-alpha-16383x8191 16383x8191 alpha 16383 8191 2 last 2 0
huffman-lossless-1024x1024 1024x1024 lossless 1024 1024 65536 cycle 2 0
huffman-alpha-1024x1024 1024x1024 alpha 1024 1024 65536 cycle 2 0
groups-lossless-16384x16384 16384x16384 lossless 16384 16384 65536 cycle 6 0
chunks-16MiB 16x16 lossless 16 16 0 cycle 2 16777216
chunks-16MiB-huffman-lossless-1024x1024 1024x1024 lossless 1024 1024 65536 cycle 2 16777216
EOF

{
  echo "### libwebp decoding memory at $(git -C "$lib" rev-parse --short=8 HEAD), as decodeWebp decodes: at full size (sides up to 16384) and halved while a side exceeds 4320"
  echo
  echo "Counted: the bytes of libwebp's allocations, each with its 16-byte header, the demuxer's included, and the output image; peak: their maximum during the decode. RSS: the maximum resident set of the process, the input included. Limits: 256 MiB, the limit of mobile builds, and 4096 MiB, which these images do not reach."
  echo
  echo "| Image | Frame | Kind | Max side | Output MiB | Demuxer MiB | 256 MiB: result | peak MiB | RSS MiB | 4096 MiB: result | peak MiB | RSS MiB |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
  cat "$out/table.md"
} | tee -a "$summary"
