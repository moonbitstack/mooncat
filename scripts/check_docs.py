#!/usr/bin/env python3
"""Every source file has a section, and every section has its file.

The one-way check — do the listed files exist — passes while a new module sits
undocumented, which is how a page goes stale without breaking. Run from the
repository root:

    python scripts/check_docs.py
"""
import glob
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP_DIRS = ("examples/", "_build/", ".mooncakes/", "scripts/")


def listed():
    src = (ROOT / "scripts" / "gen_docs.py").read_text(encoding="utf-8")
    pairs = re.findall(r"'([A-Za-z0-9_/.]+\.mbt)'|\"([A-Za-z0-9_/.]+\.mbt)\"", src)
    return [a or b for a, b in pairs]


def sources():
    out = set()
    for pattern in ("*.mbt", "*/*.mbt"):
        for found in glob.glob(str(ROOT / pattern)):
            rel = os.path.relpath(found, ROOT).replace(os.sep, "/")
            if rel.startswith(SKIP_DIRS):
                continue
            if "_wbtest." in rel or "_test." in rel:
                continue
            out.add(rel)
    return out


named = listed()
dead = [n for n in named if not (ROOT / n).exists()]
missing = sorted(sources() - set(named))

for n in dead:
    print(f"section points at a file that is gone: {n}")
for n in missing:
    print(f"source with no section: {n}")
if dead or missing:
    sys.exit(1)
print(f"{len(named)} files, all documented, all present")
