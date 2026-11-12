#!/usr/bin/env python3
"""The version the command line prints is the version in `moon.mod`.

Nothing in a running binary knows which version it was compiled from: the
compiler does not carry the manifest into it. `@cli.command` therefore holds a
copy of the number for `--version`, and a copy is wrong the moment the manifest
moves. This check is what keeps the two together.

    python scripts/checks/check_version.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
MANIFEST = re.compile(r'^version\s*=\s*"([^"]+)"', re.MULTILINE)
DEFAULT = re.compile(r'pub fn command\(version~ : String = "([^"]+)"\)')

manifest = MANIFEST.search((ROOT / "moon.mod").read_text(encoding="utf-8"))
if manifest is None:
    print("moon.mod has no version")
    sys.exit(1)
declared = manifest.group(1)

source = (ROOT / "src" / "cli" / "cli.mbt").read_text(encoding="utf-8")
default = DEFAULT.search(source)
if default is None:
    print("src/cli/cli.mbt no longer declares command(version~ : String = ...)")
    sys.exit(1)

if default.group(1) != declared:
    print(
        f"moon.mod is {declared} but --version would print {default.group(1)};"
        " the default of command(version~) has to follow the manifest"
    )
    sys.exit(1)
print(f"--version prints {declared}, the version in moon.mod")
