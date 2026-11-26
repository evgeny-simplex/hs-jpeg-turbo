import sys

FORMATS = {"1": "JPEG", "2": "PNG", "3": "WebP"}
BASE, PER_BYTE = 1048576, 16

rows = []
for line in open(sys.argv[1]):
    name, fmt, side, size, image, output, status, iterations, elapsed, *_ = line.rstrip("\n").split("\t")
    if status == "0":
        rows.append((FORMATS.get(fmt, "?"), name, int(side), int(size), int(image) + int(output), int(iterations), int(elapsed)))

print("### Iterations of decodes without a budget, by format")
print()
print("| Format | Decodes | Most iterations | Most per pixel beyond the base and 16 per byte | Smallest per-pixel rate without refusals | Median ns per iteration |")
print("|---|---|---|---|---|---|")
for fmt in ["JPEG", "PNG", "WebP"]:
    group = [r for r in rows if r[0] == fmt]
    if not group:
        continue
    need = max(group, key=lambda r: (r[5] - BASE - PER_BYTE * r[3]) / r[4])
    rate = max(0, (need[5] - BASE - PER_BYTE * need[3]) / need[4])
    ns = sorted(r[6] / r[5] for r in group if r[5] > 0)
    most = max(group, key=lambda r: r[5])
    print(f"| {fmt} | {len(group)} | {most[5]} ({most[1]}) | {rate:.2f} ({need[1]}, side {need[2]}) | {rate:.2f} | {ns[len(ns) // 2]:.2f} |")
print()
for rate in [16, 32, 64, 128]:
    refused = {}
    for fmt, name, side, size, pixels, iterations, _ in rows:
        if iterations > BASE + PER_BYTE * size + rate * pixels:
            refused.setdefault(fmt, []).append(f"{name}@{side}")
    print(f"- per pixel {rate}: refused " + (", ".join(f"{fmt} {len(v)} ({', '.join(v[:3])})" for fmt, v in refused.items()) or "none"))
print()
