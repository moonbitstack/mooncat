#!/usr/bin/env python3
"""The checks the documentation site has to pass.

Four of them, each one something that has gone wrong on a site before:

  * the API page lists every public item of every package, and nothing that no
    package declares — read out of each `pkg.generated.mbti`, which is the
    compiler's own answer, so an item added to a package cannot be forgotten and
    one removed cannot linger;
  * every page carries the same page-level navigation, in the same order, has a
    favicon, a title, and the way back to the repository;
  * the pages the site is meant to have are there;
  * no `scrollbar-width` or `scrollbar-color` is set outside the branch for
    browsers without `::-webkit-scrollbar`. Inside the other branch it would
    silently turn off every custom scrollbar in Chrome.

    python scripts/docs/check_docs.py
"""
import html
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gen_api import PACKAGES  # the page's package list, and the order it renders in

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DOCS = ROOT / "docs"
SRC = ROOT / "src"

PAGES = ["index.html", "guide.html", "api.html", "playground.html"]
FALLBACK = "not selector(::-webkit-scrollbar)"
FAILED = []


def fail(message):
    FAILED.append(message)
    print("  x " + message)


def normalise(text):
    return " ".join(html.unescape(text).split())


# Packages that are deliberately not part of the reference. The banner is a
# feature a program asks for, not an interface it programs against.
UNDOCUMENTED = {"moonbitstack/mooncat/logo"}


def interfaces():
    """Every package's interface, examples aside: those are programs, not an API."""
    found = {}
    for path in sorted(SRC.rglob("pkg.generated.mbti")):
        if path.relative_to(SRC).parts[0] == "examples":
            continue
        text = path.read_text(encoding="utf-8")
        declared = re.search(r'^package "([^"]+)"', text, re.M)
        if not declared:
            continue
        found[declared.group(1)] = [normalise(line).rstrip("{").strip()
                                    for line in text.splitlines()
                                    if line.strip().startswith("pub ")]
    return found


def check_api(items):
    documented = dict(PACKAGES)
    for package in documented:
        if package not in items:
            fail("gen_api.py names %s, which has no interface" % package)
    for package in items:
        if package not in documented and package not in UNDOCUMENTED:
            fail("%s is a package the reference neither documents nor skips" % package)
    items = {k: v for k, v in items.items() if k in documented}

    page = DOCS / "api.html"
    if not page.exists():
        fail("docs/api.html is missing - run scripts/docs/gen_api.py")
        return
    raw = page.read_text(encoding="utf-8")
    text = normalise(raw)
    listed = set(normalise(item) for item in re.findall(r'data-item="([^"]+)"', raw))

    missing = 0
    for package, signatures in items.items():
        for signature in signatures:
            if signature not in text:
                missing += 1
                if missing <= 10:
                    fail("%s: not on the API page: %s" % (package, signature[:90]))
        if 'id="%s"' % package.replace("/", "-") not in raw:
            fail("%s has no section on the API page" % package.replace("moonbitstack/", ""))
    if missing > 10:
        fail("... and %d more items missing" % (missing - 10))

    known = set()
    for signatures in items.values():
        known.update(signatures)
    for item in sorted(listed - known):
        fail("the API page lists something no package declares: %s" % item[:90])

    print("  api: %d packages, %d public items, %d listed in the page"
          % (len(items), sum(len(v) for v in items.values()), len(listed)))


def tabs(page):
    text = page.read_text(encoding="utf-8")
    nav = re.search(r'<nav class="tabs".*?</nav>', text, re.S)
    if not nav:
        return None
    return [(normalise(re.sub(r"<[^>]+>", "", label)), link)
            for link, label in re.findall(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', nav.group(0), re.S)]


def check_pages():
    reference = None
    seen = 0
    for name in PAGES:
        page = DOCS / name
        if not page.exists():
            fail("docs/%s is missing" % name)
            continue
        seen += 1
        text = page.read_text(encoding="utf-8")
        found = tabs(page)
        if not found:
            fail("%s has no page navigation" % name)
        elif reference is None:
            reference = (name, found)
        elif found != reference[1]:
            fail("%s navigates differently from %s" % (name, reference[0]))
        for needle, complaint in (('rel="icon"', "no favicon"),
                                  ("github.com/moonbitstack/mooncat", "no link back to the repository"),
                                  ("<title>", "no title")):
            if needle not in text:
                fail("%s has %s" % (name, complaint))
    if reference:
        print("  pages: %d, the same %d navigation links on each" % (seen, len(reference[1])))


def at_rule_blocks(text):
    """Every @supports block, as (header, start, end) over the whole stylesheet."""
    for match in re.finditer(r"@supports([^{]*)\{", text):
        depth = 1
        i = match.end()
        while depth and i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        yield match.group(1), match.end(), i


def check_scrollbars():
    css = DOCS / "assets" / "site.css"
    if not css.exists():
        fail("docs/assets/site.css is missing")
        return
    text = css.read_text(encoding="utf-8")
    fallback = [(start, end) for header, start, end in at_rule_blocks(text)
                if FALLBACK in header]
    if not fallback:
        fail("site.css has no '@supports not selector(::-webkit-scrollbar)' branch")
        return
    for match in re.finditer(r"(?<![\w-])(scrollbar-width|scrollbar-color)\s*:", text):
        line = text.count("\n", 0, match.start()) + 1
        if not any(start <= match.start() < end for start, end in fallback):
            fail("site.css:%d sets %s outside the fallback branch"
                 % (line, match.group(1)))
            return
    print("  scrollbars: every scrollbar-width/color is inside the fallback branch")


def main():
    items = interfaces()
    check_api(items)
    check_pages()
    check_scrollbars()
    if FAILED:
        print("%d problem(s)" % len(FAILED))
        return 1
    print("the site agrees with the sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
