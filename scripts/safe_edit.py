#!/usr/bin/env python3
"""
Replace a literal string in a file, exactly once.

Three build breaks in one session came from str.replace() matching an anchor
that appeared more than once: a protocol requirement pasted into the extension
implementing it, an attribute moved onto the wrong function, and two helper
views copied into a struct that has none of the properties they use. Each cost
a CI round to find, because the compiler reported the damage far from the edit.

The mistake is not in the replacement, it is in not checking how many places
it lands. This refuses to write anything unless the count is what the caller
said it would be.

    scripts/safe_edit.py FILE OLD NEW [--count N]
"""
import sys, pathlib, argparse

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--count", type=int, default=1,
                    help="how many occurrences are expected (default 1)")
    args = ap.parse_args()

    path = pathlib.Path(args.file)
    text = path.read_text()
    found = text.count(args.old)

    if found != args.count:
        print(f"refusing to edit {path.name}: anchor appears {found} time(s), "
              f"expected {args.count}", file=sys.stderr)
        if found > args.count:
            for lineno, line in enumerate(text.splitlines(), 1):
                if args.old.splitlines()[0] in line:
                    print(f"  {path.name}:{lineno}  {line.strip()}", file=sys.stderr)
        return 1

    path.write_text(text.replace(args.old, args.new))
    print(f"{path.name}: replaced {found} occurrence(s)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
