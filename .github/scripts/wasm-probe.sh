#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/wasm-probe
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(sed "s|^|$lib/|" .github/scripts/wasm-sources.txt)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
native_flags="-DWEBP_USE_THREAD -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
runtime="$GEN/wasm-rt-impl.c $GEN/wasm-rt-mem-impl.c $GEN/wasm-rt-exceptions-impl.c"
conformance=$(sed -n 's|^[0-9a-f]*  \(.*\.webp\)\.pam$|'"$WEBP_TEST_DATA"'/\1|p' "$WEBP_TEST_DATA/libwebp_tests.md5")
fixtures=$(ls "$FIXTURES"/*.webp)
neon="-march=armv7-a -mfpu=neon -mfloat-abi=hard"

native() {
  $2 $native_flags $sources $package/cbits/canvas.c $package/cbits/native.c $package/cbits/clock.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$1.exe"
  builds="${builds:+$builds }$1"
}

wasm() {
  $3 -Wno-pass-failed -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DSANDBOX -I "$GEN" -I "$GEN/$2" -I "$GEN/simde" -I $package/cbits \
    "$GEN/$2/webp-wasm.c" $runtime $package/cbits/host.c $package/cbits/clock.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$1.exe"
  builds="${builds:+$builds }$1"
}

measure() {
  local build
  for build in $builds; do
    mkdir -p "$out/full-$build"
    "$out/$build.exe" check "$out/full-$build" 16384 $conformance $fixtures
    {
      "$out/$build.exe" time-set 5 $conformance
      "$out/$build.exe" time 5 $fixtures
    } > "$out/time-$build.tsv"
  done
  for build in $builds; do
    echo "full size outputs of $build: $(python3 -I .github/scripts/wasm-compare.py "$out/full-${builds%% *}" "$out/full-$build")"
  done
  python3 -I .github/scripts/wasm-report.py "$1" "$out" $builds | tee -a "$summary"
}

rm -rf "$out"
mkdir -p "$out"
for version in 14 18 20; do
  cc=clang-$version
  command -v "$cc" > /dev/null || continue
  builds=
  native native-O2-clang$version "$cc -O2"
  native native-O3-clang$version "$cc -O3"
  wasm wasm-sse2-O3-clang$version sse2 "$cc -O3"
  measure "$(uname -s) $(uname -m), $("$cc" --version | sed -n 1p), bounds checks"
done
builds=
native native-O2-gcc "gcc -O2"
wasm wasm-sse2-O3-gcc sse2 "gcc -O3"
measure "$(uname -s) $(uname -m), $(gcc --version | sed -n 1p), bounds checks"
builds=
armv7="clang-18 --target=arm-linux-gnueabihf -static $neon"
native armv7-native-O2-clang18 "$armv7 -O2"
wasm armv7-wasm-scalar-O3-clang18 scalar "$armv7 -O3 -DWASM_RT_USE_MMAP=1"
wasm armv7-wasm-sse2-O3-clang18 sse2 "$armv7 -O3 -DWASM_RT_USE_MMAP=1"
measure "armv7 static, $(clang-18 --version | sed -n 1p), bounds checks, memory reserved by mmap"
