/* Page furniture: the theme switch, the scrollbar-at-top mark, copy buttons,
   and the rare alternate logo. Nothing here draws content of its own. */

(function () {
  "use strict";

  var root = document.documentElement;

  /* ---- theme -------------------------------------------------------- */

  var KEY = "mooncat-theme";

  function system() {
    return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function paint() {
    var t = root.getAttribute("data-theme") || system();
    var btn = document.getElementById("theme");
    if (btn) {
      btn.setAttribute("aria-label", "Switch to " + (t === "dark" ? "light" : "dark") + " theme");
      btn.setAttribute("title", "Switch to " + (t === "dark" ? "light" : "dark") + " theme");
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
      document.dispatchEvent(new CustomEvent("mooncat:theme", { detail: next }));
    });
  }

  /* ---- page scrollbar: thumb hidden only while the page is at its top -- */

  var mark = function () {
    root.classList.toggle("at-top", window.scrollY === 0);
  };
  addEventListener("scroll", mark, { passive: true });
  mark();

  /* ---- copy buttons -------------------------------------------------- */

  function copy(text, btn) {
    var done = function () {
      var old = btn.textContent;
      btn.textContent = "copied";
      btn.classList.add("done");
      setTimeout(function () {
        btn.textContent = old;
        btn.classList.remove("done");
      }, 1200);
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () {
        /* fall through to nothing: the text is selectable anyway */
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
    btn.textContent = "copy";
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

  /* ---- the alternate logo -------------------------------------------
     The mark has a second cut, with the wordmark capitalised. It turns up
     about one visit in ten, and the page never says so. */

  var logo = document.getElementById("logo");
  if (logo && Math.random() < 0.1) {
    logo.src = logo.getAttribute("data-alt");
    logo.alt = "MoonCat";
  }
})();
