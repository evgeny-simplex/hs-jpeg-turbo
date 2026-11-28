#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/gif-compare
package=JuicyPixels-sandbox
guest=$package/guest
sandbox_flags="-DSANDBOX -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DWASM_RT_STACK_DEPTH_COUNT=1 -DWASM_RT_MAX_CALL_STACK_DEPTH=128 -I $package/cbits -I $package/cbits/wasm2c"
sandbox_sources="$package/cbits/host.c $package/cbits/module.c $package/cbits/clock.c $package/cbits/wasm2c/wasm-rt-mem-impl.c"
suite=$(ls "$GIF_TEST_SUITE"/*.gif)
workloads=$(ls "$GIF_WORKLOADS"/*.gif)

rm -rf "$out" "$guest/nsgif" "$guest/giflib"
mkdir -p "$out" "$guest/nsgif" "$guest/giflib"
cp "$NSGIF"/include/nsgif.h "$NSGIF"/src/gif.c "$NSGIF"/src/lzw.c "$NSGIF"/src/lzw.h "$guest/nsgif/"
cp "$GIFLIB"/gif_lib.h "$GIFLIB"/gif_lib_private.h "$GIFLIB"/gif_hash.h "$GIFLIB"/dgif_lib.c "$GIFLIB"/gifalloc.c "$GIFLIB"/gif_err.c \
  "$GIFLIB"/openbsd-reallocarray.c "$guest/giflib/"
cp "$guest/gif.c" "$out/gif-wuffs.c"
for decoder in wuffs nsgif giflib; do
  if [ $decoder = wuffs ]; then
    cp "$out/gif-wuffs.c" "$guest/gif.c"
  else
    cp ".github/scripts/gif-$decoder.c" "$guest/gif.c"
  fi
  GITHUB_STEP_SUMMARY=/dev/null bash .github/scripts/wasm-generate.sh "$out/wasm-$decoder" > "$out/generate-$decoder.txt"
  code=$("$WABT/bin/wasm-objdump" -h "$out/wasm-$decoder/obj/$guest/gif.o" | sed -n 's/^ *Code start=.*size=0x\([0-9a-f]*\).*/\1/p')
  gcc -O2 $sandbox_flags $sandbox_sources .github/scripts/sandbox-bench.c -lpthread -lm -o "$out/bench-$decoder.exe"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' $decoder "$(wc -l < "$guest/gif.c")" $((16#$code)) "$(wc -c < "$out/wasm-$decoder/checked.wasm")" \
    "$(wc -c < $package/cbits/image-wasm.c)" "$(size "$out/bench-$decoder.exe" | sed -n '2s/^ *\([0-9]*\).*/\1/p')" >> "$out/sizes.tsv"
  mkdir -p "$out/frames-$decoder"
  "$out/bench-$decoder.exe" frames "$out/frames-$decoder" 16384 $suite
  SANDBOX_DEADLINE_MS=600000 "$out/bench-$decoder.exe" frames-time 9 16384 $workloads > "$out/time-$decoder.tsv"
done
cp "$out/gif-wuffs.c" "$guest/gif.c"
rm -rf "$guest/nsgif" "$guest/giflib"
git checkout -- $package/cbits
python3 -I .github/scripts/gif-compare.py "$GIF_TEST_SUITE" "$out" wuffs nsgif giflib | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
for side in 16384 1920 64; do
  "$out/bench-wuffs.exe" frames-count $side $workloads $suite
  "$out/bench-wuffs.exe" frames-count-changed $side $suite
done > "$out/count.tsv"
python3 -I .github/scripts/sandbox-budget.py "$out/count.tsv" "GIF=$(sed -n 's/^  GIF -> \([0-9]*\)$/\1/p' $package/src/Codec/Picture/Sandbox.hsc)" |
  tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
