#!/usr/bin/env python3
"""No two tests bind the same port.

Tests run in parallel, so a port written twice is a race: locally the two
rarely overlap and both pass, on a loaded CI runner one gets
`Address already in use`. Four numbers were shared when this was written, and
the suite had been green for weeks. Run from the repository root:

    python scripts/check_ports.py
"""
import collections
import glob
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "src"
# A server binds with `port=N` or `Config::new(port=N, ...)`; a client reaches
# it by URL. Only the binding side can collide.
BIND = re.compile(r"port=(\d{4,5})")


def sources():
    for pattern in ("*.mbt", "*/*.mbt"):
        for found in glob.glob(str(ROOT / pattern)):
            rel = os.path.relpath(found, ROOT).replace(os.sep, "/")
            if rel.startswith(("_build/", ".mooncakes/", "examples/")):
                continue
            yield rel


where = collections.defaultdict(list)
for rel in sources():
    for n, line in enumerate((ROOT / rel).read_text(encoding="utf-8").splitlines(), 1):
        for port in BIND.findall(line):
            where[port].append(f"{rel}:{n}")

clashes = {port: at for port, at in where.items() if len(at) > 1}
for port, at in sorted(clashes.items()):
    print(f"port {port} is bound in {len(at)} places: {', '.join(at)}")
if clashes:
    sys.exit(1)
print(f"{len(where)} ports, each bound once")
