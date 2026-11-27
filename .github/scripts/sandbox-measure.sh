#!/usr/bin/env bash

set -euo pipefail

platform=$1
shift
out=dist-newstyle/sandbox-measure
root=$PWD
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
python=${PYTHON:-python3}
libs=${LIBS:--lpthread -lm}
measure=${MEASURE:-false}
package=JuicyPixels-sandbox
webp=JuicyPixels-libwebp/cbits/libwebp
spng=JuicyPixels-spng/cbits
jpeg=jpeg-turbo/cbits
sandbox_flags="-DSANDBOX -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 -DWASM_RT_USE_MMAP=0 -DWASM_RT_STACK_DEPTH_COUNT=1 -DWASM_RT_MAX_CALL_STACK_DEPTH=128 -DWASM_RT_GROW_FAILED_HANDLER=sandbox_grow_failed -I $package/cbits -I $package/cbits/wasm2c"
sandbox_sources="$package/cbits/host.c $package/cbits/module.c $package/cbits/clock.c $package/cbits/wasm2c/wasm-rt-mem-impl.c"
corpus=
workloads=
calibration=
largest=
concurrent=
if [ "${BUILD_ONLY:-}" != 1 ]; then
  corpus=$(ls $jpeg/mozjpeg/testimages/*.jpg $spng/libspng/tests/images/*.png "$FIXTURES"/webp/*.webp "$FIXTURES"/workloads/*)
  workloads=$(ls "$FIXTURES"/workloads/*)
  calibration=$(ls "$FIXTURES"/calibration/*)
  largest=$(ls "$FIXTURES"/largest/*)
  concurrent=$(ls $jpeg/mozjpeg/testimages/testorig.jpg "$FIXTURES"/workloads/photo-1280x720.jpg "$FIXTURES"/workloads/photo-2560x1440.jpg \
    "$FIXTURES"/largest/largest-16384x16384.jpg "$FIXTURES"/largest/lossy-8192x8192.webp "$FIXTURES"/largest/paeth-4096x4096-rgba16.png)
fi

cabal_sources() {
  sed -n "s|^ *cbits/\\($2\\)$|\\1|p" "$1" | sed "s|^|$(dirname "$1")/cbits/|"
}

jpeg_native() {
  local arch=$1
  cabal_sources jpeg-turbo/jpeg-turbo.cabal 'mozjpeg/[a-z0-9_-]*\.c'
  cabal_sources jpeg-turbo/jpeg-turbo.cabal 'wrapper/[a-z0-9_-]*\.c'
  case $arch in
    aarch64) sed -n '/if arch(aarch64)/,/if arch(arm)/p' jpeg-turbo/jpeg-turbo.cabal | sed -n "s|^ *cbits/\\(.*\\.c\\)$|$jpeg/\\1|p" ;;
    arm) echo $jpeg/mozjpeg/simd/arm/aarch32/jsimd.c ;;
  esac
}

jpeg_neon() {
  sed -n '/^library neon/,/^test-suite/p' jpeg-turbo/jpeg-turbo.cabal | sed -n "s|^ *cbits/\\(.*\\.c\\)$|$jpeg/\\1|p"
}

build() {
  local name=$1 command=$2 variant=$3 flags=${4:-} arch
  arch=$($command -dumpmachine | cut -d- -f1)
  case $arch in
    arm64) arch=aarch64 ;;
    arm*) arch=arm ;;
  esac
  if [ "$variant" = native ]; then
    local jpeg_sources webp_sources neon_sources
    jpeg_sources=$(jpeg_native $arch | sed "s|^|$root/|")
    neon_sources=$(jpeg_neon | sed "s|^|$root/|")
    webp_sources=$(cabal_sources JuicyPixels-libwebp/JuicyPixels-libwebp.cabal 'libwebp/src/.*\.c' | sed "s|^|$root/|")
    mkdir -p "$out/obj-jpeg" "$out/obj-png" "$out/obj-webp"
    (cd "$out/obj-jpeg" && $command -DBMP_SUPPORTED -DPPM_SUPPORTED $([ $arch = x86_64 ] || echo -DNEON_INTRINSICS) -iquote "$root/$package/guest" \
      -I "$root/$jpeg" -I "$root/$jpeg/mozjpeg" -c $jpeg_sources "$root/$package/guest/jpeg.c") &
    if [ $arch = arm ]; then
      mkdir -p "$out/obj-neon"
      (cd "$out/obj-neon" && $command -mfpu=neon -DNEON_INTRINSICS -I "$root/$jpeg" -I "$root/$jpeg/mozjpeg" -c $neon_sources) &
    fi
    (cd "$out/obj-png" && $command -DSPNG_STATIC -DSPNG_USE_MINIZ -DMINIZ_NO_STDIO -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_APIS -iquote "$root/$package/guest" \
      -I "$root/$spng" -I "$root/$spng/libspng/spng" -I "$root/$spng/miniz" -c "$root/$spng/libspng/spng/spng.c" "$root/$spng/miniz/miniz.c" \
      "$root/$spng/miniz/miniz_tdef.c" "$root/$spng/miniz/miniz_tinfl.c" "$root/$spng/decode.c" "$root/$package/guest/png.c") &
    (cd "$out/obj-webp" && $command -DWEBP_USE_THREAD -DNDEBUG -iquote "$root/$package/guest" -I "$root/$webp" -c $webp_sources "$root/$package/guest/webp.c") &
    wait
    $command -iquote $package/guest -I $package/cbits "$out"/obj-*/*.o $package/cbits/clock.c .github/scripts/sandbox-bench.c $libs -o "$out/$name.exe"
    rm -rf "$out"/obj-*
  else
    $command $sandbox_flags $flags $sandbox_sources .github/scripts/sandbox-bench.c $libs -o "$out/$name.exe"
  fi
}

expect() {
  "$@" || echo "$platform: $*" >> "$out/failures.txt"
}

check() {
  local variant=$1 name=$2 side
  for side in 16384 64; do
    mkdir -p "$out/check-$variant-$name-$side"
    "$out/$variant-$name.exe" check "$out/check-$variant-$name-$side" $side $corpus $calibration
  done
  if [ $variant = sandbox ] || [ "$measure" = true ]; then
    mkdir -p "$out/check-$variant-$name-4320"
    "$out/$variant-$name.exe" check "$out/check-$variant-$name-4320" 4320 $largest
  fi
}

stops() {
  local sandbox=$out/sandbox-$1.exe file interval
  expect env SANDBOX_BUDGET_BASE=100000000 "$sandbox" spin 5
  for interval in 4096 65536; do
    expect env SANDBOX_DEADLINE_MS=20 SANDBOX_INTERVAL=$interval "$sandbox" spin 20
  done
  for file in "$FIXTURES"/workloads/tall-1024x4096.jpg "$FIXTURES"/workloads/tall-1024x4096-rgba.png "$FIXTURES"/workloads/tall-lossless.webp; do
    expect env SANDBOX_DEADLINE_MS=5 "$sandbox" stop 20 "$file"
  done
  expect env SANDBOX_BUDGET_BASE=1000000 "$sandbox" tree 24 "budget exceeded"
  expect env SANDBOX_DEADLINE_MS=10000 "$sandbox" tree 200 "sandbox trap 10"
  expect "$sandbox" limit
}

if [ "${PREBUILT:-}" = 1 ]; then
  chmod +x "$out"/*.exe
  rm -rf "$out"/check-* "$out/failures.txt"
else
  rm -rf "$out"
  mkdir -p "$out"
fi
echo "$platform"
for config in "$@"; do
  name=${config%%|*}
  command=${config#*|}
  if [ "${PREBUILT:-}" != 1 ]; then
    $command --version | head -1
    build "native-$name" "$command" native
    build "sandbox-$name" "$command" sandbox
    if [ "$measure" = true ]; then
      build "reserved-$name" "$command" sandbox "-UWASM_RT_USE_MMAP -DWASM_RT_USE_MMAP=1"
    fi
    {
      echo "### $platform, $name \`$command\`: sizes"
      echo '```'
      ${SIZE:-size} "$out/native-$name.exe" "$out/sandbox-$name.exe" || true
      echo '```'
    } | tee -a "$summary"
  fi
  if [ "${BUILD_ONLY:-}" = 1 ]; then
    continue
  fi

  export SANDBOX_STACK_KB=256
  check native "$name"
  check sandbox "$name"
  {
    echo "### $platform, $name: sandbox outputs compared with the reference and the native outputs"
    echo
    if [ "${RUNNER_OS:-}" != Windows ]; then
      echo "- decodes and stops on a thread with a stack of $SANDBOX_STACK_KB KiB"
    fi
    if [ -n "${REFERENCE:-}" ]; then
      $python -I .github/scripts/sandbox-compare.py manifest "$out" "$name" > "$REFERENCE"
      echo "- reference outputs written: $(wc -l < "$REFERENCE")"
    else
      expect $python -I .github/scripts/sandbox-compare.py reference "$FIXTURES/reference.tsv" "$out" "$name"
    fi
    $python -I .github/scripts/sandbox-compare.py native "$out" "$name"
    echo
    echo "### $platform, $name: loops and decodes stopped by the budget, the deadline and the call depth; memory limits above PTRDIFF_MAX refused"
    echo
    echo '```'
    stops "$name"
    echo '```'
    echo
  } | tee -a "$summary"
  for side in 16384 64 4320; do
    rm -rf "$out/check-native-$name-$side" "$out/check-sandbox-$name-$side"
  done
  unset SANDBOX_STACK_KB
  if [ "$measure" != true ]; then
    continue
  fi

  SANDBOX_DEADLINE_MS=600000 "$out/native-$name.exe" time 9 16384 $workloads > "$out/time-native-$name.tsv"
  rm -f "$out/time-sandbox-$name.tsv" "$out/time-reserved-$name.tsv"
  for file in $workloads; do
    for variant in sandbox reserved; do
      SANDBOX_DEADLINE_MS=600000 "$out/$variant-$name.exe" time 9 16384 "$file" >> "$out/time-$variant-$name.tsv"
    done
  done
  $python -I .github/scripts/sandbox-report.py "$platform, $name \`$command\`" "$out/time-native-$name.tsv" "$out/time-sandbox-$name.tsv" | tee -a "$summary"
  $python -I .github/scripts/sandbox-report.py "$platform, $name, memory grown as needed against memory reserved at the limit" "$out/time-reserved-$name.tsv" \
    "$out/time-sandbox-$name.tsv" reserved grown | tee -a "$summary"

  {
    echo "### $platform, $name: the largest picked images at the display size (4320), one decode each"
    echo
    echo '```'
    for variant in native sandbox reserved; do
      for file in $largest; do
        echo "$variant 256 MiB $(SANDBOX_MEMORY_MB=256 SANDBOX_DEADLINE_MS=0 "$out/$variant-$name.exe" time 1 4320 "$file" || echo "$(basename "$file") failed")"
      done
      for memory in 512 1024; do
        for file in "$FIXTURES"/largest/*progressive*; do
          echo "$variant $memory MiB $(SANDBOX_MEMORY_MB=$memory SANDBOX_DEADLINE_MS=0 "$out/$variant-$name.exe" time 1 4320 "$file" || echo "$(basename "$file") failed")"
        done
      done
    done
    echo '```'
    echo
    echo "### $platform, $name: the largest picked images and the deadline of 10 s"
    echo
    echo '```'
    for file in $largest; do
      SANDBOX_DEADLINE_MS=10000 "$out/sandbox-$name.exe" stop 1 "$file" || true
    done
    for file in "$FIXTURES"/largest/*progressive*; do
      SANDBOX_MEMORY_MB=1024 SANDBOX_DEADLINE_MS=10000 "$out/sandbox-$name.exe" stop 1 "$file" || true
    done
    echo '```'
    echo
  } | tee -a "$summary"

  if [ "${RUNNER_OS:-}" != Windows ]; then
    {
      echo "### $platform, $name: concurrent decodes, each session open until all have decoded"
      echo
      echo '```'
      for variant in sandbox reserved; do
        for file in $concurrent; do
          for memory in 256 512; do
            for threads in 4 8 16 32; do
              echo "$variant $(SANDBOX_MEMORY_MB=$memory "$out/$variant-$name.exe" concurrent $threads "$file")"
            done
          done
        done
      done
      echo '```'
      echo
    } | tee -a "$summary"
  fi
done

if [ "${COUNT:-}" = 1 ]; then
  name=${1%%|*}
  for side in 16384 4320 64; do
    "$out/sandbox-$name.exe" count $side $corpus
    "$out/sandbox-$name.exe" count-changed $side $(ls $jpeg/mozjpeg/testimages/*.jpg $spng/libspng/tests/images/*.png "$FIXTURES"/webp/*.webp | head -400)
    SANDBOX_MEMORY_MB=1024 "$out/sandbox-$name.exe" count $side $calibration
  done > "$out/count.tsv"
  rates=$(sed -n 's/^  \(JPEG\|PNG\|WebP\) -> \([0-9][0-9]*\)$/\1=\2/p' $package/src/Codec/Picture/Sandbox.hsc)
  $python -I .github/scripts/sandbox-budget.py "$out/count.tsv" $rates | tee -a "$summary"
fi

if [ -s "$out/failures.txt" ]; then
  echo "Failed checks:"
  cat "$out/failures.txt"
  exit 1
fi
