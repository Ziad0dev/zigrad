#!/usr/bin/env python3
"""Check that every ??? hole gives a helpful error.

For each template, answer the first k holes (k = 0, 1, 2, ...) and leave the
rest as shipped. `zig ast-check` must then report its first error on a line
that still has a ??? in it, so a student is always pointed at a hole, never
at some confusing line elsewhere.

Usage: python3 tools/check_holes.py [prefix]      e.g. tools/check_holes.py 16
"""
import pathlib
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import gen  # noqa: E402

INLINE = re.compile(r"⟪(.*?)\|\|\|(.*?)⟫")


def render(text, k):
    """Answer the first k ??? holes; leave the rest as in the exercise."""
    count = [0]

    def pick(sol, ex):
        if "???" in ex:
            count[0] += 1
            return sol if count[0] <= k else ex
        return ex

    lines, mode, sol, ex = [], None, [], []
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s == "//⟪":
            mode, sol, ex = "sol", [], []
            continue
        if s == "//|||" and mode == "sol":
            mode = "ex"
            continue
        if s == "//⟫" and mode:
            lines.append(pick("".join(sol), "".join(ex)))
            mode = None
            continue
        if mode == "sol":
            sol.append(line)
            continue
        if mode == "ex":
            ex.append(line)
            continue
        lines.append(INLINE.sub(lambda m: pick(m.group(1), m.group(2)), line))
    return "".join(lines), count[0]


def code_has_hole(src):
    return any("???" in l and not l.strip().startswith("//") for l in src.splitlines())


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else ""
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for tpl in sorted(gen.TPL.glob(prefix + "*.zig")):
            text = gen.expand_includes(tpl.read_text())
            _, holes = render(text, 0)
            for k in range(holes):
                src, _ = render(text, k)
                if not code_has_hole(src):
                    continue
                f = pathlib.Path(tmp) / tpl.name
                f.write_text(src)
                r = subprocess.run(["zig", "ast-check", str(f)], capture_output=True, text=True)
                errs = re.findall(r":(\d+):\d+: error: (.*)", r.stderr)
                if not errs:
                    print(f"BAD  {tpl.name}, {k} holes answered: no error, but ??? remain")
                    bad += 1
                    continue
                line = src.splitlines()[int(errs[0][0]) - 1]
                if "???" not in line:
                    print(f"BAD  {tpl.name}, {k} holes answered: first error is not on a hole: {line.strip()}")
                    bad += 1
    print("holes ok" if bad == 0 else f"{bad} problems")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
