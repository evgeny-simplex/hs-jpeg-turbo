import sys

title, native_path, sandbox_path = sys.argv[1:]


def read(path):
    rows = {}
    for line in open(path):
        name, _, width, height, frames, _, _, size, total, slowest, status, message = line.rstrip("\n").split("\t")
        rows[name] = (f"{width}x{height}", int(frames), int(size), float(total), float(slowest), status, message)
    return rows


native, sandbox = read(native_path), read(sandbox_path)
print(f"### {title}: every frame of the animations at full size, median of 5, ms")
print()
print("| Animation | Canvas | Frames | Bytes | Native | Sandbox | Sandbox ÷ native | Slowest frame, native | Slowest frame, sandbox |")
print("|---|---|---|---|---|---|---|---|---|")
for name, (canvas, frames, size, total, slowest, status, message) in native.items():
    _, _, _, total2, slowest2, status2, message2 = sandbox[name]
    if status != "0" or status2 != "0":
        print(f"| {name} | {canvas} | {frames} | {size} | status {status} {message} | status {status2} {message2} | | | |")
    else:
        print(f"| {name} | {canvas} | {frames} | {size} | {total / 1e6:.1f} | {total2 / 1e6:.1f} | {total2 / total:.2f} | {slowest / 1e6:.1f} | {slowest2 / 1e6:.1f} |")
print()
