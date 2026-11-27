#!/usr/bin/env bash

set -euo pipefail

package=JuicyPixels-sandbox
gen=$package/cbits
work=${1:-dist-newstyle/wasm}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
webp=JuicyPixels-libwebp/cbits/libwebp
spng=JuicyPixels-spng/cbits
jpeg=jpeg-turbo/cbits
cc="$WASI_SDK/bin/clang --target=wasm32-wasip1 --sysroot=$WASI_SDK/share/wasi-sysroot -O2 -msimd128"
link="-mexec-model=reactor -Wl,--import-memory -Wl,--stack-first -Wl,-z,stack-size=1048576"
webp_flags="-DNDEBUG -D__SSE__ -D__SSE2__ -I $EMSCRIPTEN_COMPAT -I $webp"
spng_flags="-DSPNG_STATIC -DSPNG_USE_MINIZ -DMINIZ_NO_STDIO -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_APIS -I $spng -I $spng/libspng/spng -I $spng/miniz"
jpeg_flags="-DBMP_SUPPORTED -DPPM_SUPPORTED -DNO_GETENV -DNO_PUTENV -I $jpeg -I $jpeg/mozjpeg"

webp_sources() {
  sed -n 's|^ *cbits/libwebp/\(src/.*\.c\)$|\1|p' JuicyPixels-libwebp/JuicyPixels-libwebp.cabal | grep -v '^src/dsp/cpu\.c$' | sed "s|^|$webp/|"
  echo $package/guest/cpu.c $package/guest/webp.c
}

spng_sources() {
  echo $spng/libspng/spng/spng.c $spng/miniz/miniz.c $spng/miniz/miniz_tdef.c $spng/miniz/miniz_tinfl.c $spng/decode.c $package/guest/png.c
}

jpeg_sources() {
  sed -n 's|^ *cbits/\(mozjpeg/[a-z0-9_-]*\.c\)$|\1|p; s|^ *cbits/\(wrapper/[a-z0-9_-]*\.c\)$|\1|p' jpeg-turbo/jpeg-turbo.cabal | sed "s|^|$jpeg/|"
  echo $package/guest/jpeg.c
}

compile() {
  local flags=$1 source object
  shift
  for source in "$@"; do
    object=$work/obj/${source%.c}.o
    mkdir -p "$(dirname "$object")"
    $cc $flags -I $package/guest -c "$source" -o "$object"
    echo "$object"
  done
}

rm -rf "$work" "$gen/image-wasm.c" "$gen/image-wasm.h" "$gen/wasm2c" "$gen/licenses"
mkdir -p "$work" "$gen/wasm2c/simde/wasm"
"$WASI_SDK/bin/clang" --version | sed -n 1p
"$WABT/bin/wasm2c" --version
{
  compile "$webp_flags" $(webp_sources)
  compile "$spng_flags" $(spng_sources)
  compile "$jpeg_flags" $(jpeg_sources)
  compile "" $package/guest/guest.c
} > "$work/objects.txt"
echo "$(wc -l < "$work/objects.txt") objects"
$cc $(cat "$work/objects.txt") $link -o "$work/image.wasm"

"$WABT/bin/wasm2wat" --disable-annotations --generate-names "$work/image.wasm" -o "$work/image.wat"
"$WABT/bin/wat2wasm" --debug-names "$work/image.wat" -o "$work/roundtrip.wasm"
"$WABT/bin/wasm2wat" --disable-annotations --generate-names "$work/roundtrip.wasm" -o "$work/roundtrip.wat"
cmp "$work/image.wat" "$work/roundtrip.wat"
python3 -I .github/scripts/wasm-fuel.py "$work/image.wat" "$work/checked.wat" | tee -a "$summary"
"$WABT/bin/wat2wasm" --debug-names "$work/checked.wat" -o "$work/checked.wasm"
"$WABT/bin/wasm-objdump" -x -j Import "$work/checked.wasm" | sed -n '/^Import\[/,$p' | tee -a "$summary"
"$WABT/bin/wasm-objdump" -x -j Import "$work/checked.wasm" | sed -n 's/^.* <- //p' | sort > "$work/imports.txt"
sort > "$work/expected-imports.txt" <<EOF
env.copy
env.fill
env.memory
env.refuel
wasi_snapshot_preview1.clock_time_get
wasi_snapshot_preview1.fd_close
wasi_snapshot_preview1.fd_prestat_dir_name
wasi_snapshot_preview1.fd_prestat_get
wasi_snapshot_preview1.fd_seek
wasi_snapshot_preview1.fd_write
wasi_snapshot_preview1.proc_exit
EOF
diff "$work/expected-imports.txt" "$work/imports.txt"
"$WABT/bin/wasm-objdump" -x -j Export "$work/checked.wasm" | sed -n '/^Export\[/,$p' | tee -a "$summary"
"$WABT/bin/wasm2c" --module-name=image -o "$gen/image-wasm.c" "$work/checked.wasm"

cp "$WABT_SRC"/wasm2c/wasm-rt.h "$WABT_SRC"/wasm2c/wasm-rt-impl.h \
  "$WABT_SRC"/wasm2c/wasm-rt-mem-impl.c "$WABT_SRC"/wasm2c/wasm-rt-mem-impl-helper.inc "$gen/wasm2c/"
cp "$WABT_SRC"/third_party/simde/simde/*.h "$gen/wasm2c/simde/"
cp "$WABT_SRC"/third_party/simde/simde/wasm/simd128.h "$gen/wasm2c/simde/wasm/"
cp "$WABT_SRC"/third_party/simde/COPYING "$gen/wasm2c/simde/COPYING"
cp "$WABT_SRC"/LICENSE "$gen/wasm2c/LICENSE"
mkdir -p "$gen/licenses/mozjpeg" "$gen/licenses/libspng" "$gen/licenses/miniz" "$gen/licenses/libwebp"
cp $jpeg/mozjpeg/LICENSE.md $jpeg/mozjpeg/README.ijg "$gen/licenses/mozjpeg/"
cp $spng/libspng/LICENSE "$gen/licenses/libspng/"
cp $spng/miniz/LICENSE "$gen/licenses/miniz/"
cp $webp/COPYING $webp/PATENTS "$gen/licenses/libwebp/"
{
  echo "| File | Bytes |"
  echo "|---|---|"
  for file in "$work/image.wasm" "$work/checked.wasm" "$gen/image-wasm.c" "$gen/image-wasm.h"; do
    echo "| $(basename "$file") | $(wc -c < "$file") |"
  done
} | tee -a "$summary"
