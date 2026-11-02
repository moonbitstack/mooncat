/* Page furniture: the theme switch, the search box, copy buttons, and the rare
   alternate mark. Nothing here draws content of its own. */

(function () {
  "use strict";

  var root = document.documentElement;
  var LANG = root.getAttribute("lang") || "en";
  var BASE = root.getAttribute("data-root") || ".";

  /* ---- theme -------------------------------------------------------- */

  var KEY = "mooncat-theme";

  function system() {
    return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function paint() {
    var t = root.getAttribute("data-theme") || system();
    var btn = document.getElementById("theme");
    if (btn) {
      var other = LANG === "zh"
        ? "切换到" + (t === "dark" ? "浅色" : "深色") + "主题"
        : "Switch to " + (t === "dark" ? "light" : "dark") + " theme";
      btn.setAttribute("aria-label", other);
      btn.setAttribute("title", other);
    }
  }

  try {
    var saved = localStorage.getItem(KEY);
    if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);
  } catch (e) {
    /* storage is optional; the system preference stands in */
  }
  paint();

  var themeBtn = document.getElementById("theme");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var next = (root.getAttribute("data-theme") || system()) === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try {
        localStorage.setItem(KEY, next);
      } catch (e) {
        /* ignore */
      }
      paint();
      window.dispatchEvent(new CustomEvent("mooncat:theme"));
    });
  }

  /* ---- copy buttons -------------------------------------------------- */

  // A live region, so a screen reader hears the copy as well as seeing it.
  var said = document.createElement("p");
  said.className = "sr-only";
  said.setAttribute("role", "status");
  said.setAttribute("aria-live", "polite");
  document.body.appendChild(said);

  function copy(text, btn) {
    var done = function () {
      said.textContent = LANG === "zh" ? "已复制到剪贴板" : "Copied to the clipboard";
      var old = btn.textContent;
      btn.textContent = LANG === "zh" ? "已复制" : "copied";
      btn.classList.add("done");
      setTimeout(function () {
        btn.textContent = old;
        btn.classList.remove("done");
      }, 1200);
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () {
        /* the text is selectable anyway */
      });
      return;
    }
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
      done();
    } catch (e) {
      /* ignore */
    }
    document.body.removeChild(ta);
  }

  document.querySelectorAll(".code").forEach(function (box) {
    var pre = box.querySelector("pre");
    if (!pre) return;
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy";
    btn.textContent = LANG === "zh" ? "复制" : "copy";
    btn.addEventListener("click", function () {
      copy(pre.innerText.replace(/\n$/, ""), btn);
    });
    box.appendChild(btn);
  });

  document.querySelectorAll("[data-copy]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      copy(btn.getAttribute("data-copy"), btn);
    });
  });

  /* ---- search --------------------------------------------------------
     The index is written by scripts/docs/gen_search.py from the pages
     themselves: one entry per heading, with the paragraph under it. */

  /* The matched letters, marked; and the forty characters around the first
     match, so a result says where the word actually is. */
  function markMatch(el, text, q) {
    var at = text.toLowerCase().indexOf(q);
    if (at < 0) {
      el.textContent = text;
      return;
    }
    el.appendChild(document.createTextNode(text.slice(0, at)));
    var mark = document.createElement("mark");
    mark.textContent = text.slice(at, at + q.length);
    el.appendChild(mark);
    el.appendChild(document.createTextNode(text.slice(at + q.length)));
  }

  function excerpt(text, q) {
    var at = text.toLowerCase().indexOf(q);
    if (at < 0) at = 0;
    var from = Math.max(0, at - 30);
    var to = Math.min(text.length, at + q.length + 46);
    var cut = text.slice(from, to).trim();
    // start and end on a word, not in the middle of one
    if (from > 0) cut = cut.slice(cut.indexOf(" ") + 1);
    if (to < text.length) cut = cut.slice(0, cut.lastIndexOf(" "));
    return (from > 0 ? "…" : "") + cut + (to < text.length ? "…" : "");
  }

  var form = document.getElementById("search-form");
  var entries = (window.SEARCH || []).filter(function (e) {
    return e.lang === LANG;
  });

  if (form && entries.length) {
    var input = form.querySelector("input");
    var panel = form.querySelector(".hits");
    var open = -1;

    var hide = function () {
      panel.hidden = true;
      open = -1;
    };

    var render = function () {
      var q = input.value.trim().toLowerCase();
      if (!q) {
        hide();
        return;
      }
      var hits = [];
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var inHead = e.heading.toLowerCase().indexOf(q);
        var inText = e.text.toLowerCase().indexOf(q);
        if (inHead < 0 && inText < 0) continue;
        hits.push({ e: e, score: inHead === 0 ? 0 : inHead > 0 ? 1 : 2 });
      }
      hits.sort(function (a, b) {
        return a.score - b.score || a.e.heading.length - b.e.heading.length;
      });

      panel.innerHTML = "";
      if (!hits.length) {
        var none = document.createElement("li");
        none.className = "none";
        none.textContent = LANG === "zh" ? "没有匹配的段落" : "No section matches";
        panel.appendChild(none);
        panel.hidden = false;
        return;
      }
      hits.slice(0, 8).forEach(function (hit) {
        var li = document.createElement("li");
        var a = document.createElement("a");
        a.href = BASE + "/" + hit.e.url;
        var b = document.createElement("b");
        markMatch(b, hit.e.heading, q);
        var s = document.createElement("span");
        s.textContent = hit.e.page;
        a.appendChild(b);
        a.appendChild(s);
        if (hit.e.text) {
          var line = document.createElement("em");
          line.textContent = excerpt(hit.e.text, q);
          a.appendChild(line);
        }
        li.appendChild(a);
        panel.appendChild(li);
      });
      open = -1;
      panel.hidden = false;
    };

    input.addEventListener("input", render);
    input.addEventListener("focus", function () {
      if (input.value.trim()) render();
    });
    input.addEventListener("keydown", function (ev) {
      var links = panel.querySelectorAll("a");
      if (ev.key === "Escape") {
        hide();
        input.blur();
      } else if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
        if (!links.length) return;
        ev.preventDefault();
        open = ev.key === "ArrowDown"
          ? Math.min(open + 1, links.length - 1)
          : Math.max(open - 1, 0);
        links.forEach(function (l, i) {
          l.parentNode.classList.toggle("on", i === open);
        });
        links[open].focus();
      } else if (ev.key === "Enter" && links.length) {
        ev.preventDefault();
        links[Math.max(open, 0)].click();
      }
    });
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var first = panel.querySelector("a");
      if (first) window.location.href = first.href;
    });
    document.addEventListener("click", function (ev) {
      if (!form.contains(ev.target)) hide();
    });
  }

  /* ---- the guide's own table of contents -------------------------------
     The left rail lists the guide's sections only on the guide page, so the
     one the reader is in is marked as they scroll. */

  var subLinks = document.querySelectorAll("#side .sub a");
  if (subLinks.length) {
    var targets = [];
    subLinks.forEach(function (a) {
      var id = a.getAttribute("href").split("#")[1];
      var section = id && document.getElementById(id);
      if (section) targets.push({ a: a, el: section });
    });
    var spy = function () {
      var at = null;
      targets.forEach(function (t) {
        if (t.el.getBoundingClientRect().top <= 96) at = t;
      });
      targets.forEach(function (t) {
        t.a.classList.toggle("on", t === at);
      });
    };
    addEventListener("scroll", spy, { passive: true });
    spy();
  }

  /* ---- the mark --------------------------------------------------------
     Four cuts of the mark: daylight and night, in three spellings — `mooncat`
     for the English pages, `MoonCat` for the Chinese ones, and `Mooncat` for
     the visit that comes in one time in ten. The night cuts are the navy
     tiles; the day cuts are the same art on nothing at all. */

  var marks = document.querySelectorAll("img[data-dark]");
  if (marks.length) {
    var swapped = Math.random() < 0.1;
    var syncLogo = function () {
      var theme = root.getAttribute("data-theme") || system();
      var key = "data-" + (swapped ? "egg-" : "") + theme;
      marks.forEach(function (img) {
        var src = img.getAttribute(key);
        if (src && img.getAttribute("src") !== src) {
          img.src = src;
        }
      });
      // The word beside the mark says what the mark says.
      document.querySelectorAll("[data-word]").forEach(function (word) {
        var said = word.getAttribute(swapped ? "data-egg-word" : "data-word");
        if (said && word.textContent !== said) {
          word.textContent = said;
        }
      });
    };
    syncLogo();
    addEventListener("mooncat:theme", syncLogo);
    if (matchMedia("(prefers-color-scheme: dark)").addEventListener) {
      matchMedia("(prefers-color-scheme: dark)").addEventListener("change", syncLogo);
    }
  }

  /* ---- back to the top --------------------------------------------------
     Out of the way at the top of the page, and a way back once the reader has
     gone past the first screen. */

  var toTop = document.getElementById("to-top");
  if (toTop) {
    var showTop = function () {
      toTop.hidden = window.scrollY < 600;
    };
    toTop.addEventListener("click", function () {
      var still = matchMedia("(prefers-reduced-motion: reduce)").matches;
      window.scrollTo({ top: 0, behavior: still ? "auto" : "smooth" });
      var first = document.querySelector(".brand");
      if (first) first.focus({ preventScroll: true });
    });
    addEventListener("scroll", showTop, { passive: true });
    showTop();
  }

  /* ---- how far down the page you are -----------------------------------
     Two pixels at the top of the window, drawn only when the page scrolls. */

  var track = document.querySelector(".progress");
  if (track) {
    var line = track.querySelector("i");
    var tick = function () {
      var doc = document.documentElement;
      var room = doc.scrollHeight - doc.clientHeight;
      track.hidden = room < 40;
      line.style.transform = "scaleX(" + (room > 0 ? Math.min(1, window.scrollY / room) : 0) + ")";
    };
    addEventListener("scroll", tick, { passive: true });
    addEventListener("resize", tick);
    tick();
  }

  /* ---- a link on every heading -----------------------------------------
     A section that has an id can be pointed at; its heading offers the link,
     which is the only way a reader can copy one without the address bar. */

  document.querySelectorAll("h2.bar, h3.bar").forEach(function (head) {
    // A section's own title borrows the section's id; a subsection needs one
    // of its own, or every heading in the package would point at the same
    // place and the link would say nothing.
    var id = head.id ||
      (head.tagName === "H2" ? (head.parentNode && head.parentNode.id) : "") || "";
    if (!id || head.querySelector(".anchor")) return;
    var link = document.createElement("a");
    link.className = "anchor";
    link.href = "#" + id;
    link.textContent = "#";
    link.setAttribute("aria-label", LANG === "zh" ? "本节链接" : "Link to this section");
    head.insertBefore(link, head.querySelector(".aside"));
  });

  /* ---- the section a link landed in ------------------------------------
     Arriving at `#workers` from another page should show where you are. */

  var flash = function () {
    document.querySelectorAll(".section.arrived").forEach(function (s) {
      s.classList.remove("arrived");
    });
    if (!location.hash) return;
    var at = document.getElementById(location.hash.slice(1));
    var section = at && at.closest(".section");
    if (!section) return;
    // restart the animation even when the same hash is picked twice
    void section.offsetWidth;
    section.classList.add("arrived");
  };
  addEventListener("hashchange", flash);
  flash();

  /* ---- a table that continues to the right -----------------------------
     Wide tables scroll; without a shadow the cut looks like the end. */

  var wraps = document.querySelectorAll(".tbl-wrap");
  if (wraps.length) {
    var markWide = function () {
      wraps.forEach(function (w) {
        w.classList.toggle("more", w.scrollWidth - w.clientWidth > 4);
      });
    };
    markWide();
    addEventListener("resize", markWide);
  }

  /* ---- / puts the cursor in the search box -----------------------------
     The key every documentation site uses, and it never steals a keystroke
     from a field the reader is already typing in. */

  if (form && entries.length) {
    addEventListener("keydown", function (ev) {
      if (ev.key !== "/" || ev.metaKey || ev.ctrlKey || ev.altKey) return;
      var tag = (ev.target.tagName || "").toLowerCase();
      if (tag === "input" || tag === "textarea" || ev.target.isContentEditable) return;
      ev.preventDefault();
      input.focus();
      input.select();
    });
  }

  /* ---- paper -----------------------------------------------------------
     A folded entry in the reference is still part of the page: open them all
     for the printer, and fold them back afterwards. */

  addEventListener("beforeprint", function () {
    document.querySelectorAll("details:not([open])").forEach(function (d) {
      d.setAttribute("data-was-closed", "");
      d.open = true;
    });
  });
  addEventListener("afterprint", function () {
    document.querySelectorAll("details[data-was-closed]").forEach(function (d) {
      d.open = false;
      d.removeAttribute("data-was-closed");
    });
  });
})();
