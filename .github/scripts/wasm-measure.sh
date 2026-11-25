#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/wasm-measure
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(sed "s|^|$lib/|" .github/scripts/wasm-sources.txt)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
cc=${CC:-cc}
platform="$(uname -s) $(uname -m)"
native_flags="-O2 -DWEBP_USE_THREAD -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
runtime="$GEN/wasm-rt-impl.c $GEN/wasm-rt-mem-impl.c $GEN/wasm-rt-exceptions-impl.c"
conformance=$(sed -n 's|^[0-9a-f]*  \(.*\.webp\)\.pam$|'"$WEBP_TEST_DATA"'/\1|p' "$WEBP_TEST_DATA/libwebp_tests.md5")
fixtures=$(ls "$FIXTURES"/*.webp)
builds="native native-scalar"
wasm_builds=

native() {
  $cc $native_flags $2 $sources $package/cbits/canvas.c $package/cbits/native.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$1.exe"
}

wasm() {
  $cc -O2 $3 -DSANDBOX -I "$GEN" -I "$GEN/$2" -I "$GEN/simde" -I $package/cbits "$GEN/$2/webp-wasm.c" $runtime $package/cbits/host.c \
    .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$1.exe"
  wasm_builds="$wasm_builds $1"
}

rss() {
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident set size/ {printf "%.1f", $1 / 1048576}'
  else
    /usr/bin/time -f %M "$@" 2>&1 >/dev/null | tail -n 1 | awk '{printf "%.1f", $1 / 1024}'
  fi
}

compare() {
  python3 -I .github/scripts/wasm-compare.py "$@"
}

rm -rf "$out"
mkdir -p "$out"
"$cc" --version | sed -n 1p
echo "$platform"

native native ""
native native-scalar "-DHAVE_CONFIG_H -I .github/scripts/scalar"
for variant in scalar simd128 sse2; do
  wasm "wasm-$variant-bounds" $variant "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1"
  wasm "wasm-$variant-guard" $variant "-DWASM_RT_MEMCHECK_GUARD_PAGES=1"
done
if [ "$(uname -m)" = x86_64 ]; then
  native native-v2 "-march=x86-64-v2"
  wasm wasm-sse2-bounds-v2 sse2 "-march=x86-64-v2 -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1"
  builds="$builds native-v2"
fi
builds="$builds$wasm_builds"
cc_builds=$builds
clang_builds=
if [ "$(uname -s)" = Linux ]; then
  cc=clang
  clang --version | sed -n 1p
  native native-clang ""
  wasm wasm-scalar-bounds-clang scalar "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1"
  wasm wasm-sse2-bounds-clang sse2 "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1"
  wasm wasm-sse2-guard-clang sse2 "-DWASM_RT_MEMCHECK_GUARD_PAGES=1"
  cc=${CC:-cc}
  clang_builds="native-clang wasm-scalar-bounds-clang wasm-sse2-bounds-clang wasm-sse2-guard-clang"
  builds="$builds $clang_builds"
fi

for build in $builds; do
  mkdir -p "$out/full-$build" "$out/scaled-$build"
  "$out/$build.exe" check "$out/full-$build" 16384 $conformance $fixtures
  "$out/$build.exe" check "$out/scaled-$build" 64 $conformance $fixtures
done

ls "$out/full-native" > "$out/outputs.txt"
awk 'NR == FNR {outputs[$1]; next} $2 in outputs' "$out/outputs.txt" "$WEBP_TEST_DATA/libwebp_tests.md5" > "$out/expected.md5"
[ "$(wc -l < "$out/expected.md5")" -eq 96 ]
for build in $builds; do
  python3 -I .github/scripts/wasm-compare.py md5 "$out/expected.md5" "$out/full-$build"
done

{
  echo "### $platform: outputs compared with the native build"
  echo
  echo "Full size: all 96 conformance files equal to libwebp_tests.md5 in every build. Each row compares all outputs of the build with those of \`native\`; scaled outputs have sides of at most 64."
  echo
  echo "| Build | Full size | Scaled |"
  echo "|---|---|---|"
  for build in $builds; do
    echo "| $build | $(compare "$out/full-native" "$out/full-$build") | $(compare "$out/scaled-native" "$out/scaled-$build") |"
  done
  echo
  echo "Scaled, the wasm builds compared with \`native-scalar\`, the same C code:"
  echo
  for build in $wasm_builds; do
    echo "- $build: $(compare "$out/scaled-native-scalar" "$out/scaled-$build")"
  done
  echo
} | tee -a "$summary"

for build in $builds; do
  {
    "$out/$build.exe" time-set 15 $conformance
    "$out/$build.exe" time 9 $fixtures
  } > "$out/time-$build.tsv"
done
python3 -I .github/scripts/wasm-report.py "$platform, $("$cc" --version | sed -n 1p)" "$out" $cc_builds | tee -a "$summary"
if [ -n "$clang_builds" ]; then
  python3 -I .github/scripts/wasm-report.py "$platform, $(clang --version | sed -n 1p)" "$out" $clang_builds | tee -a "$summary"
fi

{
  echo "### $platform: maximum resident set of one decode, MiB"
  echo
  echo "| Build | $(for f in $fixtures; do printf '%s | ' "$(basename "$f")"; done)"
  echo "|---|$(for f in $fixtures; do printf -- '---|'; done)"
  for build in $builds; do
    echo "| $build | $(for f in $fixtures; do printf '%s | ' "$(rss "$out/$build.exe" time 1 "$f")"; done)"
  done
  echo
} | tee -a "$summary"

{
  echo "### $platform: sandbox calls"
  echo
  echo '```'
  for build in $wasm_builds; do
    echo "== $build"
    "$out/$build.exe" trap
    "$out/$build.exe" instantiate 200
    for mib in 2 4 8 16 32 64 128; do
      "$out/$build.exe" limit "$FIXTURES/tall-lossless.webp" $mib
    done
    case $build in
      *-bounds) "$out/$build.exe" fuzz 16384 $conformance $fixtures ;;
    esac
  done
  echo '```'
  echo
} | tee -a "$summary"

if [ "$(uname -s)" = Linux ]; then
  mkdir -p "$out/objects-native" "$out/objects-native-scalar"
  for source in $sources; do
    $cc $native_flags -c "$source" -o "$out/objects-native/$(basename "$source" .c).o"
    $cc $native_flags -DHAVE_CONFIG_H -I .github/scripts/scalar -c "$source" -o "$out/objects-native-scalar/$(basename "$source" .c).o"
  done
  {
    echo "### $platform: code size"
    echo
    echo '```'
    echo "native, $(echo "$sources" | wc -w) libwebp objects"
    size -t "$out/objects-native"/*.o | sed -n '1p;$p'
    echo "native-scalar"
    size -t "$out/objects-native-scalar"/*.o | sed -n '1p;$p'
    for variant in scalar simd128 sse2; do
      $cc -O2 -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -I "$GEN" -I "$GEN/$variant" -I "$GEN/simde" -c "$GEN/$variant/webp-wasm.c" -o "$out/$variant-bounds.o"
      $cc -O2 -DWASM_RT_MEMCHECK_GUARD_PAGES=1 -I "$GEN" -I "$GEN/$variant" -I "$GEN/simde" -c "$GEN/$variant/webp-wasm.c" -o "$out/$variant-guard.o"
      echo "wasm2c $variant, bounds checks and guard pages"
      size "$out/$variant-bounds.o" "$out/$variant-guard.o"
    done
    echo "wasm2c runtime and host, bounds checks"
    for source in $runtime $package/cbits/host.c; do
      $cc -O2 -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -I "$GEN" -I "$GEN/scalar" -I $package/cbits -c "$source" -o "$out/$(basename "$source" .c).o"
    done
    size -t "$out"/wasm-rt-*.o "$out/host.o" | sed -n '1p;$p'
    echo '```'
    echo
  } | tee -a "$summary"
fi
