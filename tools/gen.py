#!/usr/bin/env python3
"""Generate exercises/ and solutions/ from tools/templates/.

Usage: python3 tools/gen.py

Template syntax:
  inline:  ⟪solution text|||exercise text⟫
  block:   a line containing only //⟪  starts the solution part,
           a line //|||  switches to the exercise part,
           a line //⟫  ends it.
  include: a line //@include name  pastes in shared code: a region some
           template exported, or else tools/templates/snippets/name.zig.
  export:  lines //@export name ... //@end  around code (holes allowed)
           make its finished version includable by later exercises, so
           an exercise and the code that builds on it can't drift apart.

Each template also gives a third file, in hard/: the same exercise with
no blanks to fill in. Every function that has a hole loses its whole
body instead (see harden()), and the same tests check it.
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


_exports: dict[str, str] | None = None
_export_owner: dict[str, str] = {}  # export name -> the template that defines it


def exports() -> dict[str, str]:
    """Every //@export region of every template, as finished (solution) code."""
    global _exports
    if _exports is None:
        _exports = {}
        for tpl in sorted(TPL.glob("*.zig")):
            name, region = None, []
            for line in tpl.read_text().splitlines(keepends=True):
                s = line.strip()
                if s.startswith("//@export "):
                    name, region = s.split()[1], []
                    assert not (TPL / "snippets" / f"{name}.zig").exists(), f"{tpl.name}: //@export {name} would hide snippets/{name}.zig"
                    assert name not in _exports, f"{tpl.name}: //@export {name} is exported twice"
                elif s == "//@end" and name is not None:
                    _exports[name] = render_raw(expand_includes("".join(region)), True)
                    _export_owner[name] = tpl.name
                    name = None
                elif name is not None:
                    region.append(line)
            assert name is None, f"{tpl.name}: //@export {name} has no //@end"
    return _exports


def expand_includes(text: str) -> str:
    out = []
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s.startswith("//@include "):
            name = s.split()[1]
            ex = exports()
            out.append(ex[name] if name in ex else (TPL / "snippets" / f"{name}.zig").read_text())
        elif s.startswith("//@export ") or s == "//@end":
            continue
        else:
            out.append(line)
    return "".join(out)


def render(text: str, want_solution: bool) -> str:
    return render_raw(expand_includes(text), want_solution)


def render_raw(text: str, want_solution: bool) -> str:
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


FN_START = re.compile(r"^(\s*)(?:pub )?(?:inline )?fn \w+\(")
HARD_MAX_BODY = 40  # lines; a longer function keeps its fill-in holes
HARD_BANNER = (
    "// HARD MODE (zig build -Dhard): no blanks to fill in. Every function\n"
    "// marked ??? has lost its whole body: write it, from its doc comment,\n"
    "// its signature and the tests. The gentler version of this file is in\n"
    "// exercises/, and the answer in solutions/.\n"
)
HARD_BODY = "???; // write this function's body\n"


def functions(lines: list[str]) -> list[tuple[int, int]]:
    """(last header line, closing brace line) of every function, by zig fmt's layout."""
    out = []
    for i, line in enumerate(lines):
        m = FN_START.match(line)
        if not m:
            continue
        indent = m.group(1)
        head = next((k for k in range(i, min(i + 12, len(lines))) if lines[k].rstrip().endswith("{")), None)
        if head is None:
            continue
        close = next((j for j in range(head + 1, len(lines)) if lines[j].rstrip("\n") == indent + "}"), None)
        if close is not None:
            out.append((head, close))
    return out


def harden(text: str) -> str:
    """The template with the body of each function that has a hole replaced
    by one hole. Holes outside functions (in tests, in constants) stay."""
    own, sep, rest = text.partition("// ─── Finished code from earlier exercises")
    lines = own.splitlines(keepends=True)
    is_hole = [("⟪" in l or l.strip() in ("//|||", "//⟫")) for l in lines]
    fns = functions(lines)
    chosen = set()
    for h in (i for i, x in enumerate(is_hole) if x and "⟪" in lines[i]):
        inside = [(a, b) for a, b in fns if a < h < b]
        if not inside:
            continue
        a, b = max(inside)  # the innermost: the one that starts last
        if b - a - 1 <= HARD_MAX_BODY:
            chosen.add((a, b))
    out, skip_to = [], -1
    for i, line in enumerate(lines):
        if i < skip_to:
            continue
        out.append(line)
        hit = next(((a, b) for a, b in chosen if a == i), None)
        if hit:
            indent = re.match(r"\s*", lines[hit[1]]).group(0) + "    "
            out.append(indent + HARD_BODY)
            skip_to = hit[1]
    return "".join(out) + sep + rest


def main():
    for d in ("exercises", "solutions", "hard"):
        (ROOT / d).mkdir(exist_ok=True)
        for f in (ROOT / d).glob("*.zig"):
            f.unlink()
    for tpl in sorted(TPL.glob("*.zig")):
        text = tpl.read_text()
        # An exercise may only build on EARLIER ones: including a later
        # exercise's export would paste that exercise's answers into this one.
        exports()  # fills _export_owner
        for line in text.splitlines():
            if line.strip().startswith("//@include "):
                owner = _export_owner.get(line.split()[1])
                if owner is not None and owner >= tpl.name:
                    raise SystemExit(f"{tpl.name}: //@include {line.split()[1]} comes from {owner}, which isn't an earlier exercise")
        ex = render(text, False)
        sol = render(text, True)
        if ex == sol:
            raise SystemExit(f"{tpl.name}: exercise has no holes")
        (ROOT / "exercises" / tpl.name).write_text(ex)
        hard = render_raw(harden(expand_includes(text)), False)
        (ROOT / "hard" / tpl.name).write_text((HARD_BANNER if hard != ex else "") + hard)
        (ROOT / "solutions" / tpl.name).write_text(SOLUTION_BANNER + sol)
        print("generated", tpl.name)


if __name__ == "__main__":
    main()
