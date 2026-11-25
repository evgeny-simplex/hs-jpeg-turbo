#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/wasm-probe
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(sed "s|^|$lib/|" .github/scripts/wasm-sources.txt)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
native_flags="-O2 -DWEBP_USE_THREAD -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
runtime="$GEN/wasm-rt-impl.c $GEN/wasm-rt-mem-impl.c $GEN/wasm-rt-exceptions-impl.c"
fixtures=$(ls "$FIXTURES"/*lossy*.webp)

rm -rf "$out"
mkdir -p "$out"
clang --version | sed -n 1p
clang $native_flags $sources $package/cbits/canvas.c $package/cbits/native.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/native.exe"
"$out/native.exe" time 5 $fixtures > "$out/time-native.tsv"
builds=native
k=0
while IFS='|' read -r compiler flags; do
  k=$((k + 1))
  $compiler -O2 $flags -Wno-pass-failed -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DSANDBOX -I "$GEN" -I "$GEN/sse2" -I "$GEN/simde" -I $package/cbits \
    "$GEN/sse2/webp-wasm.c" $runtime $package/cbits/host.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/probe$k.exe"
  "$out/probe$k.exe" time 5 $fixtures > "$out/time-probe$k.tsv"
  echo "probe$k: $compiler $flags" | tee -a "$summary"
  builds="$builds probe$k"
done <<'EOF'
clang|
clang|-O3
clang|-mcpu=apple-m1
clang|-march=armv8.2-a+dotprod+fp16
clang|-mcpu=neoverse-n2
clang|-fno-slp-vectorize -fno-vectorize
gcc|
EOF
python3 -I .github/scripts/wasm-report.py "$(uname -s) $(uname -m), the sse2 module with bounds checks by compiler flags" "$out" $builds | tee -a "$summary"
