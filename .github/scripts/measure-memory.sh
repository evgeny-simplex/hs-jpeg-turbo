#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/measure
package=JuicyPixels-libwebp
lib=$package/cbits/libwebp
sources=$(sed -n '/^library$/,/^$/p' $package/$package.cabal | grep -oE 'cbits/[^ ]+\.c' | sed "s|^|$package/|")
options=$(sed -n '/^library$/,/^$/s/^  cc-options: //p' $package/$package.cabal)
maxAllocable=$(echo "$options" | grep -oE 'WEBP_MAX_ALLOCABLE_MEMORY=[0-9]+' | cut -d= -f2)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
mib=1048576

build() {
  gcc -O2 $options $2 -I "$lib" $sources .github/scripts/webp.c -lpthread -lm -o "$out/$1.exe"
}

decoder_memory() {
  local kind=$1 pixels=$(($2 * $3)) rows=$((4 * mib)) lossless
  lossless=$((4 * pixels + 3 * pixels / 4 + 2 * maxAllocable + maxAllocable / 16))
  case $kind in
    lossy) echo $rows ;;
    lossless) echo $((rows + lossless)) ;;
    alpha) echo $((rows + 2 * pixels + lossless)) ;;
  esac
}

mib2() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'
}

measure() {
  local name=$1 kind=$2 width=$3 height=$4 image=$5 side heap rss decoded header canvas formula
  for side in 16384 4320; do
    rm -rf "$out/decoded"
    mkdir -p "$out/decoded"
    /usr/bin/time -f %M -o "$out/rss.txt" "$out/heap.exe" check "$out/decoded" "$side" "$image" 2> "$out/heap.txt"
    heap=$(sed -n 's/^high-water mark: //p' "$out/heap.txt")
    rm -rf "$out/decoded"
    mkdir -p "$out/decoded"
    /usr/bin/time -f %M -o "$out/rss.txt" "$out/rss.exe" check "$out/decoded" "$side" "$image"
    rss=$(($(cat "$out/rss.txt") * 1024))
    decoded=$(ls "$out/decoded")
    formula=$(decoder_memory "$kind" "$width" "$height")
    if [ "${decoded##*.}" = err ]; then
      echo "| $name | ${width}x${height} | $kind | $side | $(cat "$out/decoded/$decoded") | | $(mib2 "$heap") | $(mib2 "$formula") | | $(mib2 "$rss") |" | tee -a "$summary"
      continue
    fi
    header=$(head -n 3 "$out/decoded/$decoded" | tr '\n' ' ')
    case $decoded in
      *.pam) canvas=$(echo "$header" | awk '{print $3 "x" $5 " " $3 * $5 * 4}') ;;
      *.ppm) canvas=$(echo "$header" | awk '{print $2 "x" $3 " " $2 * $3 * 3}') ;;
    esac
    echo "| $name | ${width}x${height} | $kind | $side | ${canvas% *} | $(mib2 "${canvas#* }") | $(mib2 "$heap") | $(mib2 "$formula") | $(mib2 $((heap + ${canvas#* }))) | $(mib2 "$rss") |" | tee -a "$summary"
  done
  rm -f "$image"
}

rm -rf "$out/images" "$out/decoded"
mkdir -p "$out/images"
echo "libwebp $(git -C "$lib" describe --tags) at $(git -C "$lib" rev-parse HEAD); $(echo "$sources" | wc -w) C files; cc-options: $options"
build heap -DPRINT_MEM_INFO
build rss ""
gcc -O2 -I "$lib" -I "$lib/src" "$lib"/src/*/*.c "$lib"/sharpyuv/*.c .github/scripts/measure-encode.c -lm -o "$out/encode.exe"
gcc -O2 -I "$lib" -I "$lib/src" "$lib"/src/*/*.c "$lib"/sharpyuv/*.c .github/scripts/measure-craft.c -lm -o "$out/craft.exe"
groups=$((maxAllocable / (4 * 2954)))

{
  echo "### libwebp 1.6.0 decoding memory, as decodeWebp decodes: at full size (sides up to 16384) and halved while a side exceeds 4320"
  echo
  echo "Heap: the high-water mark of libwebp's allocations (PRINT_MEM_INFO), the demuxer included. Formula: the decoder memory that decodeWebp checks, without the output image. RSS: the maximum resident set of the process, input and output image included."
  echo
  echo "| Image | Frame | Kind | Max side | Output | Output MiB | Heap MiB | Formula MiB | Heap + output MiB | RSS MiB |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
} | tee -a "$summary"

while read -r name width height lossless alpha kind; do
  "$out/encode.exe" "$out/images/$name.webp" "$width" "$height" "$lossless" "$alpha"
  measure "$name" "$kind" "$width" "$height" "$out/images/$name.webp"
done <<'EOF'
lossy-16383x8191 16383 8191 0 0 lossy
lossless-opaque-4320x3758 4320 3758 1 0 lossless
lossless-alpha-4320x3328 4320 3328 1 1 lossless
lossless-alpha-4322x3864 4322 3864 1 1 lossless
lossy-alpha-4320x2709 4320 2709 0 2 alpha
lossy-alpha-4322x3746 4322 3746 0 2 alpha
EOF

while read -r name kind width height groups bytes; do
  "$out/craft.exe" "$out/images/$name.webp" "$kind" "$width" "$height" "$groups" "$bytes"
  measure "$name" "$kind" "$width" "$height" "$out/images/$name.webp"
done <<EOF
huffman-lossless-4320x3328 lossless 4320 3328 $groups 0
huffman-lossless-4322x3864 lossless 4322 3864 $groups 0
huffman-alpha-4320x2709 alpha 4320 2709 $groups 0
huffman-alpha-4322x3746 alpha 4322 3746 $groups 0
chunks-16MiB lossless 16 16 0 16777216
chunks-16MiB-huffman-lossless-4322x3864 lossless 4322 3864 $groups 16777216
chunks-16MiB-huffman-alpha-4322x3746 alpha 4322 3746 $groups 16777216
EOF
