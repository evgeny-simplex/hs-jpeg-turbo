#!/usr/bin/env bash

set -euo pipefail

target=$1
cc=$2
out=dist-newstyle/sandbox-tls/$target
package=JuicyPixels-sandbox
library=$(sed -n '/^library$/,/^$/p' $package/$package.cabal)
options=$(echo "$library" | sed -n 's/^  cc-options: //p')
sources=$(echo "$library" | grep -oE 'cbits/[^ ]+\.c' | sed "s|^|$package/|")

rm -rf "$out"
mkdir -p "$out"
for source in $sources; do
  $cc $options -I $package/cbits -I $package/cbits/wasm2c -c "$source" -o "$out/$(basename "$source" .c).o"
done
if [ "$(uname)" = Darwin ]; then
  references=$(nm -u "$out"/*.o | grep -E '_tlv_bootstrap|__emutls' || true)
  sections=$(otool -l "$out"/*.o | grep -E 'sectname __thread_' || true)
else
  references=$(llvm-nm -u "$out"/*.o | grep -E '__tls_get_addr|__emutls' || true)
  sections=$(llvm-readelf -S -W "$out"/*.o | grep -E '\.t(data|bss)' || true)
fi
echo "$target, $(echo "$sources" | wc -w) objects: $(printf '%s' "$references" | grep -c . || true) references to thread-local storage, $(printf '%s' "$sections" | grep -c . || true) thread-local sections" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
printf '%s\n' "$references" "$sections" | sed '/^$/d'
[ -z "$references$sections" ]
