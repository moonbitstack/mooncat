/* The playground: one recorded request at a time, the socket on the left and the
   application on the right, in the order they happened. The rows are in
   traces.js, written by scripts/docs/record_traces.py; nothing here invents one. */
(function () {
  "use strict";

  var scenarios = window.SIDES || [];
  var board = document.getElementById("sides");
  if (!scenarios.length || !board) return;

  var lang = document.documentElement.lang === "zh" ? "zh" : "en";
  var say = {
    en: { wire: "on the wire", app: "in the application", out: "client →", "in": "← client",
          scope: "scope", receive: "receive()", send: "send()", ms: "ms" },
    zh: { wire: "线上", app: "应用里", out: "客户端 →", "in": "← 客户端",
          scope: "scope", receive: "receive()", send: "send()", ms: "毫秒" }
  }[lang];

  var pick = document.getElementById("pick");
  var head = document.getElementById("command-line");
  var note = document.getElementById("trace-note");
  var replay = document.getElementById("replay");
  var reduce = matchMedia("(prefers-reduced-motion: reduce)");
  var timers = [];
  var current = null;

  function cell(row) {
    var box = document.createElement("div");
    box.className = "ev " + row.dir;
    var tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = say[row.dir] || row.dir;
    var title = document.createElement("b");
    title.textContent = row.title;
    box.appendChild(tag);
    box.appendChild(title);
    if (row.body) {
      var body = document.createElement("pre");
      body.textContent = row.body;
      box.appendChild(body);
    }
    return box;
  }

  function draw(scenario) {
    timers.forEach(clearTimeout);
    timers = [];
    current = scenario;
    var words = scenario.words[lang] || scenario.words.en;
    head.textContent = words.command;
    note.textContent = words.note;
    board.querySelectorAll(".row").forEach(function (old) { old.remove(); });
    var rows = scenario.rows.map(function (row) {
      var line = document.createElement("div");
      line.className = "row";
      var time = document.createElement("span");
      time.className = "t";
      time.textContent = row.t.toFixed(1) + " " + say.ms;
      var wire = document.createElement("div");
      var app = document.createElement("div");
      wire.className = "side wire";
      app.className = "side app";
      wire.setAttribute("data-label", say.wire);
      app.setAttribute("data-label", say.app);
      (row.side === "wire" ? wire : app).appendChild(cell(row));
      if (row.side === "wire") app.classList.add("empty"); else wire.classList.add("empty");
      line.appendChild(time);
      line.appendChild(wire);
      line.appendChild(app);
      board.appendChild(line);
      return line;
    });
    if (reduce.matches) {
      rows.forEach(function (r) { r.classList.add("on"); });
      return;
    }
    rows.forEach(function (r, i) {
      timers.push(setTimeout(function () { r.classList.add("on"); }, 120 + i * 220));
    });
  }

  scenarios.forEach(function (scenario, i) {
    var button = document.createElement("button");
    button.type = "button";
    button.textContent = (scenario.words[lang] || scenario.words.en).label;
    button.setAttribute("aria-pressed", i === 0 ? "true" : "false");
    button.addEventListener("click", function () {
      pick.querySelectorAll("button").forEach(function (b) {
        b.setAttribute("aria-pressed", b === button ? "true" : "false");
      });
      draw(scenario);
    });
    pick.appendChild(button);
  });
  draw(scenarios[0]);

  if (replay) replay.addEventListener("click", function () { draw(current); });

  // The arrow keys walk the row of requests: what a reader who arrived with the
  // tab key tries first.
  pick.addEventListener("keydown", function (ev) {
    var keys = { ArrowRight: 1, ArrowLeft: -1, Home: -99, End: 99 };
    if (!(ev.key in keys)) return;
    var buttons = Array.prototype.slice.call(pick.querySelectorAll("button"));
    var at = buttons.indexOf(document.activeElement);
    if (at < 0) return;
    ev.preventDefault();
    var step = keys[ev.key];
    var next = step === -99 ? 0 : step === 99 ? buttons.length - 1
      : (at + step + buttons.length) % buttons.length;
    buttons[next].focus();
    buttons[next].click();
  });
})();
