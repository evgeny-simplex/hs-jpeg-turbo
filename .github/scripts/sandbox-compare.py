import hashlib
import os
import sys

SIDES = {"16384": "full size", "64": "sides of at most 64", "4320": "the largest picked images, sides of at most 4320"}


def directory(out, variant, name, side):
    return os.path.join(out, f"check-{variant}-{name}-{side}")


def read(path):
    with open(path, "rb") as f:
        header = f.readline().split()
        return [int(x) for x in header], f.read()


def outputs(out, name):
    for side in SIDES:
        sandbox = directory(out, "sandbox", name, side)
        if os.path.isdir(sandbox):
            for file in sorted(os.listdir(sandbox)):
                with open(os.path.join(sandbox, file), "rb") as f:
                    data = f.read()
                yield (side, file), (data.split(b"\n", 1)[0].decode(), hashlib.sha256(data).hexdigest())


def manifest(out, name):
    for (side, file), (header, digest) in outputs(out, name):
        print(f"{side}\t{file}\t{header}\t{digest}")
    return 0


def reference(path, out, name):
    expected = {}
    for line in open(path):
        side, file, header, digest = line.rstrip("\n").split("\t")
        expected[(side, file)] = (header, digest)
    actual = dict(outputs(out, name))
    missing = sorted(key for key in expected if key not in actual)
    different = sorted(key for key in expected if key in actual and actual[key] != expected[key])
    extra = sum(1 for key in actual if key not in expected)
    if not expected:
        print(f"- reference outputs: none in {path}")
        return 1
    print(f"- reference outputs: {len(expected) - len(missing) - len(different)} of {len(expected)} identical, {len(different)} different, {len(missing)} missing; {extra} outputs without a reference")
    for side, file in different:
        print(f"  - {file}, {SIDES[side]}: status and size {actual[(side, file)][0]}, reference {expected[(side, file)][0]}")
    for side, file in missing:
        print(f"  - {file}, {SIDES[side]}: missing")
    return 1 if missing or different else 0


def native(out, name):
    for side, title in SIDES.items():
        native_dir, sandbox_dir = directory(out, "native", name, side), directory(out, "sandbox", name, side)
        if not (os.path.isdir(native_dir) and os.path.isdir(sandbox_dir)):
            continue
        counts, notes = {}, []
        for file in sorted(os.listdir(native_dir)):
            kind = file.rsplit(".", 2)[-2].upper()
            entry = counts.setdefault(kind, {"files": 0, "identical": 0, "within 2": 0, "different": 0, "both refused": 0, "native refused": 0, "sandbox refused": 0, "max": 0})
            entry["files"] += 1
            (status, *dims), native_samples = read(os.path.join(native_dir, file))
            (status2, *dims2), sandbox_samples = read(os.path.join(sandbox_dir, file))
            if status and status2:
                entry["both refused"] += 1
            elif status:
                entry["native refused"] += 1
                notes.append(f"{file}: native status {status}")
            elif status2:
                entry["sandbox refused"] += 1
                notes.append(f"{file}: sandbox status {status2}")
            elif dims != dims2 or len(native_samples) != len(sandbox_samples):
                entry["different"] += 1
                notes.append(f"{file}: native {dims}, sandbox {dims2}")
            elif native_samples != sandbox_samples:
                count = largest = 0
                for a, b in zip(native_samples, sandbox_samples):
                    if a != b:
                        count += 1
                        largest = max(largest, abs(a - b))
                entry["max"] = max(entry["max"], largest)
                if largest <= 2:
                    entry["within 2"] += 1
                else:
                    entry["different"] += 1
                    uniform = native_samples.count(native_samples[:1]) == len(native_samples)
                    notes.append(f"{file}: {count} of {len(native_samples)} samples differ, by up to {largest}" + (f"; every native sample is {native_samples[0]}" if uniform else ""))
            else:
                entry["identical"] += 1
        print(f"- {title}: " + "; ".join(f"{kind}: " + ", ".join(f"{v} {k}" for k, v in entry.items() if v) for kind, entry in counts.items()))
        for note in notes:
            print(f"  - {note}")
    return 0


mode, *arguments = sys.argv[1:]
sys.exit({"manifest": manifest, "reference": reference, "native": native}[mode](*arguments))
