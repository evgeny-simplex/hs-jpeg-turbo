#!/usr/bin/env bash

set -euo pipefail

out=$1
package=webp-sandbox
lib=$package/cbits/libwebp
sources=$(cat .github/scripts/wasm-sources.txt | sed "s|^|$lib/|")
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
cc="$WASI_SDK/bin/clang --target=wasm32-wasip1 --sysroot=$WASI_SDK/share/wasi-sysroot"
flags="-O2 -DWEBP_MAX_ALLOCABLE_MEMORY=67108864 -I $lib -I $package/cbits"
link="-mexec-model=reactor -Wl,--import-memory -Wl,--stack-first -Wl,-z,stack-size=1048576"
binaryen_features="--enable-simd --enable-bulk-memory --enable-bulk-memory-opt --enable-nontrapping-float-to-int --enable-sign-ext
  --enable-mutable-globals --enable-multivalue --enable-reference-types --enable-call-indirect-overlong --enable-extended-const"

translate() {
  local name=$1 extra=$2 imports=$3 dir=$out/$1 found simd
  "$WABT/bin/wasm2c" --module-name=webp -o "$dir/webp-wasm.c" "$dir/webp.wasm"
  found=$("$WABT/bin/wasm-objdump" -x -j Import "$dir/webp.wasm")
  echo "$found"
  "$WABT/bin/wasm-objdump" -x -j Export "$dir/webp.wasm" | sed -n '/^Export\[/,$p'
  grep -q 'w2c_webp_0x5Finitialize(w2c_webp\*)' "$dir/webp-wasm.h"
  grep -q 'wasm_rt_memory_t\* w2c_env_memory(struct w2c_env\*)' "$dir/webp-wasm.h"
  if [ "$(echo "$found" | grep -c ' func\[' || true)" != "$imports" ]; then
    echo "$name: the module imports other functions than expected"
    exit 1
  fi
  "$WABT/bin/wasm-objdump" -d "$dir/webp.wasm" > "$dir/webp.dis"
  simd=$(grep -cE '\b(v128|i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.' "$dir/webp.dis" || true)
  rm "$dir/webp.dis"
  echo "| $name | $extra | $(wc -c < "$dir/webp.wasm") | $(wc -c < "$dir/webp-wasm.c") | $simd |" | tee -a "$summary"
}

variant() {
  local name=$1 extra=$2 cpu=$3
  mkdir -p "$out/$name"
  $cc $flags $extra $(echo "$sources" | grep -v '/cpu\.c$') "$cpu" $package/cbits/canvas.c $package/cbits/guest.c $link -o "$out/$name/webp.wasm"
  translate "$name" "\`$extra\`" 0
}

budget_variants() {
  local text=$out/texts mode
  mkdir -p "$text" "$out/sse2-loops" "$out/sse2-calls" "$out/sse2-log"
  "$WABT/bin/wasm2wat" --disable-annotations --generate-names "$out/sse2/webp.wasm" -o "$text/sse2.wat"
  "$WABT/bin/wat2wasm" --debug-names "$text/sse2.wat" -o "$text/roundtrip.wasm"
  "$WABT/bin/wasm2wat" --disable-annotations --generate-names "$text/roundtrip.wasm" -o "$text/roundtrip.wat"
  if ! cmp "$text/sse2.wat" "$text/roundtrip.wat"; then
    diff "$text/sse2.wat" "$text/roundtrip.wat" | sed -n 1,40p
    exit 1
  fi
  echo "wasm2wat and wat2wasm reproduce the text of the sse2 module, $(wc -l < "$text/sse2.wat") lines" | tee -a "$summary"
  for mode in loops calls; do
    python3 -I .github/scripts/wasm-fuel.py $mode "$text/sse2.wat" "$text/sse2-$mode.wat" | tee -a "$summary"
    "$WABT/bin/wat2wasm" --debug-names "$text/sse2-$mode.wat" -o "$out/sse2-$mode/webp.wasm"
    translate "sse2-$mode" "budget checks by \`wasm-fuel.py $mode\`" 1
    grep -q 'u32 w2c_env_refuel(struct w2c_env\*)' "$out/sse2-$mode/webp-wasm.h"
    grep -q 'u32\* w2c_webp_fuel(w2c_webp\*' "$out/sse2-$mode/webp-wasm.h"
  done
  "$BINARYEN/bin/wasm-opt" --version
  "$BINARYEN/bin/wasm-opt" $binaryen_features --log-execution -g "$out/sse2/webp.wasm" -o "$out/sse2-log/webp.wasm"
  translate sse2-log "binaryen \`wasm-opt --log-execution\`" 1
  grep -q 'void w2c_env_log_execution(struct w2c_env\*, u32)' "$out/sse2-log/webp-wasm.h"
  echo "sse2-log: $("$WABT/bin/wasm2wat" "$out/sse2-log/webp.wasm" | grep -c 'call \$log_execution\|call 0 ' || true) calls of log_execution" | tee -a "$summary"
  rm -rf "$text"
}

rm -rf "$out"
mkdir -p "$out"
"$WASI_SDK/bin/clang" --version | sed -n 1p
"$WABT/bin/wasm2c" --version
echo "libwebp $(git -C "$lib" describe --tags --always) at $(git -C "$lib" rev-parse HEAD); $(echo "$sources" | wc -w) C files"
{
  echo "### WebP decoder modules, wasi-sdk and wasm2c"
  echo
  echo "| Variant | Flags | .wasm bytes | wasm2c .c bytes | SIMD instructions |"
  echo "|---|---|---|---|---|"
} | tee -a "$summary"
variant scalar "" "$lib/src/dsp/cpu.c"
variant simd128 "-msimd128" "$lib/src/dsp/cpu.c"
variant sse2 "-msimd128 -D__SSE__ -D__SSE2__ -I $EMSCRIPTEN_COMPAT" "$package/cbits/guest-cpu.c"
budget_variants
cp "$WABT_SRC"/wasm2c/wasm-rt.h "$WABT_SRC"/wasm2c/wasm-rt-impl.h "$WABT_SRC"/wasm2c/wasm-rt-impl.c "$WABT_SRC"/wasm2c/wasm-rt-impl-tableops.inc \
  "$WABT_SRC"/wasm2c/wasm-rt-mem-impl.c "$WABT_SRC"/wasm2c/wasm-rt-mem-impl-helper.inc "$WABT_SRC"/wasm2c/wasm-rt-exceptions.h \
  "$WABT_SRC"/wasm2c/wasm-rt-exceptions-impl.c "$out/"
mkdir -p "$out/simde"
cp -r "$WABT_SRC"/third_party/simde/simde "$out/simde/"
ls -l "$out" "$out"/*/
