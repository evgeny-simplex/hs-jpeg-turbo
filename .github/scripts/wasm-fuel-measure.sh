#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/wasm-fuel
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(sed "s|^|$lib/|" .github/scripts/wasm-sources.txt)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
platform=$1
shift
native_flags="-DWEBP_USE_THREAD -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
runtime="$GEN/wasm-rt-impl.c $GEN/wasm-rt-mem-impl.c $GEN/wasm-rt-exceptions-impl.c"
conformance=$(sed -n 's|^[0-9a-f]*  \(.*\.webp\)\.pam$|'"$WEBP_TEST_DATA"'/\1|p' "$WEBP_TEST_DATA/libwebp_tests.md5")
fixtures=$(ls "$FIXTURES"/*.webp)
crafted=$(ls "$CRAFTED"/*.webp)
rule="WEBP_BUDGET_BASE=$RULE_BASE WEBP_BUDGET_PER_BYTE=$RULE_PER_BYTE WEBP_BUDGET_PER_PIXEL=$RULE_PER_PIXEL"
variants="sse2 sse2-loops sse2-calls sse2-bulk sse2-log"
counted="sse2-loops sse2-calls sse2-bulk"

build() {
  local name=$1 command=$2 variant=$3 unit extra=
  if [ "$variant" = native ]; then
    $command $native_flags $sources $package/cbits/canvas.c $package/cbits/native.c $package/cbits/clock.c .github/scripts/wasm-bench.c \
      -lpthread -lm -o "$out/$name.exe"
    return
  fi
  unit=$GEN/$variant/webp-wasm.c
  case $variant in
    sse2-loops | sse2-calls | sse2-bulk) extra=-DWEBP_SANDBOX_FUEL_GLOBAL ;;
    sse2-log) unit=$package/cbits/fuel-log.c ;;
  esac
  $command -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DSANDBOX $extra -I "$GEN" -I "$GEN/$variant" -I "$GEN/simde" -I $package/cbits "$unit" $runtime \
    $package/cbits/host.c $package/cbits/clock.c .github/scripts/wasm-bench.c -lpthread -lm -o "$out/$name.exe"
}

timing() {
  local tsv=$1 exe=$2
  shift 2
  env "$@" "$exe" time-set 15 $conformance > "$tsv"
  env "$@" "$exe" time 9 $fixtures >> "$tsv"
}

rm -rf "$out"
mkdir -p "$out"
echo "$platform"
for config in "$@"; do
  name=${config%%|*}
  command=${config#*|}
  pids=
  for variant in native $variants; do
    build "$variant-$name" "$command" $variant &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid"
  done

  for variant in $variants; do
    mkdir -p "$out/full-$variant-$name"
    "$out/$variant-$name.exe" check "$out/full-$variant-$name" 16384 $conformance $fixtures $crafted
  done
  mkdir -p "$out/full-rule-$name"
  env $rule WEBP_INTERVAL=4096 "$out/sse2-bulk-$name.exe" check "$out/full-rule-$name" 16384 $conformance $fixtures $crafted
  {
    echo "### $platform, $name \`$command\`: outputs of the builds with budget checks compared with the sse2 build"
    echo
    for build in sse2-loops sse2-calls sse2-bulk sse2-log rule; do
      echo "- $build: $(python3 -I .github/scripts/wasm-compare.py "$out/full-sse2-$name" "$out/full-$build-$name")"
    done
    echo
  } | tee -a "$summary"

  for variant in native $variants; do
    timing "$out/time-$variant-$name.tsv" "$out/$variant-$name.exe"
  done
  timing "$out/time-sse2-bulk-deadline-$name.tsv" "$out/sse2-bulk-$name.exe" WEBP_DEADLINE_MS=600000 WEBP_INTERVAL=4096
  timing "$out/time-sse2-bulk-rule-$name.tsv" "$out/sse2-bulk-$name.exe" $rule WEBP_DEADLINE_MS=600000 WEBP_INTERVAL=4096
  python3 -I .github/scripts/wasm-report.py "$platform, $name \`$command\`, bounds checks" "$out" sse2-$name sse2-loops-$name sse2-calls-$name \
    sse2-bulk-$name sse2-log-$name sse2-bulk-deadline-$name sse2-bulk-rule-$name native-$name | tee -a "$summary"

  {
    echo "### $platform, $name: decodes and loops stopped by the budget and by the deadline"
    echo
    echo '```'
    for variant in $counted; do
      echo "== $variant"
      WEBP_BUDGET_BASE=100000000 "$out/$variant-$name.exe" spin 5
      for interval in 4096 65536 1048576; do
        WEBP_DEADLINE_MS=20 WEBP_INTERVAL=$interval "$out/$variant-$name.exe" spin 20
      done
      for image in tall-lossy-alpha.webp tall-lossless.webp photo-2560x1440-lossy.webp; do
        for interval in 1024 4096 65536; do
          WEBP_DEADLINE_MS=5 WEBP_INTERVAL=$interval "$out/$variant-$name.exe" stop 20 "$FIXTURES/$image"
        done
      done
      WEBP_BUDGET_BASE=1000000 "$out/$variant-$name.exe" tree 24
    done
    echo '```'
    echo
  } | tee -a "$summary"
done

if [ "${COUNT:-}" = 1 ]; then
  name=${1%%|*}
  for variant in $counted sse2-log; do
    for side in 16384 64; do
      "$out/$variant-$name.exe" count $side $conformance $fixtures $crafted
    done > "$out/count-$variant.tsv"
  done
  for variant in $counted; do
    for side in 16384 64; do
      "$out/$variant-$name.exe" count-changed $side $conformance $fixtures
    done >> "$out/count-$variant.tsv"
  done
  python3 -I .github/scripts/wasm-budget.py "$out" sse2-bulk sse2-calls sse2-loops sse2-log | tee -a "$summary"
  {
    echo "### The rule base $RULE_BASE, per byte $RULE_PER_BYTE, per pixel $RULE_PER_PIXEL enforced on truncated and changed inputs, sse2-bulk"
    echo
    echo '```'
    for side in 16384 64; do
      env $rule WEBP_INTERVAL=4096 "$out/sse2-bulk-$name.exe" fuzz $side $conformance $fixtures $crafted
    done
    echo '```'
    echo
  } | tee -a "$summary"
fi
