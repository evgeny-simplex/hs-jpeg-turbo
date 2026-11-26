import itertools
import sys

directory = sys.argv[1]
variants = sys.argv[2:]
max_pixels = 2 * 16384 * 16384


def read(path):
    rows = []
    for line in open(path):
        name, side, size, frame, output, status, iterations, refuels, elapsed = line.rstrip("\n").split("\t")
        rows.append(
            {
                "name": name,
                "side": int(side),
                "size": int(size),
                "pixels": int(frame) + int(output),
                "status": int(status),
                "iterations": int(iterations),
                "elapsed": int(elapsed),
            }
        )
    return rows


def kind(row):
    if "#" in row["name"]:
        return "changed"
    if row["name"].startswith(("huffman-", "chunks-")):
        return "crafted"
    if row["name"].startswith(("photo-", "logo-", "tall-")):
        return "fixtures"
    return "conformance"


def allowed(rule, row):
    base, per_byte, per_pixel = rule
    return base + per_byte * row["size"] + per_pixel * row["pixels"]


print(f"### Budget checks: iterations counted per decode, {', '.join(variants)}")
print()
print("Iterations per pixel: counted iterations of a decode, probe included, divided by the pixels of the frame plus those of the output.")
print()
print("| Variant | Set | Side | Decodes | Most iterations | Most per pixel | Most per byte | Median ns per iteration |")
print("|---|---|---|---|---|---|---|---|")
tables = {}
for variant in variants:
    rows = [row for row in read(f"{directory}/count-{variant}.tsv") if row["status"] == 0 and row["iterations"] > 0]
    tables[variant] = rows
    for (set_, side), group in itertools.groupby(sorted(rows, key=lambda r: (kind(r), r["side"])), key=lambda r: (kind(r), r["side"])):
        group = list(group)
        per_pixel = max(group, key=lambda r: r["iterations"] / r["pixels"])
        per_byte = max(group, key=lambda r: r["iterations"] / r["size"])
        timing = sorted(r["elapsed"] / r["iterations"] for r in group if r["iterations"] >= 1000000)
        median = f"{timing[len(timing) // 2]:.2f}" if timing else ""
        print(
            f"| {variant} | {set_} | {side} | {len(group)} | {max(r['iterations'] for r in group)} | "
            f"{per_pixel['iterations'] / per_pixel['pixels']:.2f} ({per_pixel['name']}) | "
            f"{per_byte['iterations'] / per_byte['size']:.2f} ({per_byte['name']}) | {median} |"
        )
print()

rules = itertools.product([1 << 20, 1 << 22, 1 << 24], [0, 16, 64, 256], [8, 16, 32, 64, 128])
sets = ["conformance", "fixtures", "crafted", "changed"]
rows = tables[variants[0]]
print(f"### Budget rules on {variants[0]}: decodes refused, of those that complete without a budget")
print()
print("Budget = base + per byte x input bytes + per pixel x (frame pixels + output pixels). Largest budget: a 16384x16384 frame decoded at full size, 1 MiB of input.")
print()
print("| Base | Per byte | Per pixel | " + " | ".join(f"{s} 16384 | {s} 64" for s in sets) + " | Largest budget |")
print("|---|---|---|" + "---|" * (2 * len(sets)) + "---|")
for rule in rules:
    cells = []
    for set_ in sets:
        for side in (16384, 64):
            group = [r for r in rows if kind(r) == set_ and r["side"] == side]
            refused = sum(1 for r in group if r["iterations"] > allowed(rule, r))
            cells.append(f"{refused}/{len(group)}")
    largest = rule[0] + rule[1] * (1 << 20) + rule[2] * max_pixels
    print(f"| {rule[0]} | {rule[1]} | {rule[2]} | " + " | ".join(cells) + f" | {largest:.3g} |")
print()
