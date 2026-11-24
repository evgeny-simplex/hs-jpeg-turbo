#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/wasm-armv7
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(sed "s|^|$lib/|" .github/scripts/wasm-sources.txt)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
cc="arm-linux-gnueabihf-gcc -static"
neon="-march=armv7-a -mfpu=neon -mfloat-abi=hard"
vfp="-march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard"
platform="armv7 static, $(uname -m) kernel $(uname -r)"
native_flags="-O2 -DWEBP_USE_THREAD -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
runtime="$GEN/wasm-rt-impl.c $GEN/wasm-rt-mem-impl.c $GEN/wasm-rt-exceptions-impl.c"
conformance=$(sed -n 's|^[0-9a-f]*  \(.*\.webp\)\.pam$|'"$WEBP_TEST_DATA"'/\1|p' "$WEBP_TEST_DATA/libwebp_tests.md5")
fixtures=$(ls "$FIXTURES"/*.webp)
builds=

native() {
  $cc $2 $native_flags $sources $package/cbits/canvas.c $package/cbits/native.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$1.exe"
  builds="$builds $1"
}

wasm() {
  $cc $neon -O2 $3 -DSANDBOX -I "$GEN" -I "$GEN/$2" -I "$GEN/simde" -I $package/cbits "$GEN/$2/webp-wasm.c" $runtime $package/cbits/host.c \
    .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$1.exe"
  builds="$builds $1"
}

rm -rf "$out"
mkdir -p "$out"
arm-linux-gnueabihf-gcc --version | sed -n 1p
{
  echo "### $platform: execution of armv7 binaries"
  echo '```'
  ls /proc/sys/fs/binfmt_misc/ || true
  grep -l arm /proc/sys/fs/binfmt_misc/* 2>/dev/null || echo "no binfmt_misc entry for arm"
  grep -m 1 -E 'CPU part|CPU implementer' /proc/cpuinfo || true
  lscpu | grep -E 'Model name|op-mode' || true
  echo '```'
} | tee -a "$summary"

native native-neon "$neon"
native native-c "$vfp"
for variant in scalar simd128 sse2; do
  wasm "wasm-$variant-malloc" $variant "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1"
  wasm "wasm-$variant-mmap" $variant "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DWASM_RT_USE_MMAP=1"
done
file "$out/native-neon.exe"

for build in $builds; do
  mkdir -p "$out/full-$build" "$out/scaled-$build"
  "$out/$build.exe" check "$out/full-$build" 16384 $conformance $fixtures
  "$out/$build.exe" check "$out/scaled-$build" 64 $conformance $fixtures
done
ls "$out/full-native-neon" > "$out/outputs.txt"
awk 'NR == FNR {outputs[$1]; next} $2 in outputs' "$out/outputs.txt" "$WEBP_TEST_DATA/libwebp_tests.md5" > "$out/expected.md5"
[ "$(wc -l < "$out/expected.md5")" -eq 96 ]
for build in $builds; do
  python3 -I .github/scripts/wasm-compare.py md5 "$out/expected.md5" "$out/full-$build"
done
{
  echo "### $platform: outputs compared with native-neon and native-c"
  echo
  echo "| Build | Full size, to native-neon | Scaled, to native-neon | Scaled, to native-c |"
  echo "|---|---|---|---|"
  for build in $builds; do
    echo "| $build | $(python3 -I .github/scripts/wasm-compare.py "$out/full-native-neon" "$out/full-$build") | $(python3 -I .github/scripts/wasm-compare.py "$out/scaled-native-neon" "$out/scaled-$build") | $(python3 -I .github/scripts/wasm-compare.py "$out/scaled-native-c" "$out/scaled-$build") |"
  done
  echo
} | tee -a "$summary"

for build in $builds; do
  {
    "$out/$build.exe" time-set 9 $conformance
    "$out/$build.exe" time 5 $fixtures
  } > "$out/time-$build.tsv"
done
python3 -I .github/scripts/wasm-report.py "$platform" "$out" $builds | tee -a "$summary"

{
  echo "### $platform: maximum resident set of one decode, MiB"
  echo
  echo "| Build | $(for f in $fixtures; do printf '%s | ' "$(basename "$f")"; done)"
  echo "|---|$(for f in $fixtures; do printf -- '---|'; done)"
  for build in $builds; do
    echo "| $build | $(for f in $fixtures; do printf '%s | ' "$(/usr/bin/time -f %M "$out/$build.exe" time 1 "$f" 2>&1 >/dev/null | tail -n 1 | awk '{printf "%.1f", $1 / 1024}')"; done)"
  done
  echo
  echo "### $platform: sandbox calls"
  echo
  echo '```'
  for build in $builds; do
    case $build in
      wasm-*)
        echo "== $build"
        "$out/$build.exe" trap
        "$out/$build.exe" instantiate 100
        for mib in 2 8 32 128; do
          "$out/$build.exe" limit "$FIXTURES/tall-lossless.webp" $mib
        done
        ;;
    esac
  done
  echo '```'
  echo
} | tee -a "$summary"

mkdir -p "$out/objects-neon" "$out/objects-c"
for source in $sources; do
  arm-linux-gnueabihf-gcc $neon $native_flags -c "$source" -o "$out/objects-neon/$(basename "$source" .c).o"
  arm-linux-gnueabihf-gcc $vfp $native_flags -c "$source" -o "$out/objects-c/$(basename "$source" .c).o"
done
{
  echo "### $platform: code size"
  echo '```'
  echo "native-neon, $(echo "$sources" | wc -w) libwebp objects"
  arm-linux-gnueabihf-size -t "$out/objects-neon"/*.o | sed -n '1p;$p'
  echo "native-c"
  arm-linux-gnueabihf-size -t "$out/objects-c"/*.o | sed -n '1p;$p'
  for variant in scalar simd128 sse2; do
    arm-linux-gnueabihf-gcc $neon -O2 -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -I "$GEN" -I "$GEN/$variant" -I "$GEN/simde" -c "$GEN/$variant/webp-wasm.c" -o "$out/$variant.o"
    echo "wasm2c $variant, bounds checks"
    arm-linux-gnueabihf-size "$out/$variant.o"
  done
  echo '```'
} | tee -a "$summary"
