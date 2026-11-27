#!/usr/bin/env bash

set -euo pipefail

builddir=dist-newstyle/coverage
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

report() {
  {
    echo "### $1"
    echo '```'
    "${@:2}"
    echo '```'
  } | tee -a "$summary"
}

encode_coverage() {
  gcov -b -n "$(find "$builddir" -name encode.o.gcda)" | grep -A4 "^File 'cbits/encode.c'"
}

libwebp_coverage() {
  for object in vp8l_dec io_dec alpha_dec hs_webp; do
    gcov -f -n "$(find "$builddir" -name "$object.o.gcda")"
  done | grep -A1 -E "^Function '(AllocateAndInitRescaler|EmitRescaledRowsRGBA|InitRGBRescaler|EmitRescaledRGB|EmitRescaledAlphaRGB|ShiftWindow8b|ShiftWindow32b|VP8LShiftWindowBuffer|WebPShiftAlphaWindow|allocate|release|HsWebPDemux|HsWebPDecode)'"
}

decode_coverage() {
  gcov -b -n "$(find "$builddir" -name decode.o.gcda)" | grep -A4 "^File 'cbits/decode.c'"
}

host_coverage() {
  gcov -b -n "$(find "$builddir" -name host.o.gcda)" | grep -A4 "^File 'cbits/host.c'"
}

rm -f jpeg-turbo/*.tix JuicyPixels-jpeg-turbo/*.tix JuicyPixels-spng/*.tix JuicyPixels-libwebp/*.tix JuicyPixels-sandbox/*.tix
cabal test all --builddir="$builddir" --ghc-options=-fhpc --ghc-options=-optc--coverage --ghc-options=-optl--coverage
hpc sum --union --output="$builddir/jpeg-turbo.tix" --include=TurboJPEG2 --include=TurboJPEG3 --include=MozJPEG jpeg-turbo/jpeg-turbo-test.tix JuicyPixels-jpeg-turbo/JuicyPixels-jpeg-turbo-test.tix
report jpeg-turbo hpc report "$builddir/jpeg-turbo.tix" --hpcdir=jpeg-turbo/.hpc
report JuicyPixels-jpeg-turbo hpc report JuicyPixels-jpeg-turbo/JuicyPixels-jpeg-turbo-test.tix --hpcdir=JuicyPixels-jpeg-turbo/.hpc --include=Codec.Picture.JPEGTurbo
report JuicyPixels-spng hpc report JuicyPixels-spng/JuicyPixels-spng-test.tix --hpcdir=JuicyPixels-spng/.hpc --include=Codec.Picture.Spng
report JuicyPixels-libwebp hpc report JuicyPixels-libwebp/JuicyPixels-libwebp-test.tix --hpcdir=JuicyPixels-libwebp/.hpc --include=Codec.Picture.Webp
report JuicyPixels-sandbox hpc report JuicyPixels-sandbox/JuicyPixels-sandbox-test.tix --hpcdir=JuicyPixels-sandbox/.hpc --include=Codec.Picture.Sandbox
report jpeg-turbo/cbits/encode.c encode_coverage
report "libwebp scaling, sliding windows and memory count, JuicyPixels-libwebp tests" libwebp_coverage
report JuicyPixels-spng/cbits/decode.c decode_coverage
report JuicyPixels-sandbox/cbits/host.c host_coverage
