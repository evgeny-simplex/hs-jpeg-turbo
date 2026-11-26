import re
import sys

CHECK = [
    "global.get $__fuel",
    "i32.const 1",
    "i32.sub",
    "global.set $__fuel",
    "global.get $__fuel",
    "i32.const 0",
    "i32.lt_s",
    "if",
    "call $__refuel",
    "global.set $__fuel",
    "end",
]

IMPORTS = {
    "refuel": '  (import "env" "refuel" (func $__refuel (result i32)))',
    "fill": '  (import "env" "fill" (func $__fill (param i32 i32 i32)))',
    "copy": '  (import "env" "copy" (func $__copy (param i32 i32 i32)))',
}


def balance(line):
    return line.count("(") - line.count(")")


def instrument(lines, entries, bulk):
    out, counts, pending = [], {"loops": 0, "functions": 0, "bulk": 0}, None
    for line in lines:
        stripped = line.lstrip()
        if pending is not None:
            if stripped.startswith("(local"):
                out.append(line)
                if balance(line) < 0:
                    pending = None
                continue
            out.extend(pending + check for check in CHECK)
            counts["functions"] += 1
            pending = None
        if bulk:
            line, replaced = re.subn(r"^(\s*)memory\.(fill|copy)\b", r"\1call $__\2", line)
            counts["bulk"] += replaced
        out.append(line)
        if re.match(r"loop\b", stripped):
            indent = line[: len(line) - len(stripped)] + "  "
            out.extend(indent + check for check in CHECK)
            counts["loops"] += 1
        elif entries and stripped.startswith("(func ") and balance(line) > 0:
            pending = line[: len(line) - len(stripped)] + "  "
    return out, counts


def last_index(lines, prefix):
    found = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    return found[-1] if found else None


def main():
    mode, source, target = sys.argv[1:]
    text = open(source).read()
    if re.search(r"\$__(fuel|refuel|fill|copy)\b", text):
        sys.exit("the module already names $__fuel, $__refuel, $__fill or $__copy")
    lines, counts = instrument(text.split("\n"), mode in ("calls", "bulk"), mode == "bulk")
    imports = last_index(lines, "  (import ")
    for name in ["refuel", "fill", "copy"] if mode == "bulk" else ["refuel"]:
        imports += 1
        lines.insert(imports, IMPORTS[name])
    globals_ = last_index(lines, "  (global ")
    lines.insert(globals_ + 1, "  (global $__fuel (mut i32) (i32.const 0))")
    exports = last_index(lines, "  (export ")
    lines.insert(exports + 1, '  (export "fuel" (global $__fuel))')
    open(target, "w").write("\n".join(lines))
    print(
        f"{mode}: budget checks at {counts['loops']} loop headers and {counts['functions']} function entries, "
        f"{counts['bulk']} memory.fill and memory.copy through the host"
    )


main()
