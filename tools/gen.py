#!/usr/bin/env python3
"""Generate exercises/ and solutions/ from tools/templates/.

Usage: python3 tools/gen.py

Template syntax:
  inline:  ⟪solution text|||exercise text⟫
  block:   a line containing only //⟪  starts the solution part,
           a line //|||  switches to the exercise part,
           a line //⟫  ends it.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent  # repo root
TPL = pathlib.Path(__file__).resolve().parent / "templates"
INLINE = re.compile(r"⟪(.*?)\|\|\|(.*?)⟫")

SOLUTION_BANNER = (
    "// Reference solution. Try the exercise in exercises/ first:\n"
    "// struggling a bit is how this stuff sticks.\n"
)


def expand_includes(text: str) -> str:
    out = []
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.startswith("//@include "):
            name = s.split()[1]
            out.append((TPL / "snippets" / f"{name}.zig").read_text())
        else:
            out.append(line)
    return "".join(out)


def render(text: str, want_solution: bool) -> str:
    text = expand_includes(text)
    out = []
    mode = None  # None, "sol", "ex"
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s == "//⟪":
            mode = "sol"
            continue
        if s == "//|||" and mode == "sol":
            mode = "ex"
            continue
        if s == "//⟫" and mode is not None:
            mode = None
            continue
        if mode == "sol" and not want_solution:
            continue
        if mode == "ex" and want_solution:
            continue
        out.append(INLINE.sub(lambda m: m.group(1) if want_solution else m.group(2), line))
    assert mode is None, "unterminated block"
    return "".join(out)


def main():
    for d in ("exercises", "solutions"):
        (ROOT / d).mkdir(exist_ok=True)
        for f in (ROOT / d).glob("*.zig"):
            f.unlink()
    for tpl in sorted(TPL.glob("*.zig")):
        text = tpl.read_text()
        ex = render(text, False)
        sol = render(text, True)
        if ex == sol:
            raise SystemExit(f"{tpl.name}: exercise has no holes")
        (ROOT / "exercises" / tpl.name).write_text(ex)
        (ROOT / "solutions" / tpl.name).write_text(SOLUTION_BANNER + sol)
        print("generated", tpl.name)


if __name__ == "__main__":
    main()
