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

PAGES = {
    "en": ["index.html", "guide.html", "api.html", "playground.html"],
    "zh": ["zh/index.html", "zh/guide.html", "zh/api.html", "zh/playground.html"],
}
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
        parts = path.relative_to(SRC).parts
        if parts[0] == "examples" or "snippets-check" in parts:
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
    documented = {name: desc for name, desc, _zh in PACKAGES}
    for package in documented:
        if package not in items:
            fail("gen_api.py names %s, which has no interface" % package)
    for package in items:
        if package not in documented and package not in UNDOCUMENTED:
            fail("%s is a package the reference neither documents nor skips" % package)
    items = {k: v for k, v in items.items() if k in documented}

    listed = 0
    for page in (DOCS / "api.html", DOCS / "zh" / "api.html"):
        listed = check_api_page(page, items, documented) or listed
    total = sum(len(v) for v in items.values())
    print("  api: %d packages, %d public items, %d listed per page"
          % (len(items), total, listed))


def check_api_page(page, items, documented):
    if not page.exists():
        fail("%s is missing - run scripts/docs/gen_api.py" % page.relative_to(ROOT))
        return
    raw = page.read_text(encoding="utf-8")

    # The page is built from the home page's chrome. When that split went
    # wrong the whole home page ended up above the reference and nothing else
    # noticed, so the shape is checked first.
    for told, want in (('<main', 1), ('<article class="content">', 1), ('class="hero"', 0),
                       ('class="search"', 1)):
        got = raw.count(told)
        if got != want:
            fail("%s has %d of %s, expected %d"
                 % (page.relative_to(ROOT), got, told, want))

    listed = set(normalise(item) for item in re.findall(r'data-item="([^"]+)"', raw))

    # Each package against its own section: a name that appears in two packages —
    # `port` is in both the root and `config` — must be in both places, not once.
    sections = {}
    for key, body in re.findall(r'<section class="section pkg" id="([^"]+)">(.*?)</section>',
                                raw, re.S):
        sections[key] = normalise(body)

    missing = 0
    for package, signatures in items.items():
        key = package.replace("/", "-")
        body = sections.get(key)
        if body is None:
            fail("%s has no section on the API page" % package.replace("moonbitstack/", ""))
            continue
        for signature in signatures:
            if signature not in body:
                missing += 1
                if missing <= 10:
                    fail("%s: not in its section: %s" % (package, signature[:90]))
    if missing > 10:
        fail("... and %d more items missing" % (missing - 10))

    known = set()
    for signatures in items.values():
        known.update(signatures)
    for item in sorted(listed - known):
        fail("the API page lists something no package declares: %s" % item[:90])

    return len(listed)


def rail(page):
    """The left rail's own links: the four pages, plus the guide's sections."""
    text = page.read_text(encoding="utf-8")
    side = re.search(r'<nav id="side".*?</nav>', text, re.S)
    if not side:
        return None
    return [(normalise(re.sub(r"<[^>]+>", "", label)), link)
            for link, label in re.findall(r'<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', side.group(0), re.S)]


def check_pages():
    seen = 0
    for lang, names in PAGES.items():
        reference = None
        other = "zh" if lang == "en" else "en"
        for name in names:
            page = DOCS / name
            if not page.exists():
                fail("docs/%s is missing" % name)
                continue
            seen += 1
            text = page.read_text(encoding="utf-8")
            # There is no strip of tabs under the header: the rail is the only
            # navigation, as it is on the site this one follows. Every page
            # must reach the other three from it, and no page may grow the
            # strip back.
            if 'class="tabs"' in text:
                fail("%s has the tab strip back" % name)
            found = rail(page)
            if not found:
                fail("%s has no links in its side rail" % name)
            else:
                known = set(link.lstrip("./").split("#")[0] for _label, link in found)
                for target in ("index.html", "guide.html", "api.html", "playground.html"):
                    if target not in known:
                        fail("%s cannot reach %s from the rail" % (name, target))
            for needle, complaint in (('rel="icon"', "no favicon"),
                                      ('id="search-form"', "no search box"),
                                      ("github.com/moonbitstack/mooncat", "no link back to the repository"),
                                      ('class="lang"', "no language switch"),
                                      ('class="i-sun"', "no sun in the theme button"),
                                      ('class="i-moon"', "no moon in the theme button"),
                                      ("<title>", "no title")):
                if needle not in text:
                    fail("%s has %s" % (name, complaint))
            # One button that names the other language and goes there, the
            # way the theme button names the other theme. Both the page it
            # points at and the word on it are checked, because a switch that
            # says EN and stays put is worse than no switch at all.
            switches = re.findall(r'<a class="lang"[^>]*href="([^"]+)"[^>]*>([^<]+)</a>', text)
            if len(switches) != 1:
                fail("%s has %d language switches, expected one"
                     % (name, len(switches)))
                continue
            href, label = switches[0]
            want = name.replace("zh/", "") if lang == "zh" else "zh/" + name
            if href.lstrip("./") != want:
                fail("%s switches to %s, not %s" % (name, href, want))
            if label.strip().upper() != other.upper():
                fail("%s labels its switch %s, not %s" % (name, label.strip(), other.upper()))

            order = [text.find('class="lang"'), text.find('id="theme"'),
                     text.find("github.com/moonbitstack/mooncat")]
            if order != sorted(order) or -1 in order:
                fail("%s orders its header controls wrongly: language, theme, repository" % name)
    if seen:
        print("  pages: %d across two languages, no tab strip, rail reaches all four" % seen)

    # The page a wrong address lands on: same chrome, a way home in both
    # languages, and no fourth page pretending to be real.
    gone = DOCS / "404.html"
    if not gone.exists():
        fail("docs/404.html is missing")
        return
    text = gone.read_text(encoding="utf-8")
    for needle, complaint in (('href="./index.html"', "no way home"),
                              ('href="./zh/index.html"', "no way to the Chinese pages"),
                              ("<title>", "no title")):
        if needle not in text:
            fail("404.html has %s" % complaint)


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


def check_assets():
    """Every file a page points at is a file: the marks come in six cuts and a
    typo in one of them is a broken image nobody notices until a visitor does."""
    seen = 0
    for page in sorted(DOCS.rglob("*.html")):
        if page.name.startswith("_"):
            continue
        text = page.read_text(encoding="utf-8")
        for path in re.findall(
                r'(?:src|href|data-[a-z-]+)="([^"#?:]+\.(?:png|js|css|ico|svg))"', text):
            if path.startswith(("http", "//")):
                continue
            seen += 1
            if not (page.parent / path).resolve().exists():
                fail("%s points at %s, which is not there"
                     % (page.relative_to(DOCS).as_posix(), path))
    print("  assets: %d references, all present" % seen)


def check_search():
    index = DOCS / "assets" / "search-index.js"
    if not index.exists():
        fail("docs/assets/search-index.js is missing - run scripts/docs/gen_search.py")
        return
    text = index.read_text(encoding="utf-8")
    found = re.search(r"window\.SEARCH = (\[.*?\]);", text, re.S)
    if not found:
        fail("the search index is not parseable")
        return
    import json

    entries = json.loads(found.group(1))
    pages = set(e["url"].split("#")[0] for e in entries)
    for lang, names in PAGES.items():
        for name in names:
            want = name if lang == "en" else name.replace("zh/", "")
            if want not in pages:
                fail("the search index has nothing for %s" % name)
    print("  search: %d sections over %d pages" % (len(entries), len(pages)))


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
    check_assets()
    check_search()
    check_scrollbars()
    if FAILED:
        print("%d problem(s)" % len(FAILED))
        return 1
    print("the site agrees with the sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
