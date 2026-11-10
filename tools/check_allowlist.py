#!/usr/bin/env python3
"""Check tools/mutants_ok.txt, the allowlist of equivalent mutants.

An entry is `exercise | mutated answer`, with no hole number. So it must
match a mutant of exactly ONE hole of that exercise: an entry that matches
none is stale, and one that matches several would also excuse a real
survivor in a hole it was never meant for.

Usage: python3 tools/check_allowlist.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import gen  # noqa: E402
import mutate  # noqa: E402


def main():
    bad = 0
    for line in mutate.OK_FILE.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        ex, _, answer = (part.strip() for part in line.partition(" | "))
        tpl = gen.TPL / f"{ex}.zig"
        if not tpl.exists():
            print(f"BAD  no such exercise: {ex}")
            bad += 1
            continue
        holes = [s for s in mutate.parse(gen.expand_includes(tpl.read_text())) if not isinstance(s, str)]
        hits = [i for i, h in enumerate(holes) if answer in {" ".join(new.split()) for _, new in mutate.mutants(h["sol"], h["kind"])}]
        if len(hits) != 1:
            print(f"BAD  {ex}: matches {len(hits)} holes, not 1: {answer[:60]}")
            bad += 1
    print("allowlist ok" if bad == 0 else f"{bad} problems")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
