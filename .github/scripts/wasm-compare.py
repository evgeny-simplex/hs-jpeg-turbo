import hashlib
import os
import sys


def samples(path):
    data = open(path, "rb").read()
    if data.startswith(b"P7"):
        end = data.index(b"ENDHDR\n") + 7
        return 4, data[:end], data[end:]
    if data.startswith(b"P6"):
        end = len(b"\n".join(data.split(b"\n", 3)[:3])) + 1
        return 3, data[:end], data[end:]
    return 0, data, b""


def largest_difference(depth, a, b):
    largest = 0
    for i in range(0, len(a), depth):
        if depth == 4:
            x, y = a[i + 3], b[i + 3]
            largest = max([largest, abs(x - y)] + [abs(a[i + k] * x - b[i + k] * y) / 255 for k in range(3)])
        else:
            largest = max([largest] + [abs(a[i + k] - b[i + k]) for k in range(3)])
    return largest


def compare(reference_dir, build_dir):
    names = sorted(os.listdir(reference_dir))
    if names != sorted(os.listdir(build_dir)):
        missing = sorted(set(names) ^ set(os.listdir(build_dir)))
        print(f"different outputs: {' '.join(missing[:5])}")
        return 1
    differing, largest = [], 0
    for name in names:
        depth, header, a = samples(os.path.join(reference_dir, name))
        _, other_header, b = samples(os.path.join(build_dir, name))
        if header != other_header:
            print(f"{name}: different headers")
            return 1
        if a == b:
            continue
        differing.append(name)
        largest = max(largest, largest_difference(depth, a, b) if depth else 255)
    if not differing:
        print(f"identical, {len(names)} files")
    else:
        print(f"{len(differing)} of {len(names)} files differ, at most {largest:.2f} in a sample: {' '.join(differing[:3])}")
    return 0


def check_md5(expected, directory):
    failed = 0
    for line in open(expected):
        digest, name = line.split()
        if hashlib.md5(open(os.path.join(directory, name), "rb").read()).hexdigest() != digest:
            print(f"{directory}/{name}: md5 differs")
            failed += 1
    return 1 if failed else 0


if sys.argv[1] == "md5":
    sys.exit(check_md5(sys.argv[2], sys.argv[3]))
sys.exit(compare(sys.argv[1], sys.argv[2]))
