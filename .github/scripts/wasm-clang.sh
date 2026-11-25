#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/wasm-clang
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(sed "s|^|$lib/|" .github/scripts/wasm-sources.txt)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
platform="$(uname -s) $(uname -m)"
native_flags="-O2 -DWEBP_USE_THREAD -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
runtime="$GEN/wasm-rt-impl.c $GEN/wasm-rt-mem-impl.c $GEN/wasm-rt-exceptions-impl.c"
conformance=$(sed -n 's|^[0-9a-f]*  \(.*\.webp\)\.pam$|'"$WEBP_TEST_DATA"'/\1|p' "$WEBP_TEST_DATA/libwebp_tests.md5")
fixtures=$(ls "$FIXTURES"/*.webp)

rm -rf "$out"
mkdir -p "$out"
for version in 14 15 16 17 18 19 20 21; do
  cc=clang-$version
  command -v "$cc" > /dev/null || continue
  "$cc" --version | sed -n 1p
  "$cc" $native_flags $sources $package/cbits/canvas.c $package/cbits/native.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/native-clang$version.exe"
  builds="native-clang$version"
  for variant in scalar sse2; do
    "$cc" -O2 -Wno-pass-failed -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DSANDBOX -I "$GEN" -I "$GEN/$variant" -I "$GEN/simde" -I $package/cbits \
      "$GEN/$variant/webp-wasm.c" $runtime $package/cbits/host.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/wasm-$variant-bounds-clang$version.exe"
    builds="$builds wasm-$variant-bounds-clang$version"
  done
  for build in $builds; do
    mkdir -p "$out/full-$build"
    "$out/$build.exe" check "$out/full-$build" 16384 $conformance $fixtures
    {
      "$out/$build.exe" time-set 5 $conformance
      "$out/$build.exe" time 5 $fixtures
    } > "$out/time-$build.tsv"
  done
  echo "full size outputs of wasm-sse2-bounds-clang$version: $(python3 -I .github/scripts/wasm-compare.py "$out/full-native-clang$version" "$out/full-wasm-sse2-bounds-clang$version")"
  python3 -I .github/scripts/wasm-report.py "$platform, $("$cc" --version | sed -n 1p)" "$out" $builds | tee -a "$summary"
done
