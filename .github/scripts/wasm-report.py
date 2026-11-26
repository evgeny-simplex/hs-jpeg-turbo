import os
import sys

platform, directory, *builds = sys.argv[1:]


def read(build):
    rows = {}
    for line in open(os.path.join(directory, f"time-{build}.tsv")):
        name, width, height, channels, size, minimum, median, memory = line.rstrip("\n").split("\t")[:8]
        rows[name] = (int(width), int(height), int(channels), int(size), float(minimum), float(median), int(memory))
    return rows


times = {build: read(build) for build in builds}
reference = times[builds[0]]
wasm = [build for build in builds if build.startswith("wasm")]

print(f"### {platform}: decode time, median ms, and the ratio to `{builds[0]}`")
print()
print("One decode at full size per call, the sandbox instantiated and freed in each call. Conformance: one pass over the 96 files.")
print()
print("| Image | Pixels | Bytes | " + " | ".join(builds) + " | Linear memory MiB |")
print("|---|---|---|" + "---|" * len(builds) + "---|")
for name, (width, height, channels, size, _, median, _) in reference.items():
    cells = []
    for build in builds:
        value = times[build][name][5]
        cells.append(f"{value / 1e6:.2f}" if build == builds[0] else f"{value / 1e6:.2f} ({value / median:.2f}x)")
    memory = times[wasm[0]][name][6] / 1048576 if wasm else 0
    pixels = f"{width}x{height}x{channels}" if width else ""
    print(f"| {name} | {pixels} | {size} | " + " | ".join(cells) + f" | {memory:.1f} |")
print()
