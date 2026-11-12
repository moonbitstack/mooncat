#!/usr/bin/env python3
"""No test picks the port it listens on.

Tests run in parallel, so a number written twice is a race: locally the two rarely overlap and
both pass, on a loaded CI runner one of them gets `Address already in use`. Four numbers were
shared when this was first checked, and the suite had been green for weeks. Asking for port 0 and
reading the real one back from the listener takes the number out of the test entirely — that is
what `@serve.Listening` is for.

What this refuses:

- `port=<number>` anywhere under `src/` outside `examples/`. The command line's own tests parse a
  port rather than bind one, so `src/cli` is left out.
- an address literal naming a port, `"127.0.0.1:8080"`, `"localhost:8080"`, `"0.0.0.0:8080"`: a
  client that connects to one only works because something else bound it.
- a serving entry point handed a `Config` that does not say `port=0` in the same line: the default
  is 12000, which collides with anything else on the machine — a stray example server was enough
  to fail the test that was written this way.

    python scripts/checks/check_ports.py
"""
import glob
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent / "src"
BIND = re.compile(r"\bport\s*=\s*(\d+)")
ADDRESS = re.compile(r'"(?:127\.0\.0\.1|localhost|0\.0\.0\.0):(\d+)"')
# A serving entry point handed a literal `Config` in one line: the default port is 12000, which is
# a number written down as surely as `port=12000`, and nothing in the line says so. The entry
# points themselves are the exception — they are handed `port~`.
SERVES = ("serve(", "serve_config(", "serve_h2c", "serve_tls", "serve_graceful(")
DEFAULTED = re.compile(r"Config::new\((?![^)]*port\s*[=~])")


def sources():
    for pattern in ("*.mbt", "*/*.mbt"):
        for found in glob.glob(str(ROOT / pattern)):
            rel = os.path.relpath(found, ROOT).replace(os.sep, "/")
            if rel.startswith(("_build/", ".mooncakes/", "examples/", "cli/")):
                continue
            yield rel


found = []
for rel in sources():
    for n, line in enumerate((ROOT / rel).read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        for number in BIND.findall(line):
            if int(number) != 0:
                found.append(f"{rel}:{n} binds port {number}")
        for number in ADDRESS.findall(line):
            if int(number) != 0:
                found.append(f"{rel}:{n} connects to port {number}")
        if any(call in line for call in SERVES) and DEFAULTED.search(line):
            found.append(
                f"{rel}:{n} serves a Config that does not ask for port 0,"
                " so it takes the default 12000"
            )

for one in found:
    print(one)
if found:
    print(f"{len(found)} places pick a port; ask for 0 and read the one you were given")
    sys.exit(1)
print("every listener a test starts asks for port 0")
