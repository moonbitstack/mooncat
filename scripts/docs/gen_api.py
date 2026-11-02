#!/usr/bin/env python3
"""Generate docs/api.html from the interfaces the compiler wrote.

`moon info` leaves a `pkg.generated.mbti` beside every package: the authority on
what is public, including type parameters. The prose comes from the `///` blocks
in the sources, keyed by the name on the declaration that follows them.

Nothing is listed by hand, so an item added to a package appears in the page on
the next run, and one that is removed cannot linger. `scripts/docs/check_docs.py`
checks that from the other side: it walks the .mbti files and fails if any
public item is missing from the page.

    python scripts/docs/gen_api.py
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "src"
OUT = ROOT / "docs" / "api.html"

# The order the packages are read in, and one sentence each. Everything else on
# the page is generated.
PACKAGES = [
    ("moonbitstack/mooncat",
     "The entry points, re-exported: what a program that serves one application needs, and nothing it does not."),
    ("moonbitstack/mooncat/config",
     "The configuration record, the access and error log, and the HTTP date every response can carry."),
    ("moonbitstack/mooncat/lifespan",
     "The lifespan protocol: an application invoked once before the listener binds and once on the way out."),
    ("moonbitstack/mooncat/proxy",
     "The client and scheme a trusted proxy reports, and the decision to believe it."),
    ("moonbitstack/mooncat/serve",
     "The accept loop, HTTP/1.1, HTTP/2, WebSocket, TLS, workers and the graceful shutdown."),
    ("moonbitstack/mooncat/cli",
     "The command line as a set of flags, and run(app) as a whole server program."),
    ("moonbitstack/mooncat/quic",
     "HTTP/3: the UDP socket, the datagram loop that routes by connection ID, and the request streams."),
]

KIND = {
    "fn": "fn",
    "let": "let",
    "struct": "struct",
    "enum": "enum",
    "suberror": "error",
    "impl": "impl",
    "using": "alias",
}


def package_dir(name):
    """Where a package's sources live, from its declared name."""
    tail = name.split("mooncat", 1)[1].strip("/")
    return SRC / tail if tail else SRC


def read_text(path):
    return path.read_text(encoding="utf-8")


def doc_comments(pkg_path):
    """Every `///` block in a package, keyed by the declaration it introduces."""
    docs = {}
    for mbt in sorted(list(pkg_path.glob("*.mbt")) + list(pkg_path.glob("*/*.mbt"))):
        if "_test." in mbt.name or "_wbtest." in mbt.name:
            continue
        lines = read_text(mbt).splitlines()
        block = []
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped == "///|":
                block = []
                continue
            if stripped.startswith("///"):
                block.append(stripped[3:].lstrip())
                continue
            if not stripped:
                continue
            if stripped.startswith("pub ") and block:
                key = declared_name(stripped)
                if key and key not in docs:
                    docs[key] = "\n".join(block).strip()
            block = []
    return docs


def declared_name(line):
    """The name a `pub` declaration introduces, as the page keys its docs by."""
    line = re.sub(r"^pub(\([a-z]+\))?\s+", "", line)
    line = re.sub(r"^(async|extern)\s+", "", line)
    if line.startswith("fn "):
        head = line[3:].split("(")[0].strip()
        return head
    if line.startswith("let "):
        return line[4:].split(":")[0].strip()
    match = re.match(r"(struct|enum|suberror|type|trait)\s+([A-Za-z0-9_]+)", line)
    if match:
        return match.group(2)
    return None


def parse_interface(path):
    """The .mbti as items, in the sections the compiler grouped them under."""
    sections = {}
    section = None
    lines = read_text(path).splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()
        if line.startswith("// "):
            section = line[3:].strip()
            sections.setdefault(section, [])
            i += 1
            continue
        if not line.startswith("pub "):
            i += 1
            continue
        if section is None:
            section = "Values"
            sections.setdefault(section, [])
        # A type block: its body holds the fields, the variants and the methods.
        if line.endswith("{"):
            head = line[:-1].strip()
            body = []
            depth = 1
            i += 1
            while i < len(lines) and depth > 0:
                inner = lines[i]
                depth += inner.count("{") - inner.count("}")
                if depth > 0:
                    body.append(inner)
                i += 1
            sections[section].append(parse_block(head, body))
            continue
        sections[section].append({"kind": "", "sig": line, "body": [], "methods": []})
        i += 1
    for items in sections.values():
        for item in items:
            if not item["kind"]:
                item["kind"] = item_kind(item["sig"])
    return sections


def parse_block(head, body):
    fields, methods = [], []
    for inner in body:
        stripped = inner.strip()
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("pub "):
            methods.append(stripped)
        elif not stripped.startswith("}"):
            fields.append(re.sub(r"\s*//.*$", "", stripped))
    return {"kind": item_kind(head), "sig": head, "body": fields, "methods": methods}


def item_kind(sig):
    rest = re.sub(r"^pub(\([a-z]+\))?\s+", "", sig)
    rest = re.sub(r"^(async|extern)\s+", "", rest)
    if rest.startswith("fn "):
        return "fn"
    if rest.startswith("let "):
        return "let"
    if rest.startswith("struct "):
        return "struct"
    if rest.startswith("enum "):
        return "enum"
    if rest.startswith("suberror "):
        return "suberror"
    if rest.startswith("impl "):
        return "impl"
    if rest.startswith("using "):
        return "using"
    if rest.startswith("type "):
        return "type"
    if rest.startswith("trait "):
        return "trait"
    return "item"


def method_name(sig):
    match = re.search(r"\bfn\s+([A-Za-z0-9_]+::)?([A-Za-z0-9_]+)\s*[(<]", sig)
    if not match:
        return None
    return (match.group(1) or "") + match.group(2)


def item_name(item):
    return method_name(item["sig"]) or declared_name(item["sig"]) or ""


# ------------------------------------------------------------------ rendering

def inline(text):
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def render_doc(doc):
    """`///` prose to HTML: paragraphs, lists and fenced MoonBit, no HTML in."""
    if not doc:
        return ""
    out, para, items, fence = [], [], [], None
    for line in doc.splitlines():
        if line.strip().startswith("```"):
            if fence is None:
                if para:
                    out.append("<p>%s</p>" % inline(" ".join(para)))
                    para = []
                if items:
                    out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(i) for i in items))
                    items = []
                fence = []
            else:
                out.append("<pre>%s</pre>" % html.escape("\n".join(fence)))
                fence = None
            continue
        if fence is not None:
            fence.append(line)
            continue
        stripped = line.strip()
        if not stripped:
            if para:
                out.append("<p>%s</p>" % inline(" ".join(para)))
                para = []
            if items:
                out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(i) for i in items))
                items = []
            continue
        if stripped.startswith("- "):
            if para:
                out.append("<p>%s</p>" % inline(" ".join(para)))
                para = []
            items.append(stripped[2:])
            continue
        if items:
            out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(i) for i in items))
            items = []
        para.append(stripped)
    if fence:
        out.append("<pre>%s</pre>" % html.escape("\n".join(fence)))
    if para:
        out.append("<p>%s</p>" % inline(" ".join(para)))
    if items:
        out.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(i) for i in items))
    return "".join(out)


def anchor(pkg, name):
    return re.sub(r"[^A-Za-z0-9_-]+", "-", "%s--%s" % (pkg.rsplit("/", 1)[-1], name)).strip("-")


def reexport_target(sig):
    """`pub using @config {type Config}` -> ('moonbitstack/mooncat/config', 'Config')."""
    match = re.search(r"@([A-Za-z0-9_]+)\s*\{\s*type\s+([A-Za-z0-9_]+)", sig)
    if not match:
        return None
    alias, name = match.group(1), match.group(2)
    for pkg, _ in PACKAGES:
        if pkg.rsplit("/", 1)[-1] == alias or pkg.rsplit("/", 2)[-2:] == [alias]:
            return pkg, name
    return None


def derived_note(name):
    """What produced a method that has no comment of its own."""
    tail = name.rsplit("::", 1)[-1]
    if tail in ("equal", "not_equal"):
        return "From the type's <code>derive(Eq)</code>."
    if tail == "to_repr":
        return "From the type's <code>derive(Debug)</code>."
    if tail in ("to_string", "output"):
        return "From the type's <code>Show</code> implementation."
    return ""


def render_item(pkg, item, docs, out):
    full = item["sig"]
    name = item_name(item)
    doc = docs.get(name, "")
    kind = item["kind"]
    label = KIND.get(kind, kind)
    anchor_id = anchor(pkg, name or html.escape(full)[:24])
    out.append('<details class="item" id="%s" data-item="%s">' % (anchor_id, html.escape(full, quote=True)))
    shown = re.sub(r"^pub(\([a-z]+\))?\s+", "", full)
    out.append('<summary><span class="caret"></span><span class="kind">%s</span>'
               '<span class="sig">%s</span></summary>' % (label, html.escape(shown)))
    out.append('<div class="body">')
    if doc:
        out.append(render_doc(doc))
    elif kind == "using":
        target = reexport_target(full)
        if target:
            where, type_name = target
            out.append('<p class="alias">Re-exported from <code>%s</code>; '
                       '<a href="#%s">documented there</a>.</p>'
                       % (where.replace("moonbitstack/", ""),
                          anchor(where, type_name)))
        else:
            out.append('<p class="alias">Re-exported.</p>')
    if item["body"]:
        fields = "\n".join(item["body"])
        out.append('<pre class="fields">%s</pre>' % html.escape(fields))
    for method in item["methods"]:
        mname = method_name(method)
        mdoc = docs.get(mname or "", "")
        out.append('<p class="meth"><code>%s</code>%s</p>'
                   % (html.escape(method),
                      (" — " + inline(mdoc)) if mdoc else (" — " + derived_note(mname or "") if derived_note(mname or "") else "")))
    if not doc and not item["body"] and not item["methods"] and kind != "using":
        note = derived_note(name) or ("From the <code>Show</code> implementation." if kind == "impl" else "")
        if note:
            out.append('<p class="alias">%s</p>' % note)
        else:
            out.append('<p class="nobody">No documentation comment in the source.</p>')
    out.append("</div></details>")


TABS = """<nav class="tabs" aria-label="Pages">
    <div class="wrap">
      <a href="./index.html">Home</a>
      <a href="./guide.html">Guide</a>
      <a href="./api.html" aria-current="page">API reference</a>
      <a href="./playground.html">Playground</a>
      <a class="gh" href="https://github.com/moonbitstack/mooncat">GitHub</a>
    </div>
  </nav>"""


def main():
    found = []
    for name, desc in PACKAGES:
        path = package_dir(name)
        mbti = path / "pkg.generated.mbti"
        if not mbti.exists():
            print("no interface for %s — run moon info" % name, file=sys.stderr)
            return 1
        found.append((name, desc, parse_interface(mbti), doc_comments(path)))

    index = read_text(ROOT / "docs" / "index.html")
    head = index.split('<main id="middle">')[0]
    head = re.sub(r"<title>.*?</title>", "<title>API reference — mooncat</title>", head, flags=re.S)
    head = re.sub(r'<meta name="description" content="[^"]*">',
                  '<meta name="description" content="Every public type, function, constant and method of '
                  'mooncat, generated from the package interfaces.">', head, count=1)
    head = re.sub(r'<nav class="tabs".*?</nav>', TABS, head, flags=re.S)

    total = 0
    body = ['<main id="middle">']
    body.append('<aside id="side"><div class="grp"><h2>Packages</h2><ul>')
    for name, desc, sections, docs in found:
        count = sum(len(v) for v in sections.values())
        body.append('<li><a href="#%s">%s (%d)</a></li>'
                    % (name.replace("/", "-"), name.replace("moonbitstack/", ""), count))
    body.append('</ul></div>')
    body.append('<div class="grp"><h2>mooncat</h2><ul>'
                '<li><a href="./index.html">Home</a></li>'
                '<li><a href="./playground.html">Playground</a></li>'
                '<li><a href="./api.html">API reference</a></li>'
                '</ul></div>')
    body.append('<div class="grp"><h2>Elsewhere</h2><ul>'
                '<li><a href="https://github.com/moonbitstack/mooncat">GitHub</a></li>'
                '<li><a href="https://moonbitstack.github.io/mooncat/">Docs</a></li>'
                '</ul></div></aside>')

    body.append('<div class="content">')
    body.append('<h1>API reference</h1>')
    body.append('<p class="lede">Every public item of every package, in the order the compiler lists them. '
                'Generated from the package interfaces by <code>scripts/docs/gen_api.py</code>; the prose is the '
                '<code>///</code> comment beside each declaration.</p>')

    for name, desc, sections, docs in found:
        count = sum(len(v) for v in sections.values())
        total += count
        short = name.replace("moonbitstack/", "")
        body.append('<section class="section pkg" id="%s">' % name.replace("/", "-"))
        body.append('<h2 class="bar">%s<span class="aside">%d items</span></h2>' % (short, count))
        body.append('<p class="pkg-desc">%s</p>' % desc)
        for section, items in sections.items():
            if not items:
                continue
            body.append('<h3 class="bar">%s</h3>' % html.escape(section))
            for item in items:
                render_item(name, item, docs, body)
        body.append('</section>')

    body.append('<p class="api-count">%d public items across %d packages.</p>' % (total, len(found)))
    body.append('<div class="pager"><a href="./playground.html">← Playground</a><a href="./index.html">Home →</a></div>')
    body.append('</div></main>')

    footer_tail = index.split("</main>", 1)[1]
    page = head + "\n".join(body) + footer_tail
    OUT.write_text(page, encoding="utf-8", newline="\n")
    print("wrote %s (%d public items in %d packages)" % (OUT.relative_to(ROOT), total, len(found)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
