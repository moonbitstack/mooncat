// 此功能不入文档

// The banner a program may print before it begins to serve. Nothing here runs
// unless a program asks for it: linking this package changes no output of its
// own, and `enable` is the only way in.
//
// The wordmark is drawn in the same shapes as the mark: a moon, two server bars
// and a cat peering over them, in seven-segment, block and typewriter alphabets.

///|
/// The art chosen at run time, or `None` while the banner is off.
let chosen : Ref[String?] = Ref(None)

///|
/// Art added by a program, under the name it was added with.
let added : Ref[Map[String, String]] = Ref(Map([]))

///|
/// Turn the banner on, optionally naming the art: `enable(name="shadow")`.
///
/// A name that is neither built in nor added falls back to `fast`, which is what
/// `enable()` alone selects. Turning it on twice with a different name replaces
/// the choice rather than printing twice.
pub fn enable(name? : String) -> Unit {
  let wanted = match name {
    Some(n) => n
    None => "fast"
  }
  let picture = match added.val.get(wanted) {
    Some(art) => art
    None => builtin(wanted).unwrap_or(builtin("fast").unwrap_or("mooncat"))
  }
  chosen.val = Some(picture)
}

///|
/// Turn the banner off. A program that never enables it is in this state to
/// begin with, which is why a server built against this package prints nothing.
pub fn disable() -> Unit {
  chosen.val = None
}

///|
/// Whether `print` would print anything.
pub fn is_enabled() -> Bool {
  chosen.val is Some(_)
}

///|
/// The name of the art in use, or `""` while the banner is off.
pub fn style() -> String {
  match chosen.val {
    None => ""
    Some(art) => {
      for pair in all() {
        if pair.1 == art {
          return pair.0
        }
      }
      "custom"
    }
  }
}

///|
/// Add art under a name, so `enable(name=..)` can select it. The text is printed
/// as it is given: a program that wants colour puts its own escape sequences in.
pub fn register(name : String, art : String) -> Unit {
  added.val[name] = art
}

///|
/// The names `enable` accepts: the built-in ones in the order they are listed,
/// then any added with `register`.
pub fn names() -> Array[String] {
  let out = builtin_names.copy()
  for name, _ in added.val {
    if !out.contains(name) {
      out.push(name)
    }
  }
  out
}

///|
/// The banner itself, or `""` while it is off. Printing it is the program's to
/// do: a server that starts under a supervisor may want it in a log instead.
pub fn banner() -> String {
  match chosen.val {
    Some(art) => art
    None => ""
  }
}

///|
/// Print the banner, if it is on. The one line a program adds to its start.
pub fn print() -> Unit {
  match chosen.val {
    Some(art) => println(art)
    None => ()
  }
}
