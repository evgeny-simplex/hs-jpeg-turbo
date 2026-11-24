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

variant() {
  local name=$1 extra=$2 cpu=$3 dir=$out/$1 imports simd
  mkdir -p "$dir"
  $cc $flags $extra $(echo "$sources" | grep -v '/cpu\.c$') "$cpu" $package/cbits/canvas.c $package/cbits/guest.c $link -o "$dir/webp.wasm"
  "$WABT/bin/wasm2c" --module-name=webp -o "$dir/webp-wasm.c" "$dir/webp.wasm"
  imports=$("$WABT/bin/wasm-objdump" -x -j Import "$dir/webp.wasm")
  echo "$imports"
  "$WABT/bin/wasm-objdump" -x -j Export "$dir/webp.wasm"
  grep -q 'w2c_webp_0x5Finitialize(w2c_webp\*)' "$dir/webp-wasm.h"
  grep -q 'wasm_rt_memory_t\* w2c_env_memory(struct w2c_env\*)' "$dir/webp-wasm.h"
  case $imports in
    *' func['*)
      echo "$name: the module imports functions"
      exit 1
      ;;
  esac
  "$WABT/bin/wasm-objdump" -d "$dir/webp.wasm" > "$dir/webp.dis"
  simd=$(grep -cE '\b(v128|i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.' "$dir/webp.dis" || true)
  rm "$dir/webp.dis"
  echo "| $name | \`$extra\` | $(wc -c < "$dir/webp.wasm") | $(wc -c < "$dir/webp-wasm.c") | $simd |" | tee -a "$summary"
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
cp "$WABT_SRC"/wasm2c/wasm-rt.h "$WABT_SRC"/wasm2c/wasm-rt-impl.h "$WABT_SRC"/wasm2c/wasm-rt-impl.c "$WABT_SRC"/wasm2c/wasm-rt-impl-tableops.inc \
  "$WABT_SRC"/wasm2c/wasm-rt-mem-impl.c "$WABT_SRC"/wasm2c/wasm-rt-mem-impl-helper.inc "$WABT_SRC"/wasm2c/wasm-rt-exceptions.h \
  "$WABT_SRC"/wasm2c/wasm-rt-exceptions-impl.c "$out/"
mkdir -p "$out/simde"
cp -r "$WABT_SRC"/third_party/simde/simde "$out/simde/"
ls -l "$out" "$out"/*/
