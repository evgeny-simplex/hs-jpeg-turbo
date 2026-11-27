import sys

FORMATS = {"1": "JPEG", "2": "PNG", "3": "WebP"}
BASE, PER_BYTE = 1048576, 16
RATES = [16, 32, 64, 128, 256, 512, 1024]
PACKAGE = dict((fmt, int(rate)) for fmt, rate in (arg.split("=") for arg in sys.argv[2:]))


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
        work = (int(iterations) - BASE) / pixels
        rows.append((FORMATS.get(fmt, "?"), kind(name), name, int(side), int(size), pixels, int(iterations), int(elapsed), need, work))

print("### Iterations of decodes without a budget, by format")
print()
print(f"Needed rate: (iterations − {BASE} − {PER_BYTE} × bytes) ÷ (image pixels + output pixels). Rate without the per-byte term: (iterations − {BASE}) ÷ (image pixels + output pixels).")
print()
print("| Format | Set | Decodes | Most iterations | Largest needed rate per pixel | Largest rate without the per-byte term | Median ns per iteration |")
print("|---|---|---|---|---|---|---|")
for fmt in ["JPEG", "PNG", "WebP"]:
    for group_kind in ["corpus", "changed", "worst case", "crafted"]:
        group = [r for r in rows if r[0] == fmt and r[1] == group_kind]
        if not group:
            continue
        most = max(group, key=lambda r: r[6])
        need = max(group, key=lambda r: r[8])
        work = max(group, key=lambda r: r[9])
        ns = sorted(r[7] / r[6] for r in group if r[6] > 0)
        print(
            f"| {fmt} | {group_kind} | {len(group)} | {most[6]} ({most[2]}, side {most[3]}) | {max(0, need[8]):.2f} ({need[2]}, side {need[3]}) "
            f"| {max(0, work[9]):.2f} ({work[2]}, side {work[3]}) | {ns[len(ns) // 2]:.2f} |"
        )
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
if PACKAGE:
    print("Smallest margin at the rates of the package, the rate ÷ the needed rate:")
    print()
    print("| Format | Rate | Set | Smallest margin | Decodes refused |")
    print("|---|---|---|---|---|")
    for fmt, rate in PACKAGE.items():
        for group_kind in ["corpus", "changed", "worst case", "crafted"]:
            group = [r for r in rows if r[0] == fmt and r[1] == group_kind and r[8] > 0]
            if group:
                least = min(group, key=lambda r: rate / r[8])
                refused = sum(1 for r in group if r[8] > rate)
                print(f"| {fmt} | {rate} | {group_kind} | {rate / least[8]:.2f} ({least[2]}, side {least[3]}) | {refused} |")
    print()
print("Worst cases and crafted files, needed rate per pixel at each side:")
print()
print("| File | Side | Bytes | Pixels | Iterations | Needed rate | Rate without the per-byte term |")
print("|---|---|---|---|---|---|---|")
for r in sorted((r for r in rows if r[1] in ("worst case", "crafted")), key=lambda r: (r[0], r[2], r[3])):
    print(f"| {r[2]} | {r[3]} | {r[4]} | {r[5]} | {r[6]} | {r[8]:.2f} | {r[9]:.2f} |")
print()
