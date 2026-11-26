import re
import sys

CHECK = [
    "global.get $__fuel",
    "i32.const 1",
    "i32.sub",
    "global.tee $__fuel",
    "i32.const 0",
    "i32.lt_s",
    "if",
    "call $__refuel",
    "global.set $__fuel",
    "end",
]


def balance(line):
    return line.count("(") - line.count(")")


def instrument(lines, entries):
    out, loops, functions, pending = [], 0, 0, None
    for line in lines:
        stripped = line.lstrip()
        if pending is not None:
            if stripped.startswith("(local"):
                out.append(line)
                if balance(line) < 0:
                    pending = None
                continue
            out.extend(pending + check for check in CHECK)
            functions += 1
            pending = None
        out.append(line)
        if re.match(r"loop\b", stripped):
            indent = line[: len(line) - len(stripped)] + "  "
            out.extend(indent + check for check in CHECK)
            loops += 1
        elif entries and stripped.startswith("(func ") and balance(line) > 0:
            pending = line[: len(line) - len(stripped)] + "  "
    return out, loops, functions


def last_index(lines, prefix):
    found = [i for i, line in enumerate(lines) if line.startswith(prefix)]
    return found[-1] if found else None


def main():
    mode, source, target = sys.argv[1:]
    text = open(source).read()
    if "$__fuel" in text or "$__refuel" in text:
        sys.exit("the module already names $__fuel or $__refuel")
    lines, loops, functions = instrument(text.split("\n"), mode == "calls")
    imports = last_index(lines, "  (import ")
    lines.insert(imports + 1, '  (import "env" "refuel" (func $__refuel (result i32)))')
    globals_ = last_index(lines, "  (global ")
    lines.insert(globals_ + 1, "  (global $__fuel (mut i32) (i32.const 0))")
    exports = last_index(lines, "  (export ")
    lines.insert(exports + 1, '  (export "fuel" (global $__fuel))')
    open(target, "w").write("\n".join(lines))
    print(f"{mode}: budget checks at {loops} loop headers and {functions} function entries")


main()
