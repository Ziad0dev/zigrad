#!/usr/bin/env python3
"""Mutation testing: do the tests catch wrong answers?

For every hole, take the reference answer and make one small, plausible
mistake in it: flip an operator, nudge a constant by one, swap two arguments,
drop a statement. Put it back in the solution and run that exercise's tests.
They should fail ("killed"). A mutant that still passes "survived": either the
tests miss that mistake, or the mutant means the same thing as the answer
(@max(0, x) for @max(x, 0)).

Survivors that are known to be equivalent are listed in tools/mutants_ok.txt,
one per line, as `exercise | mutated answer`. Any other survivor is a test gap,
and makes this script exit with status 1.

Usage:
  python3 tools/mutate.py                   every exercise
  python3 tools/mutate.py 07 160            exercises whose names start with 07 or 160
  python3 tools/mutate.py --since origin/main   only templates changed since a git ref
  options: --jobs N   --max-per-hole N (default 12)   --keep (keep the work directory)
"""
import argparse
import hashlib
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import gen  # noqa: E402

ROOT = gen.ROOT
OK_FILE = pathlib.Path(__file__).parent / "mutants_ok.txt"
# Exercises whose answers have many right forms, so a mutated answer is
# usually still right.
SKIP = {
    "190_tests_due_monday": "its answers are tests, and many different tests are right",
}
FLAGS = re.compile(r"^// zig test flags: (.*)$", re.M)

# ── holes ───────────────────────────────────────────────────────────────


def parse(text):
    """Split an (include-expanded) template into plain text and holes."""
    segs, mode, sol, ex = [], None, [], []
    for line in text.splitlines(keepends=True):
        s = line.strip()
        if s == "//⟪" and mode is None:
            mode, sol, ex = "sol", [], []
            continue
        if s == "//|||" and mode == "sol":
            mode = "ex"
            continue
        if s == "//⟫" and mode is not None:
            segs.append({"kind": "block", "sol": "".join(sol), "ex": "".join(ex)})
            mode = None
            continue
        if mode == "sol":
            sol.append(line)
            continue
        if mode == "ex":
            ex.append(line)
            continue
        pos = 0
        for m in gen.INLINE.finditer(line):
            segs.append(line[pos:m.start()])
            segs.append({"kind": "inline", "sol": m.group(1), "ex": m.group(2)})
            pos = m.end()
        segs.append(line[pos:])
    return segs


def render(segs, hole=None, answer=None):
    """The solution, with hole number `hole` answered by `answer` instead."""
    out, h = [], 0
    for s in segs:
        if isinstance(s, str):
            out.append(s)
            continue
        out.append(answer if h == hole else s["sol"])
        h += 1
    return "".join(out)


# ── mutants ─────────────────────────────────────────────────────────────


def mask(code):
    """Blank out comments and string literals, so nothing inside them is mutated."""
    out, i, n = list(code), 0, len(code)
    while i < n:
        if code.startswith("//", i):
            j = code.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = " " * (j - i)
            i = j
        elif code[i] in "\"'":
            q, j = code[i], i + 1
            while j < n and code[j] != q:
                j += 2 if code[j] == "\\" else 1
            out[i:min(j + 1, n)] = " " * (min(j + 1, n) - i)
            i = j + 1
        else:
            i += 1
    return "".join(out)


SWAPS = [
    (r" \+ ", " - "), (r" - ", " + "), (r" \* ", " + "), (r" / ", " * "),
    (r" \+= ", " -= "), (r" -= ", " += "), (r" \*= ", " += "),
    (r" < ", " <= "), (r" <= ", " < "), (r" > ", " >= "), (r" >= ", " > "),
    (r" == ", " != "), (r" != ", " == "), (r" and ", " or "), (r" or ", " and "),
    (r"@max\(", "@min("), (r"@min\(", "@max("), (r"@floor\(", "@ceil("), (r"@ceil\(", "@floor("),
    (r"@divFloor\(", "@divTrunc("), (r"@divTrunc\(", "@divFloor("),
    (r"\btrue\b", "false"), (r"\bfalse\b", "true"),
]
INT = re.compile(r"(?<![\w.])(\d+)(?![\w.])")
FLOAT = re.compile(r"(?<![\w.])(\d+\.\d+)(?![\w.])")
NEG = re.compile(r"(?<![\w)\]])-(?=[A-Za-z_(@])")
NOT = re.compile(r"!(?=[A-Za-z_(@])")
ARGS2 = re.compile(r"\(\s*([A-Za-z_][\w.]*|\d+(?:\.\d+)?)\s*,\s*([A-Za-z_][\w.]*|\d+(?:\.\d+)?)\s*\)")


def mutants(code, kind):
    m, seen, out = mask(code), {code}, []

    def add(new, desc):
        if new not in seen:
            seen.add(new)
            out.append((desc, new))

    for pat, rep in SWAPS:
        for mt in re.finditer(pat, m):
            add(code[:mt.start()] + rep + code[mt.end():], f"{mt.group(0).strip()} -> {rep.strip()}")
    for mt in INT.finditer(m):
        v = int(mt.group(1))
        add(code[:mt.start()] + str(v + 1) + code[mt.end():], f"{v} -> {v + 1}")
        if v > 0:
            add(code[:mt.start()] + str(v - 1) + code[mt.end():], f"{v} -> {v - 1}")
    for mt in FLOAT.finditer(m):
        add(code[:mt.start()] + repr(float(mt.group(1)) + 1.0) + code[mt.end():], f"{mt.group(1)} + 1")
    for mt in NEG.finditer(m):
        add(code[:mt.start()] + code[mt.end():], "drop a unary -")
    for mt in NOT.finditer(m):
        add(code[:mt.start()] + code[mt.end():], "drop a !")
    for mt in ARGS2.finditer(m):
        a, b = mt.group(1), mt.group(2)
        if a != b:
            add(code[:mt.start()] + f"({b}, {a})" + code[mt.end():], f"swap ({a}, {b})")
    if kind == "block":
        lines = code.splitlines(keepends=True)
        for i, line in enumerate(lines):
            s = line.strip()
            if s.endswith(";") and not s.startswith(("//", "const ", "var ", "return", "_ =")):
                add("".join(lines[:i] + lines[i + 1:]), f"delete `{s[:40]}`")
    return out


# ── running ─────────────────────────────────────────────────────────────


def run(job):
    path, work = job["path"], job["work"]
    exe = path.with_suffix(".bin")
    c = subprocess.run(["zig", "test", *job["flags"], str(path), "--test-no-exec", f"-femit-bin={exe}",
                        "--cache-dir", str(work / "cache")], cwd=work, capture_output=True, text=True)
    if c.returncode != 0:
        return "stillborn"
    try:
        r = subprocess.run([str(exe)], cwd=work, capture_output=True, text=True, timeout=120)
        out = r.stderr + r.stdout
        if r.returncode == 0 and re.search(r"\b\d+ passed; [1-9]\d* skipped", out):
            # It passed, but the tests that might have killed it didn't run
            # (GPU tests on a machine without a GPU): no verdict either way.
            return "skipped"
        return "survived" if r.returncode == 0 else "killed"
    except subprocess.TimeoutExpired:
        return "killed"
    finally:
        exe.unlink(missing_ok=True)


def changed_since(ref):
    names = subprocess.run(["git", "diff", "--name-only", ref, "--", "tools/templates"],
                           cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    snippets = {pathlib.Path(n).stem for n in names if "/snippets/" in n}
    # a changed template changes every later exercise that includes its exports
    gen.exports()
    snippets |= {name for name, owner in gen._export_owner.items() if f"tools/templates/{owner}" in names}
    picked = []
    for tpl in sorted(gen.TPL.glob("*.zig")):
        includes = set(re.findall(r"^\s*//@include (\S+)", tpl.read_text(), re.M))
        if f"tools/templates/{tpl.name}" in names or includes & snippets:
            picked.append(tpl)
    return picked


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prefixes", nargs="*")
    ap.add_argument("--since")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--max-per-hole", type=int, default=12)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    if a.since:
        tpls = changed_since(a.since)
    else:
        tpls = [t for t in sorted(gen.TPL.glob("*.zig")) if not a.prefixes or t.name.startswith(tuple(a.prefixes))]
    for t in [t for t in tpls if t.stem in SKIP]:
        print(f"skipping {t.stem}: {SKIP[t.stem]}")
    tpls = [t for t in tpls if t.stem not in SKIP]
    if not tpls:
        print("no exercises to check")
        return

    ok = set()
    if OK_FILE.exists():
        for line in OK_FILE.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                ok.add(line.strip())

    work = pathlib.Path(tempfile.mkdtemp(prefix="zigrad-mutate-"))
    jobs = []
    for tpl in tpls:
        text = gen.expand_includes(tpl.read_text())
        flags = FLAGS.search(text)
        flags = flags.group(1).split() if flags else []
        segs = parse(text)
        holes = [s for s in segs if not isinstance(s, str)]
        control = work / f"{tpl.stem}__control.zig"
        control.write_text(render(segs))
        jobs.append({"tpl": tpl.stem, "hole": -1, "desc": "unmutated", "answer": "", "path": control,
                     "work": work, "flags": flags})
        for hi, h in enumerate(holes):
            ms = mutants(h["sol"], h["kind"])
            if len(ms) > a.max_per_hole:  # a reproducible sample
                seed = int(hashlib.sha256(f"{tpl.stem}:{hi}:{h['sol']}".encode()).hexdigest(), 16)
                ms = random.Random(seed).sample(ms, a.max_per_hole)
            for mi, (desc, new) in enumerate(ms):
                p = work / f"{tpl.stem}__{hi}_{mi}.zig"
                p.write_text(render(segs, hi, new))
                jobs.append({"tpl": tpl.stem, "hole": hi, "desc": desc, "answer": " ".join(new.split()),
                             "path": p, "work": work, "flags": flags})

    print(f"{len(jobs) - len(tpls)} mutants of {len(tpls)} exercises, {a.jobs} at a time", flush=True)
    t0 = time.time()
    # one plain compile first, so the parallel jobs share a warm cache
    run({"path": jobs[0]["path"], "work": work, "flags": jobs[0]["flags"]})
    with ThreadPoolExecutor(a.jobs) as pool:
        results = list(pool.map(run, jobs))

    bad_controls, survivors, counts = [], [], {}
    for j, status in zip(jobs, results):
        if j["hole"] < 0:
            if status not in ("survived", "skipped"):
                bad_controls.append(j["tpl"])
            continue
        counts[status] = counts.get(status, 0) + 1
        if status == "survived":
            survivors.append(j)

    viable = counts.get("killed", 0) + counts.get("survived", 0)
    print(f"done in {time.time() - t0:.0f}s: {counts.get('killed', 0)} of {viable} viable mutants killed"
          f" ({counts.get('stillborn', 0)} didn't compile, {counts.get('skipped', 0)} skipped)")
    if bad_controls:
        print("the unmutated solution FAILS for:", ", ".join(bad_controls))

    new = [s for s in survivors if f"{s['tpl']} | {s['answer']}" not in ok]
    if new:
        print(f"\n{len(new)} mutants survived (a test gap, or an equivalent answer for tools/mutants_ok.txt):")
        for s in new:
            print(f"  {s['tpl']} | {s['answer']}      ({s['desc']})")
    if a.keep:
        print("work directory:", work)
        (work / "results.json").write_text(json.dumps(
            [{k: str(v) for k, v in j.items() if k != "work"} | {"status": st} for j, st in zip(jobs, results)], indent=1))
    else:
        shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if new or bad_controls else 0)


if __name__ == "__main__":
    main()
