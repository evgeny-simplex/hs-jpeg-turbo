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

IMPORTS = [
    '  (import "env" "refuel" (func $__refuel (result i32)))',
    '  (import "env" "fill" (func $__fill (param i32 i32 i32)))',
    '  (import "env" "copy" (func $__copy (param i32 i32 i32)))',
]

GLOBALS = [
    "  (global $__fuel (mut i32) (i32.const 0))",
    "  (global $__depth (mut i32) (i32.const 0))",
]

EXPORTS = [
    '  (export "fuel" (global $__fuel))',
    '  (export "depth" (global $__depth))',
]


def balance(line):
    return line.count("(") - line.count(")")


def instrument(lines):
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
        line, replaced = re.subn(r"^(\s*)memory\.(fill|copy)\b", r"\1call $__\2", line)
        counts["bulk"] += replaced
        out.append(line)
        if re.match(r"loop\b", stripped):
            indent = line[: len(line) - len(stripped)] + "  "
            out.extend(indent + check for check in CHECK)
            counts["loops"] += 1
        elif stripped.startswith("(func ") and balance(line) > 0:
            pending = line[: len(line) - len(stripped)] + "  "
    return out, counts


def insert_after_last(lines, prefix, items):
    index = max(i for i, line in enumerate(lines) if line.startswith(prefix))
    lines[index + 1 : index + 1] = items


def main():
    source, target = sys.argv[1:]
    text = open(source).read()
    if re.search(r"\$__(fuel|depth|refuel|fill|copy)\b", text):
        sys.exit("the module already names $__fuel, $__depth, $__refuel, $__fill or $__copy")
    lines, counts = instrument(text.split("\n"))
    insert_after_last(lines, "  (import ", IMPORTS)
    insert_after_last(lines, "  (global ", GLOBALS)
    insert_after_last(lines, "  (export ", EXPORTS)
    open(target, "w").write("\n".join(lines))
    print(
        f"budget checks at {counts['loops']} loop headers and {counts['functions']} function entries, "
        f"{counts['bulk']} memory.fill and memory.copy through the host"
    )


main()
