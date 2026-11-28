import os
import sys

suite, out, *decoders = sys.argv[1:]


def parse(path):
    sections, current = {}, None
    for line in open(path):
        line = line.strip()
        if line.startswith("["):
            current = sections.setdefault(line.strip("[]"), {})
        elif "=" in line and current is not None and not line.startswith("#"):
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip()
    return sections


def premultiplied(rgba):
    return bytes(c if i % 4 == 3 else (c * rgba[i - i % 4 + 3] + 127) // 255 for i, c in enumerate(rgba))


def decoded(decoder, name):
    stem, ext = os.path.splitext(name)
    frames = []
    while True:
        path = os.path.join(out, f"frames-{decoder}", f"{stem}-frame{len(frames)}{ext}.out")
        if not os.path.exists(path):
            return frames
        with open(path, "rb") as f:
            status, width, height, _, duration = map(int, f.readline().split())
            frames.append((status, width, height, duration, f.read()))


def problem(decoder, conf):
    config = conf["config"]
    names = [name for name in config.get("frames", "").split(",") if name]
    frames = decoded(decoder, config["input"])
    if not names:
        return None if frames[0][0] != 0 else f"decoded {len(frames)} frames, none expected"
    if any(status != 0 for status, *_ in frames):
        return f"refused at frame {len(frames) - 1}"
    if len(frames) != len(names):
        return f"{len(frames)} frames, {len(names)} expected"
    for k, (name, (_, width, height, duration, pixels)) in enumerate(zip(names, frames)):
        if (width, height) != (int(config["width"]), int(config["height"])):
            return f"size {width}x{height}, {config['width']}x{config['height']} expected"
        with open(os.path.join(suite, conf[name]["pixels"]), "rb") as f:
            expected = premultiplied(f.read())
        if pixels != expected:
            return f"frame {k}: {sum(a != b for a, b in zip(pixels, expected))} of {len(expected)} samples differ"
        if duration != 10 * int(conf[name].get("delay", "0")):
            return f"frame {k}: duration {duration} ms, {10 * int(conf[name].get('delay', '0'))} expected"
    return None


tests = [line.strip() for line in open(os.path.join(suite, "TESTS")) if line.strip()]
problems = {decoder: {test: problem(decoder, parse(os.path.join(suite, f"{test}.conf"))) for test in tests} for decoder in decoders}
print("### GIF decoders in the sandbox")
print()
print(f"Conformance: the {len(tests)} tests of the GIF test suite of pygif, each frame decoded at full size and compared with the expected frame, its size and its duration; a test without frames passes when the first frame is refused.")
print()
print("| Decoder | Tests passed | Tests failed |")
print("|---|---|---|")
for decoder in decoders:
    failed = [test for test in tests if problems[decoder][test]]
    print(f"| {decoder} | {len(tests) - len(failed)} | {', '.join(failed) or '-'} |")
print()
print("| Test | " + " | ".join(decoders) + " |")
print("|---" * (len(decoders) + 1) + "|")
for test in tests:
    if any(problems[decoder][test] for decoder in decoders):
        print(f"| {test} | " + " | ".join(problems[decoder][test] or "passed" for decoder in decoders) + " |")
print()
print("Code size: the decoder and its glue compiled to WebAssembly (the code section of gif.o), the module with budget checks, its C, and the text of the sandbox harness compiled by gcc -O2.")
print()
print("| Decoder | Glue lines | Code bytes | checked.wasm | image-wasm.c | Harness text |")
print("|---|---|---|---|---|---|")
for line in open(os.path.join(out, "sizes.tsv")):
    print("| " + " | ".join(line.rstrip("\n").split("\t")) + " |")
print()
times = {}
for decoder in decoders:
    for line in open(os.path.join(out, f"time-{decoder}.tsv")):
        name, _, width, height, frames, _, _, _, total, slowest, status, message = line.rstrip("\n").split("\t")
        times.setdefault((name, width, height, frames), {})[decoder] = f"{float(total) / 1e6:.1f} / {float(slowest) / 1e6:.1f}" if status == "0" else f"refused: {message}"
print("Decode time in the sandbox, every frame at full size, median of 9, ms: all frames / the slowest frame.")
print()
print("| Workload | Canvas | Frames | " + " | ".join(decoders) + " |")
print("|---|---|---|" + "---|" * len(decoders))
for (name, width, height, frames), row in times.items():
    print(f"| {name} | {width}x{height} | {frames} | " + " | ".join(row.get(d, "-") for d in decoders) + " |")
print()
