import concurrent.futures
import csv
import glob
import json
import os
import subprocess
import sys
import tempfile

BACKGROUNDS = {"light": (0xF5, 0xF5, 0xF6), "dark": (0x18, 0x26, 0x2E)}
MODELS = ["preview", "phone", "large"]
MODES = ["decode", "image", "preview"]


VARIANTS = {
    "png": [("base-png", "base", "4096", False), ("new-png", "new", "1024", False), ("new-png-sharp", "new", "1024", True), ("cr-png", "cr", "4096", False), ("cr-png-sharp", "cr", "4096", True)],
    "jpeg": [("base-jpeg", "base", "1024", False), ("base-jpeg-sharp", "base", "1024", True)],
}


def cpu():
    with open("/proc/cpuinfo") as f:
        return next((line.split(":", 1)[1].strip() for line in f if line.startswith("model name")), "?")


def run(binary, args, env):
    with tempfile.NamedTemporaryFile("r") as timing:
        process = subprocess.run(
            ["/usr/bin/time", "-f", "%M %e", "-o", timing.name, binary, *args],
            env={**os.environ, **env},
            capture_output=True,
            text=True,
        )
        rss_kb, wall = timing.read().split()[-2:]
    lines = process.stdout.strip().splitlines()
    result = json.loads(lines[-1]) if process.returncode == 0 and lines else {"exit": process.returncode, "stderr": process.stderr[-2000:]}
    result.update(rss_mib=round(int(rss_kb) / 1024, 1), wall_s=float(wall), cpu=cpu())
    return result


def resize(binaries, wanted, out, files):
    results = []
    for variant, version, limit, sharpen in VARIANTS[wanted]:
        if version not in binaries:
            continue
        env = {"MAX_DECODE_MB": limit, **({"SHARPEN_KEPT": "1"} if sharpen else {})}
        for path in files:
            name = os.path.splitext(os.path.basename(path))[0]
            directory = os.path.join(out, variant, name)
            os.makedirs(directory, exist_ok=True)
            result = run(binaries[version], ["resize", path, directory], env)
            result.update(variant=variant, name=name, input_bytes=os.path.getsize(path))
            print(json.dumps(result), flush=True)
            results.append(result)
    return results


def memory(binaries, out, files):
    results = []
    for limit in ["512", "1024"]:
        for path in files:
            for mode in MODES:
                for version, binary in binaries.items():
                    name = os.path.splitext(os.path.basename(path))[0]
                    directory = os.path.join(out, "memory", version, limit, name)
                    os.makedirs(directory, exist_ok=True)
                    args = ["decode", path] if mode == "decode" else [mode, path, directory]
                    result = run(binary, args, {"MAX_DECODE_MB": limit})
                    result.update(version=version, limit=int(limit), mode=mode, name=name, input_bytes=os.path.getsize(path))
                    print(json.dumps(result), flush=True)
                    results.append(result)
    return results


STAGE_INPUTS = ["zero-rgba8-8192x8192-paeth", "zero-rgba8-8192x8192-adam7-paeth", "large", "relief-transparent", "saturn-photo", "world-map", "grey-16384x16384"]


def stages(binaries, files):
    results = []
    for limit in ["512", "1024"]:
        for path in files:
            name = os.path.splitext(os.path.basename(path))[0]
            if name not in STAGE_INPUTS:
                continue
            for version, binary in binaries.items():
                process = subprocess.run([binary, "stages", path, "+RTS", "-T", "-RTS"], env={**os.environ, "MAX_DECODE_MB": limit}, capture_output=True, text=True)
                lines = [json.loads(line) for line in process.stdout.splitlines() if line.startswith("{")]
                if process.returncode != 0:
                    lines.append({"stage": "exit", "error": f"exit {process.returncode}: {process.stderr[-300:]}"})
                for line in lines:
                    line.update(version=version, limit=int(limit), name=name, cpu=cpu())
                    print(json.dumps(line), flush=True)
                results += lines
    return results


def binaries(directory, versions=("base", "new", "cr")):
    return {version: path for version in versions if os.path.exists(path := os.path.join(directory, f"resize-{version}"))}


def equality(base, new, out, files):
    rows = []
    for path in files:
        name = os.path.relpath(path)
        pair = {}
        for version, binary in [("base", base), ("new", new)]:
            directory = os.path.join(out, "equal", version, name.replace("/", "_"))
            os.makedirs(directory, exist_ok=True)
            pair[version] = (run(binary, ["decode", path], {}), run(binary, ["resize", path, directory], {}))
        (base_decode, base_resize), (new_decode, new_resize) = pair["base"], pair["new"]
        row = {
            "name": name,
            "decode": same(base_decode, new_decode, ["error", "width", "height", "constructor", "profile", "samples_fnv1a"]),
            "image": same_output(base_resize, new_resize, "image"),
            "preview": same_output(base_resize, new_resize, "preview"),
            "base": base_resize,
            "new": new_resize,
        }
        print(json.dumps(row), flush=True)
        rows.append(row)
    return rows


def same(a, b, keys):
    return all(a.get(k) == b.get(k) for k in keys) and "exit" not in a and "exit" not in b


def same_output(a, b, name):
    if "exit" in a or "exit" in b:
        return False
    files = [r.get(name + "_file") for r in (a, b)]
    if files[0] is None or files[1] is None:
        return files[0] == files[1] and a.get("error") == b.get("error") and a.get(name + "_error") == b.get(name + "_error")
    with open(files[0], "rb") as f, open(files[1], "rb") as g:
        return f.read() == g.read()


def display_sizes(width, height):
    preview_width = 910 if width >= height else 682

    def fit(box_width, box_height):
        scale = min(box_width / width, box_height / height)
        return (max(1, round(width * scale)), max(1, round(height * scale)))

    return {"preview": (preview_width, max(1, round(height * preview_width / width))), "phone": fit(1179, 2556), "large": fit(2560, 1600)}


def source_image(path, decoder, work):
    from PIL import Image, ImageOps

    if path.endswith(".png"):
        raw = os.path.join(work, "source.rgba")
        width, height = map(int, subprocess.run([decoder, path, raw], check=True, capture_output=True, text=True).stdout.split())
        with open(raw, "rb") as f:
            image = Image.frombuffer("RGBA", (width, height), f.read(), "raw", "RGBA", 0, 1)
        os.remove(raw)
        return image
    return ImageOps.exif_transpose(Image.open(path)).convert("RGBA")


def composited(image, size, resample, background):
    from PIL import Image

    resized = image.resize(size, resample)
    return Image.alpha_composite(Image.new("RGBA", size, background + (255,)), resized).convert("RGB")


def ssimulacra2(tool, reference, candidate):
    output = subprocess.run([tool, reference, candidate], check=True, capture_output=True, text=True).stdout
    return float(output.split()[-1])


def score(tool, decoder, out, sources, results, root):
    from PIL import Image

    def output(result, kind):
        return (glob.glob(os.path.join(root, result["variant"], result["name"], kind + ".*")) or [None])[0]


    Image.MAX_IMAGE_PIXELS = None
    scores = []
    by_name = {}
    for result in results:
        by_name.setdefault(result["name"], []).append(result)
    for name, variants in sorted(by_name.items()):
        work = os.path.join(out, "score", name)
        os.makedirs(work, exist_ok=True)
        source = source_image(sources[name], decoder, work)
        sizes = display_sizes(*source.size)
        references = {}
        for model, size in sizes.items():
            for background_name, background in BACKGROUNDS.items():
                path = os.path.join(work, f"reference-{model}-{background_name}.png")
                composited(source, size, Image.LANCZOS, background).save(path)
                references[(model, background_name)] = path
        source_size = source.size
        del source
        jobs = []
        for result in variants:
            outputs = {"preview": output(result, "preview"), "phone": output(result, "image"), "large": output(result, "image")}
            for model, size in sizes.items():
                if outputs[model] is None:
                    continue
                candidate = Image.open(outputs[model]).convert("RGBA")
                for background_name, background in BACKGROUNDS.items():
                    path = os.path.join(work, f"{result['variant']}-{model}-{background_name}.png")
                    composited(candidate, size, Image.BILINEAR, background).save(path)
                    jobs.append((result["variant"], model, references[(model, background_name)], path))
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            values = list(pool.map(lambda job: ssimulacra2(tool, job[2], job[3]), jobs))
        lowest = {}
        for (variant, model, _, _), value in zip(jobs, values):
            lowest[(variant, model)] = min(value, lowest.get((variant, model), value))
        for result in variants:
            row = {"name": name, "variant": result["variant"], "source_width": source_size[0], "source_height": source_size[1]}
            row.update({model: lowest.get((result["variant"], model)) for model in MODELS})
            for key in ["image_width", "image_height", "image_bytes", "preview_width", "preview_height", "preview_chars", "decode_ms", "image_ms", "preview_ms", "error", "rss_mib", "wall_s", "cpu"]:
                row[key] = result.get(key)
            print(json.dumps(row), flush=True)
            scores.append(row)
    return scores


def corpus(path, directory, wanted):
    with open(path) as f:
        rows = [row for row in csv.DictReader(f, delimiter="\t") if row["set"] == wanted]
    return [glob.glob(os.path.join(directory, wanted, row["name"] + ".*"))[0] for row in rows]


def fmt(value, digits=1):
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(fmt(cell) for cell in row) + " |" for row in rows]
    return "\n".join(lines) + "\n"


def memory_report(results):
    out = "## Memory and time\n\nMaximum resident set (MiB) and wall time (s) of one process per row, as one call of the C API: `decode` is `decodeResizable` alone; `image`, `decodeResizable` and `resizeImage` of 261120 bytes in the format of `imageFormat` (`chat_resize_image` with png = -1); `preview`, `decodeResizable` and `resizeImageDataUri` of 14000 characters (`chat_resize_image_uri`).\n\n"
    keyed = {(r["name"], r["limit"], r["mode"], r["version"]): r for r in results}
    names = list(dict.fromkeys(r["name"] for r in results))
    rows = []
    for name in names:
        for limit in [512, 1024]:
            for mode in MODES:
                row = [name, keyed.get((name, limit, mode, "base"), {}).get("input_bytes"), limit, mode]
                for version in ["base", "new"]:
                    r = keyed.get((name, limit, mode, version))
                    if r is None:
                        row += [None, None, None]
                        continue
                    outcome = r.get("error") or r.get("stderr", "").strip().splitlines()[-1:] or None
                    if isinstance(outcome, list):
                        outcome = outcome[0] if outcome else None
                    if outcome is None:
                        outcome = f"{r.get('width')}×{r.get('height')}"
                    row += [outcome, r["rss_mib"], f"{r['wall_s']:.2f}"]
                rows.append(row)
    cpus = ", ".join(sorted({r.get("cpu", "?") for r in results}))
    return out + f"Base and new ran one after the other on one runner: {cpus}.\n\n" + table(["input", "bytes", "MAX_DECODE_MB", "mode", "base result", "base MiB", "base s", "new result", "new MiB", "new s"], rows)


def stages_report(results):
    out = "## Memory by stage\n\nOne process per input, version and limit; after each stage: resident set (`VmRSS`) and its peak so far (`VmHWM`), then a major GC and the bytes live after it (`+RTS -T`), MiB. The stages before `resizeImage` repeat its first trial with the exported functions: `scaleRGBA8` of the decoded image at 1×1 premultiplies the whole image, as the first trial of `fitImage` does, and the closure keeps the premultiplied copy for the trial at the largest size; `resizeImage` and `resizeImageDataUri` then run the whole size search, each with its own premultiplied copy. The major GC after each stage lowers the later peaks below those of one uninterrupted call, which \"Memory and time\" measures.\n\n"
    rows = [[r["name"], r["limit"], r["version"], r["stage"], r.get("error") or "", r.get("ms"), r.get("rss_mib"), r.get("hwm_mib"), r.get("live_after_gc_mib")] for r in results]
    return out + table(["input", "MAX_DECODE_MB", "version", "stage", "error", "ms", "RSS", "peak RSS", "live after GC"], rows)


def equality_report(rows):
    out = "## Equality with today's path, sides at most 4320\n\n"
    counts = {k: sum(1 for r in rows if r[k]) for k in ["decode", "image", "preview"]}
    out += f"{len(rows)} inputs; decodeResizable identical (samples, size, constructor, profile, error): {counts['decode']}; image data identical: {counts['image']}; preview identical: {counts['preview']}.\n\n"
    differing = [[r["name"], r["decode"], r["image"], r["preview"]] for r in rows if not (r["decode"] and r["image"] and r["preview"])]
    if differing:
        out += table(["input", "decode", "image", "preview"], differing)
    return out


def quality_report(scores):
    out = "## Quality, SSIMULACRA2 at display size\n\nLower of the light and dark bubble backgrounds; reference: the source resized with premultiplied Lanczos3; candidate: the output resized bilinear.\n\n"
    for wanted, variants in [("png", ["base-png", "new-png", "new-png-sharp", "cr-png", "cr-png-sharp"]), ("jpeg", ["base-jpeg", "base-jpeg-sharp"])]:
        rows = [s for s in scores if s["variant"] in variants]
        if not rows:
            continue
        present = [v for v in variants if any(s["variant"] == v for s in rows)]
        keyed = {(s["name"], s["variant"]): s for s in rows}
        names = list(dict.fromkeys(s["name"] for s in rows))
        out += f"{wanted}: the variants ran one after the other on one runner: {', '.join(sorted({s.get('cpu') or '?' for s in rows}))}.\n\n"
        for title, keys in [("scores", MODELS), ("output", ["image_width", "image_bytes", "preview_width", "preview_chars"]), ("milliseconds", ["decode_ms", "image_ms", "preview_ms"])]:
            header = ["input", "source"] + [f"{v} {k}" for k in keys for v in present]
            body = []
            for name in names:
                first = next(keyed[(name, v)] for v in present if (name, v) in keyed)
                body.append([name, f"{first['source_width']}×{first['source_height']}"] + [keyed.get((name, v), {}).get(k) for k in keys for v in present])
            if title == "scores":
                means = ["mean", "inputs scored in every variant"]
                for k in keys:
                    common = [n for n in names if all((n, v) in keyed and keyed[(n, v)][k] is not None for v in present)]
                    for v in present:
                        values = [keyed[(n, v)][k] for n in common]
                        means.append(sum(values) / len(values) if values else None)
                body.append(means)
            out += f"### {wanted}: {title}\n\n" + table(header, body) + "\n"
    return out


def environment_report():
    core = os.environ.get("NEW_SOURCE", "")
    if core == "provisional":
        new = "new: master's Image.hs with its PNG line of `decodeResizable` replaced by `Spng.DecodeOptions (2 ^ (28 :: Int)) (maxDecodeMemoryMB `div` 2) (\\(w, h) -> maybe imageDoesNotFit (Right . snd) $ displaySize w h)`, provisional until a commit of ep/core-png is measured, with the binding of this branch"
    elif core:
        new = f"new: Image.hs of evgeny-simplex/simplex-chat at {core}, with the binding of this branch"
    else:
        new = "new: not measured"
    base = f"base: Image.hs of simplex-chat/simplex-chat at {os.environ.get('BASE_CORE')}, with simplex-chat/hs-jpeg-turbo at {os.environ.get('BASE_BINDING')}"
    cr = "cr: master's Image.hs with its PNG line of `decodeResizable` replaced by a full-size decode with the binding of this branch, then `catmullRom` to the display size without sharpening (colour premultiplied by alpha, then divided out), the output that a Catmull-Rom resampler streamed in the decoder would return"
    return f"{base}; {new}; {cr}.\n\nEach measurement process runs alone on a GitHub ubuntu-24.04 runner with 4 CPUs. Image.hs is compiled with two replacements read from the environment: `maxDecodeMemoryMB` from `MAX_DECODE_MB` (1024 when unset, as in desktop builds) and sharpening at the kept size when `SHARPEN_KEPT` is set; with `SHARPEN_KEPT` unset and `MAX_DECODE_MB` at 512 or 1024, the code equals the commit's code of mobile or desktop builds.\n\n"


def main():
    command, *args = sys.argv[1:]
    if command == "memory":
        directory, out, inputs, corpus_file = args
        files = sorted(glob.glob(os.path.join(inputs, "generated", "*"))) + corpus(corpus_file, inputs, "png")
        write_json(os.path.join(out, "stages.json"), stages(binaries(directory, ("base", "new")), files))
        write_json(os.path.join(out, "memory.json"), memory(binaries(directory, ("base", "new")), out, files))
    elif command == "resize":
        directory, wanted, out, inputs, corpus_file = args
        write_json(os.path.join(out, f"resize-{wanted}.json"), resize(binaries(directory), wanted, out, corpus(corpus_file, inputs, wanted)))
    elif command == "equality":
        base, new, out, inputs, corpus_file = args
        files = corpus(corpus_file, inputs, "equal") + sorted(glob.glob(os.path.join(inputs, "fixtures", "*.png"))) + sorted(glob.glob("JuicyPixels-spng/cbits/libspng/tests/images/*.png"))
        write_json(os.path.join(out, "equality.json"), equality(base, new, out, files))
    elif command == "score":
        tool, decoder, out, inputs, corpus_file, root = args
        sources = {os.path.splitext(os.path.basename(p))[0]: p for s in ["png", "jpeg"] for p in corpus(corpus_file, inputs, s)}
        results = [r for f in sorted(glob.glob(os.path.join(root, "resize-*.json"))) for r in json.load(open(f))]
        write_json(os.path.join(out, "scores.json"), score(tool, decoder, out, sources, results, root))
    elif command == "report":
        out, = args
        report = environment_report()
        memories = [r for f in sorted(glob.glob(os.path.join(out, "**", "memory.json"), recursive=True)) for r in json.load(open(f))]
        if memories:
            report += memory_report(memories) + "\n"
        stage_rows = [r for f in sorted(glob.glob(os.path.join(out, "**", "stages.json"), recursive=True)) for r in json.load(open(f))]
        if stage_rows:
            report += stages_report(stage_rows) + "\n"
        equalities = glob.glob(os.path.join(out, "**", "equality.json"), recursive=True)
        if equalities:
            report += equality_report(json.load(open(equalities[0]))) + "\n"
        scores = glob.glob(os.path.join(out, "**", "scores.json"), recursive=True)
        if scores:
            report += quality_report(json.load(open(scores[0])))
        with open(os.path.join(out, "report.md"), "w") as f:
            f.write(report)
        print(report)
    else:
        sys.exit(f"unknown command {command}")


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(value, f, indent=1)


if __name__ == "__main__":
    main()
