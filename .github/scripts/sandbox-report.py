import math
import sys

title, native_path, sandbox_path = sys.argv[1:]


def read(path):
    rows = {}
    for line in open(path):
        name, w, h, ow, oh, channels, size, minimum, median, memory, iterations = line.rstrip("\n").split("\t")
        rows[name] = (int(w), int(h), int(size), float(median), int(memory), int(iterations))
    return rows


native, sandbox = read(native_path), read(sandbox_path)
ratios = {}
print(f"### {title}: decode time at full size, median of 9, ms")
print()
print("| Image | Pixels | Bytes | Native | Sandbox | Sandbox ÷ native | Linear memory MiB | Iterations |")
print("|---|---|---|---|---|---|---|---|")
for name, (w, h, size, median, _, _) in native.items():
    _, _, _, sandboxed, memory, iterations = sandbox[name]
    ratio = sandboxed / median
    ratios.setdefault(name.rsplit(".", 1)[-1].upper(), []).append(ratio)
    print(f"| {name} | {w}x{h} | {size} | {median / 1e6:.2f} | {sandboxed / 1e6:.2f} | {ratio:.2f} | {memory / 1048576:.1f} | {iterations} |")
print()
everything = [r for rs in ratios.values() for r in rs]
means = [f"{kind} {math.exp(sum(map(math.log, rs)) / len(rs)):.2f}" for kind, rs in ratios.items()]
print(f"Geometric mean of sandbox ÷ native: {', '.join(means)}; all {math.exp(sum(map(math.log, everything)) / len(everything)):.2f}")
print()
