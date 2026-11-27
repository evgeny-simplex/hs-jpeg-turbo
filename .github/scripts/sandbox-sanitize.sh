#!/usr/bin/env bash

set -euo pipefail

out=dist-newstyle/sandbox-sanitize
package=JuicyPixels-sandbox
library=$(sed -n '/^library$/,/^$/p' $package/$package.cabal)
options=$(echo "$library" | sed -n 's/^  cc-options: //p')
sources=$(echo "$library" | grep -oE 'cbits/[^ ]+\.c' | sed "s|^|$package/|")
inputs=$(ls jpeg-turbo/cbits/mozjpeg/testimages/*.jpg JuicyPixels-spng/cbits/libspng/tests/images/*.png "$WEBP_TEST_DATA"/*.webp)

rm -rf "$out"
mkdir -p "$out"
"$CC" --version | head -1
"$CC" -g -fsanitize=address,undefined -fno-sanitize-recover=undefined $options -DSANDBOX -I $package/cbits -I $package/cbits/wasm2c $sources \
  .github/scripts/sandbox-bench.c -lpthread -lm -o "$out/sanitized.exe"
for side in 16384 64; do
  "$out/sanitized.exe" count $side $inputs
  "$out/sanitized.exe" count-changed $side $inputs
done > "$out/count.tsv"

python3 -I - "$out/count.tsv" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import collections
import sys

FORMATS = {"1": "JPEG", "2": "PNG", "3": "WebP"}
STATUSES = {"0": "decoded", "-7": "refused by the decoder", "-8": "refused at the memory limit", "-3": "out of memory", "-1": "trapped", "-2": "invalid output"}
counts = collections.Counter()
unexpected = []
for line in open(sys.argv[1]):
    name, fmt, side, _, _, _, status, *_ = line.rstrip("\n").split("\t")
    counts[(FORMATS.get(fmt, "not detected"), STATUSES.get(status, f"status {status}"))] += 1
    if status not in ("0", "-7", "-8"):
        unexpected.append(f"{name} at {side}: status {status}")
print("### Sandbox with address and undefined behaviour sanitizers, truncated and changed images")
print()
print("| Format | Outcome | Decodes |")
print("|---|---|---|")
for (fmt, outcome), n in sorted(counts.items()):
    print(f"| {fmt} | {outcome} | {n} |")
print()
print(f"{sum(counts.values())} decodes; {len(unexpected)} with another outcome")
for entry in unexpected[:20]:
    print(f"- {entry}")
sys.exit(1 if unexpected else 0)
PY
