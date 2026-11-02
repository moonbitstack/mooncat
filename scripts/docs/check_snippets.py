#!/usr/bin/env python3
"""Compile every MoonBit snippet the pages and the README show.

A documentation example that does not compile is worse than no example: it
teaches an interface that is not there. The snippets are lifted out of the
pages exactly as a reader would copy them, each becomes a package of its own in
a scratch directory inside the module, and the whole thing is checked once.

What is skipped, and why: shell sessions and recorded terminals are output, not
MoonBit, and the API page's fenced blocks are checked where they live — those
carry `moon test` markers and run as part of the suite.

    python scripts/docs/check_snippets.py

The scratch directory is `src/snippets-check`, removed on the way out even when
the check fails. It is ignored by git.
"""
import html
import pathlib
import shutil
import shutil
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SCRATCH = ROOT / "src" / "snippets-check"

IMPORTS = """import {
  "moonbitstack/mooncat",
  "moonbitstack/mooncat/cli",
  "moonbitstack/mooncat/quic",
  "moonbitstack/moonasgi",
  "moonbitlang/async",
  "moonbitlang/core/env",
  "moonbitlang/core/encoding/utf8",
}

pkgtype(kind: "executable")

warnings = "-29"
"""


def strip_markup(fragment):
    """An HTML fragment to the text a reader selects."""
    text = re.sub(r"<[^>]+>", "", fragment)
    return html.unescape(text).strip("\n")


def from_html(path):
    """The MoonBit blocks of one page, with the caption that introduced each."""
    page = path.read_text(encoding="utf-8")
    found = []
    for match in re.finditer(
        r'<div class="code">\s*<div class="cap">(.*?)</div>\s*<pre>(.*?)</pre>',
        page,
        re.S,
    ):
        caption = strip_markup(match.group(1))
        if not caption.endswith(".mbt"):
            continue
        found.append((caption, strip_markup(match.group(2))))
    return found


def from_readme(path):
    """The ```moonbit blocks of the README."""
    text = path.read_text(encoding="utf-8")
    return [("README.md", body) for body in
            re.findall(r"```(?:moonbit|mbt)\n(.*?)```", text, re.S)]


def wrap(code):
    """A block that is one program stays as it is; statements get a main around them."""
    if re.search(r"\bfn\s+main\b", code):
        return code + "\n"
    body = "".join("  " + line + "\n" for line in code.splitlines())
    return "async fn main {\n" + body + "}\n"


def main():
    snippets = []
    for page in sorted((ROOT / "docs").glob("*.html")):
        snippets += [(page.name, caption, code) for caption, code in from_html(page)]
    snippets += [("README.md", caption, code) for caption, code in from_readme(ROOT / "README.md")]

    if not snippets:
        print("no snippets found — the extraction is broken, not the pages")
        return 1

    shutil.rmtree(SCRATCH, ignore_errors=True)
    SCRATCH.mkdir(parents=True)
    try:
        for index, (where, caption, code) in enumerate(snippets):
            package = SCRATCH / ("%02d" % index)
            package.mkdir(exist_ok=True)
            (package / "moon.pkg").write_text(IMPORTS, encoding="utf-8", newline="\n")
            (package / "main.mbt").write_text(wrap(code), encoding="utf-8", newline="\n")
            print("  %02d  %-14s %s" % (index, where, caption))

        print("checking %d snippets" % len(snippets))
        done = subprocess.run(
            ["moon", "check", "--target", "native"],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        output = (done.stdout or "") + (done.stderr or "")
        if done.returncode != 0:
            print(output)
            print("a snippet does not compile")
            return 1
        print("all %d snippets compile" % len(snippets))
        return 0
    finally:
        shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
