import os
import sys

native_dir, sandbox_dir = sys.argv[1:]


def read(path):
    with open(path, "rb") as f:
        header = f.readline().split()
        return [int(x) for x in header], f.read()


counts = {}
for name in sorted(os.listdir(native_dir)):
    kind = name.rsplit(".", 2)[-2].upper()
    entry = counts.setdefault(kind, {"files": 0, "identical": 0, "within 2": 0, "different": 0, "both refused": 0, "native refused": 0, "sandbox refused": 0, "max": 0})
    entry["files"] += 1
    (status, *dims), native = read(os.path.join(native_dir, name))
    (status2, *dims2), sandbox = read(os.path.join(sandbox_dir, name))
    if status and status2:
        entry["both refused"] += 1
    elif status:
        entry["native refused"] += 1
    elif status2:
        entry["sandbox refused"] += 1
    elif dims != dims2 or len(native) != len(sandbox):
        entry["different"] += 1
    elif native == sandbox:
        entry["identical"] += 1
    else:
        largest = max(abs(a - b) for a, b in zip(native, sandbox))
        entry["max"] = max(entry["max"], largest)
        entry["within 2" if largest <= 2 else "different"] += 1

print("; ".join(f"{kind}: " + ", ".join(f"{v} {k}" for k, v in entry.items() if v) for kind, entry in counts.items()))
