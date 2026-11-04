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
     "The entry points, re-exported: what a program that serves one application needs, and nothing it does not.",
     "入口函数的重导出：服务一个应用需要的东西，不多一样。"),
    ("moonbitstack/mooncat/config",
     "The configuration record, the access and error log, and the HTTP date every response can carry.",
     "配置记录、访问与错误日志，以及每个响应可以带的 HTTP 日期。"),
    ("moonbitstack/mooncat/lifespan",
     "The lifespan protocol: an application invoked once before the listener binds and once on the way out.",
     "lifespan 协议：应用在监听前被调用一次，退出前再一次。"),
    ("moonbitstack/mooncat/proxy",
     "The client and scheme a trusted proxy reports, and the decision to believe it.",
     "受信代理报告的客户端与 scheme，以及要不要相信它。"),
    ("moonbitstack/mooncat/serve",
     "The accept loop, HTTP/1.1, HTTP/2, WebSocket, TLS, workers and the graceful shutdown.",
     "接受循环、HTTP/1.1、HTTP/2、WebSocket、TLS、多 worker 与优雅停机。"),
    ("moonbitstack/mooncat/cli",
     "The command line as a set of flags, and run(app) as a whole server program.",
     "命令行参数，以及把 run(app) 当作完整的服务器程序。"),
    ("moonbitstack/mooncat/quic",
     "HTTP/3: the UDP socket, the datagram loop that routes by connection ID, and the request streams.",
     "HTTP/3：UDP 套接字、按连接 ID 分发的数据报循环，以及请求流。"),
]

SECTIONS_ZH = {
    "Values": "值",
    "Errors": "错误",
    "Types and methods": "类型与方法",
    "Type aliases": "类型别名",
    "Traits": "Trait",
}

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
            if not stripped or stripped.startswith("#"):
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
    for pkg, *_ in PACKAGES:
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


LANG = {
    "en": {
        "dir": "",
        "file": "docs/api.html",
        "title": "API reference — mooncat",
        "desc": "Every public type, function, constant and method of mooncat, "
                "generated from the package interfaces.",
        "h1": "API reference",
        "lede": "Every public item of every package, in the order the compiler lists them. "
                "Generated from the package interfaces by <code>scripts/docs/gen_api.py</code>; "
                "the prose is the <code>///</code> comment beside each declaration.",
        "rail": "Documentation navigation",
        "packages": "Packages",
        "mooncat": ("Mooncat", [("index.html", "Home"), ("playground.html", "Playground")]),
        "documentation": ("Documentation", [("guide.html", "Guide"), ("api.html", "API reference")]),
        "download": ("Download", [("https://mooncakes.io/docs/moonbitstack/mooncat", "mooncakes")]),
        "problems": ("Problems?", [("https://github.com/moonbitstack/mooncat/issues", "Issues")]),
        "items": "%d items",
        "count": "%d public items across %d packages.",
        "lang_href": "./zh/api.html",
        "lang_label": "ZH",
        "lang_title": "中文",
        "prev": "← Playground",
        "next": "Home →",
        "search": "Search the documentation",
        "placeholder": "Search...",
        "footer": "mooncat — Apache-2.0. The API page is generated from the source tree.",
    },
    "zh": {
        "dir": "zh/",
        "file": "docs/zh/api.html",
        "title": "API 参考 — mooncat",
        "desc": "mooncat 的全部公开类型、函数、常量与方法，由包接口生成。",
        "h1": "API 参考",
        "lede": "每个包的全部公开项，顺序照编译器的列法。由 <code>scripts/docs/gen_api.py</code> "
                "从包接口生成；说明文字来自声明旁的 <code>///</code> 注释。",
        "rail": "文档导航",
        "packages": "包",
        "mooncat": ("Mooncat", [("index.html", "首页"), ("playground.html", "演示")]),
        "documentation": ("文档", [("guide.html", "指南"), ("api.html", "API 参考")]),
        "download": ("下载", [("https://mooncakes.io/docs/moonbitstack/mooncat", "mooncakes")]),
        "problems": ("问题？", [("https://github.com/moonbitstack/mooncat/issues", "议题")]),
        "items": "%d 项",
        "count": "共 %d 个公开项，分属 %d 个包。",
        "lang_href": "../api.html",
        "lang_label": "EN",
        "lang_title": "English",
        "prev": "← 演示",
        "next": "首页 →",
        "search": "搜索文档",
        "placeholder": "搜索…",
        "footer": "mooncat — Apache-2.0。API 页面由源码树生成。",
    },
}


def group(title, links, current=None):
    out = ['  <div class="grp">', "    <h2>%s</h2>" % title, "    <ul>"]
    for href, text in links:
        mark = ' aria-current="page"' if href == current else ""
        out.append('      <li><a href="%s"%s>%s</a></li>' % (href, mark, text))
    out += ["    </ul>", "  </div>"]
    return "\n".join(out)


def write_page(lang, found):
    labels = LANG[lang]
    index = read_text(ROOT / "docs" / labels["dir"] / "index.html")
    # Everything above the body of the page: split on the tag, whatever
    # attributes it has grown, or the whole home page would be taken for the
    # chrome and copied into the reference.
    head = re.split(r'<main id="middle"[^>]*>', index)[0]
    head = re.sub(r"<title>.*?</title>", "<title>%s</title>" % labels["title"], head, flags=re.S)
    head = re.sub(r'<meta name="description" content="[^"]*">',
                  '<meta name="description" content="%s">' % labels["desc"], head, count=1)

    # The cards and the canonical link were written for the home page; this is
    # a page of its own, so they have to say so.
    url = "https://moonbitstack.github.io/mooncat/" + labels["dir"].replace("zh/", "zh/") + "api.html"
    head = re.sub(r'<link rel="canonical" href="[^"]*">',
                  '<link rel="canonical" href="%s">' % url, head, count=1)
    head = re.sub(r'<meta property="og:url" content="[^"]*">',
                  '<meta property="og:url" content="%s">' % url, head, count=1)
    head = re.sub(r'(<meta property="og:title" content=")[^"]*(">)',
                  r'\g<1>%s\g<2>' % labels["title"].replace('"', "&quot;"), head, count=1)
    head = re.sub(r'(<meta property="og:description" content=")[^"]*(">)',
                  r'\g<1>%s\g<2>' % labels["desc"].replace('"', "&quot;"), head, count=1)
    head = re.sub(r'(<meta property="og:locale" content=")[^"]*(">)',
                  r'\g<1>%s\g<2>' % ("zh_CN" if lang == "zh" else "en"), head, count=1)
    head = re.sub(r'(<meta name="twitter:title" content=")[^"]*(">)',
                  r'\g<1>%s\g<2>' % labels["title"].replace('"', "&quot;"), head, count=1)
    head = re.sub(r'(<meta name="twitter:description" content=")[^"]*(">)',
                  r'\g<1>%s\g<2>' % labels["desc"].replace('"', "&quot;"), head, count=1)
    # the head is lifted from the home page; the switch has to point here
    head = re.sub(r'<a class="lang"[^>]*>[^<]*</a>',
                  '<a class="lang" href="%s" hreflang="%s" title="%s">%s</a>'
                  % (labels["lang_href"], "zh" if lang == "en" else "en",
                     labels["lang_title"], labels["lang_label"]), head, count=1)

    body = ['<main id="middle" tabindex="-1">',
            '<nav id="side" aria-label="%s">' % labels["rail"]]
    body.append('  <form class="search" id="search-form" role="search">')
    body.append('    <label class="sr-only" for="q">%s</label>' % labels["search"])
    body.append('    <input id="q" type="search" placeholder="%s" autocomplete="off">'
                % labels["placeholder"])
    body.append('    <button type="submit">GO</button>')
    body.append('    <ul class="hits" hidden></ul>')
    body.append("  </form>")
    body.append(group(labels["mooncat"][0], labels["mooncat"][1]))
    body.append("  <div class=\"grp\">")
    body.append("    <h2>%s</h2>" % labels["packages"])
    body.append("    <ul>")
    for name, _desc, _desc_zh, sections, _docs in found:
        count = sum(len(v) for v in sections.values())
        body.append('      <li><a href="#%s">%s (%d)</a></li>'
                    % (name.replace("/", "-"), name.replace("moonbitstack/", ""), count))
    body.append("    </ul>")
    body.append("  </div>")
    body.append(group(labels["documentation"][0], labels["documentation"][1], current="api.html"))
    body.append(group(labels["download"][0], labels["download"][1]))
    body.append(group(labels["problems"][0], labels["problems"][1]))
    body.append("</nav>")

    body.append('<article class="content">')
    shown = "zh" if lang == "zh" else "en"
    up = "../" if lang == "zh" else ""
    body.append('<img class="corner" src="{0}assets/logo/{1}-light.png" data-light="{0}assets/logo/{1}-light.png" '
                'data-dark="{0}assets/logo/{1}-dark.png" data-egg-light="{0}assets/logo/egg-light.png" '
                'data-egg-dark="{0}assets/logo/egg-dark.png" alt="" width="150" height="114">'.format(up, shown))
    body.append("<h1>%s</h1>" % labels["h1"])
    body.append('<p class="lede">%s</p>' % labels["lede"])

    total = 0
    for name, desc, desc_zh, sections, docs in found:
        count = sum(len(v) for v in sections.values())
        total += count
        body.append('<section class="section pkg" id="%s">' % name.replace("/", "-"))
        body.append('<h2 class="bar">%s<span class="aside">%s</span></h2>'
                    % (name.replace("moonbitstack/", ""), labels["items"] % count))
        body.append('<p class="pkg-desc">%s</p>' % (desc_zh if lang == "zh" else desc))
        for section, items in sections.items():
            if not items:
                continue
            title = SECTIONS_ZH.get(section, section) if lang == "zh" else section
            body.append('<h3 class="bar">%s</h3>' % html.escape(title))
            for item in items:
                render_item(name, item, docs, body)
        body.append("</section>")

    body.append('<p class="api-count">%s</p>' % (labels["count"] % (total, len(found))))
    body.append('<div class="pager"><a href="./playground.html">%s</a>'
                '<a href="./index.html">%s</a></div>' % (labels["prev"], labels["next"]))
    body.append("</article></main>")

    tail = index.split("</main>", 1)[1]
    out = pathlib.Path(ROOT / labels["file"])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(head + "\n".join(body) + tail, encoding="utf-8", newline="\n")
    print("wrote %s (%d public items, %d packages)" % (out.relative_to(ROOT), total, len(found)))


def main():
    found = []
    for name, desc, desc_zh in PACKAGES:
        path = package_dir(name)
        mbti = path / "pkg.generated.mbti"
        if not mbti.exists():
            print("no interface for %s — run moon info" % name, file=sys.stderr)
            return 1
        found.append((name, desc, desc_zh, parse_interface(mbti), doc_comments(path)))
    for lang in LANG:
        write_page(lang, found)
    return 0


if __name__ == "__main__":
    sys.exit(main())
