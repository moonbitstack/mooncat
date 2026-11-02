#!/usr/bin/env python3
"""Build the index the search box reads.

One entry per section of every page: the heading, the first few hundred
characters under it, and the page it lives on. Written from the pages
themselves, so a section that is added or renamed is searchable on the next run
and one that is removed cannot be found any more.

    python scripts/docs/gen_search.py
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DOCS = ROOT / "docs"
OUT = DOCS / "assets" / "search-index.js"

PAGE_NAMES = {
    ("en", "index.html"): "Home",
    ("en", "guide.html"): "Guide",
    ("en", "api.html"): "API reference",
    ("en", "playground.html"): "Playground",
    ("zh", "index.html"): "首页",
    ("zh", "guide.html"): "指南",
    ("zh", "api.html"): "API 参考",
    ("zh", "playground.html"): "演示",
}

TEXT_LIMIT = 260


def plain(fragment):
    text = re.sub(r"<script.*?</script>", " ", fragment, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return " ".join(text.split())


def entries_for(lang, path):
    page = PAGE_NAMES.get((lang, path.name), path.name)
    body = path.read_text(encoding="utf-8")
    body = body.split('<div class="content">', 1)[-1]
    body = body.split("</main>", 1)[0]

    url = path.name if lang == "en" else "zh/" + path.name
    found = []

    title = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
    if title:
        found.append({
            "lang": lang,
            "page": page,
            "url": url,
            "heading": plain(title.group(1)),
            "text": "",
        })

    for match in re.finditer(r'<section class="section[^"]*" id="([^"]+)">(.*?)</section>', body, re.S):
        anchor, block = match.group(1), match.group(2)
        heading = re.search(r"<h[23][^>]*>(.*?)</h[23]>", block, re.S)
        if not heading:
            continue
        text = plain(block[heading.end():])[:TEXT_LIMIT]
        found.append({
            "lang": lang,
            "page": page,
            "url": url + "#" + anchor,
            "heading": plain(heading.group(1)),
            "text": text,
        })
    return found


def main():
    entries = []
    for lang, folder in (("en", DOCS), ("zh", DOCS / "zh")):
        for name in ("index.html", "guide.html", "api.html", "playground.html"):
            path = folder / name
            if not path.exists():
                print("missing docs/%s%s" % ("" if lang == "en" else "zh/", name), file=sys.stderr)
                return 1
            entries += entries_for(lang, path)

    if not entries:
        print("no sections found — the extraction is broken", file=sys.stderr)
        return 1

    import json

    body = ("/* Written by scripts/docs/gen_search.py from the pages themselves.\n"
            "   Regenerate rather than edit. */\n"
            "window.SEARCH = " + json.dumps(entries, ensure_ascii=False, indent=1) + ";\n")
    OUT.write_text(body, encoding="utf-8", newline="\n")
    print("wrote %s (%d sections)" % (OUT.relative_to(ROOT), len(entries)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
