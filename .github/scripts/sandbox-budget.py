import sys

FORMATS = {"1": "JPEG", "2": "PNG", "3": "WebP"}
BASE, PER_BYTE = 1048576, 16
RATES = [16, 32, 64, 128, 256, 512, 1024]


def kind(name):
    if "#" in name:
        return "changed"
    if name.startswith("worst-"):
        return "worst case"
    if name.startswith("crafted-"):
        return "crafted"
    return "corpus"


rows = []
for line in open(sys.argv[1]):
    name, fmt, side, size, image, output, status, iterations, elapsed, *_ = line.rstrip("\n").split("\t")
    if status == "0":
        pixels = int(image) + int(output)
        need = (int(iterations) - BASE - PER_BYTE * int(size)) / pixels
        rows.append((FORMATS.get(fmt, "?"), kind(name), name, int(side), int(size), pixels, int(iterations), int(elapsed), need))

print("### Iterations of decodes without a budget, by format")
print()
print(f"Needed rate: (iterations − {BASE} − {PER_BYTE} × bytes) ÷ (image pixels + output pixels).")
print()
print("| Format | Set | Decodes | Most iterations | Largest needed rate per pixel | Median ns per iteration |")
print("|---|---|---|---|---|---|")
for fmt in ["JPEG", "PNG", "WebP"]:
    for group_kind in ["corpus", "changed", "worst case", "crafted"]:
        group = [r for r in rows if r[0] == fmt and r[1] == group_kind]
        if not group:
            continue
        most = max(group, key=lambda r: r[6])
        need = max(group, key=lambda r: r[8])
        ns = sorted(r[7] / r[6] for r in group if r[6] > 0)
        print(f"| {fmt} | {group_kind} | {len(group)} | {most[6]} ({most[2]}, side {most[3]}) | {max(0, need[8]):.2f} ({need[2]}, side {need[3]}) | {ns[len(ns) // 2]:.2f} |")
print()
print("Decodes refused at each per-pixel rate, base and per-byte rate as above:")
print()
print("| Rate | " + " | ".join(f"{fmt}, {k}" for fmt in ["JPEG", "PNG", "WebP"] for k in ["corpus", "changed", "worst case", "crafted"]) + " |")
print("|---" * 13 + "|")
for rate in RATES:
    cells = []
    for fmt in ["JPEG", "PNG", "WebP"]:
        for group_kind in ["corpus", "changed", "worst case", "crafted"]:
            refused = [r for r in rows if r[0] == fmt and r[1] == group_kind and r[8] > rate]
            cells.append(str(len(refused)))
    print(f"| {rate} | " + " | ".join(cells) + " |")
print()
print("Worst cases and crafted files, needed rate per pixel at each side:")
print()
print("| File | Side | Bytes | Pixels | Iterations | Needed rate |")
print("|---|---|---|---|---|---|")
for r in sorted((r for r in rows if r[1] in ("worst case", "crafted")), key=lambda r: (r[0], r[2], r[3])):
    print(f"| {r[2]} | {r[3]} | {r[4]} | {r[5]} | {r[6]} | {r[8]:.2f} |")
print()
