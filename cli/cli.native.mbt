///|
/// Why a command line was not accepted.
///
/// Unknown flags and missing values are `argparse`'s to report — it already
/// prints what clap prints. These three are mooncat's own.
pub(all) suberror Refused {
  /// A value that is not what the flag takes. `want` names the shape, such as
  /// `"a number"` or the list of words a choice allows.
  Value(flag~ : String, got~ : String, want~ : String)
  /// A uvicorn flag mooncat cannot honour, and the reason.
  Unsupported(flag~ : String, why~ : String)
  /// Half of a pair. `--ssl-certfile` without `--ssl-keyfile` is not a
  /// certificate.
  Partial(flag~ : String, needs~ : String)
} derive(Eq, Debug)

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
pub extend Refused with Show::{to_string, output}

///|
pub impl Show for Refused with fn output(self, logger) {
  match self {
    Value(flag~, got~, want~) =>
      logger.write_string("\{flag} wants \{want}, got '\{got}'")
    Unsupported(flag~, why~) => logger.write_string("\{flag}: \{why}")
    Partial(flag~, needs~) => logger.write_string("\{flag} also needs \{needs}")
  }
}

///|
/// What a parsed command line says to do: the configuration, whether to wrap
/// it in TLS, and whether to speak HTTP/2 in the clear.
///
/// The three together pick which `serve_*` runs, which is why they travel as
/// one value instead of as three arguments.
pub(all) struct Plan {
  config : @mooncat.Config
  tls : @mooncat.TlsCert?
  h2c : Bool
}

// ------------------------------------------------------------------ grammar

///|
/// uvicorn flags mooncat cannot honour, each with the reason.
///
/// Declared rather than left to fall through as "unexpected argument":
/// someone who writes `--workers 4` should be told that one process is all
/// there will be, not that the flag looks like a typo. The second field says
/// whether the flag takes a value, which `argparse` needs in order to swallow
/// it before complaining.
let refused : Array[(String, Bool, String)] = [
  (
    "reload", false, "a save cannot change a compiled binary; watch files with @mooncat.reload_watch and let a supervisor rebuild and restart",
  ),
  ("reload-dir", true, "see --reload"),
  ("reload-include", true, "see --reload"),
  ("reload-exclude", true, "see --reload"),
  ("reload-delay", true, "see --reload"),
  ("workers", true, "mooncat serves from one process; there is no fork here"),
  ("uds", true, "the async transport binds TCP only"),
  ("fd", true, "the async transport binds TCP only"),
  ("factory", false, "there is no import by string to call a factory through"),
  ("app-dir", true, "the app is linked in, not found on a path"),
  ("interface", true, "ASGI 3.0 is the only interface"),
  ("loop", true, "moonbitlang/async is the only event loop"),
  ("http", true, "there is one HTTP/1.1 implementation; --h2c picks HTTP/2"),
  ("ws", true, "there is one WebSocket implementation"),
  ("log-config", true, "logging is configured in code, through Config::logger"),
  ("env-file", true, "read the file yourself and build a Config"),
  (
    "ws-ping-interval", true, "a heartbeat needs a read that can be interrupted mid-message, which a native blocking read cannot be",
  ),
  ("ws-ping-timeout", true, "see --ws-ping-interval"),
  (
    "ws-max-queue", true, "bounding the queue needs that same interruptible reader",
  ),
  (
    "ws-per-message-deflate", false, "the async gzip package frames gzip streams only, and accepting the extension without raw DEFLATE would corrupt every frame",
  ),
  ("ssl-keyfile-password", true, "the TLS backend takes unencrypted keys"),
  ("ssl-version", true, "TLS 1.3 only"),
  ("ssl-cert-reqs", true, "client certificates are not requested"),
  ("ssl-ca-certs", true, "client certificates are not requested"),
  ("ssl-ciphers", true, "the suites are TLS 1.3's, and not selectable"),
]

///|
/// The command line, as `argparse` describes it.
///
/// Options carry no defaults on purpose: an absent flag must be
/// distinguishable from one that happens to match the default, because
/// everything not given is left as `parse` found it in `base`.
pub fn command(version~ : String = "0.14.6") -> @argparse.Command {
  let flags = [
    @argparse.FlagArg::FlagArg(
      "date_header",
      long="date-header",
      negatable=true,
      about="stamp a Date header on every response",
    ),
    @argparse.FlagArg::FlagArg(
      "server_header",
      long="server-header",
      negatable=true,
      about="stamp a Server header",
    ),
    @argparse.FlagArg::FlagArg(
      "proxy_headers",
      long="proxy-headers",
      negatable=true,
      about="believe X-Forwarded-* from the allowed peers",
    ),
    @argparse.FlagArg::FlagArg(
      "access_log",
      long="access-log",
      negatable=true,
      about="log one line per request",
    ),
    @argparse.FlagArg::FlagArg(
      "reuse_addr",
      long="reuse-addr",
      negatable=true,
      about="set SO_REUSEADDR on the listener",
    ),
    @argparse.FlagArg::FlagArg(
      "dual_stack",
      long="dual-stack",
      about="accept IPv4 and IPv6 on one socket",
    ),
    @argparse.FlagArg::FlagArg(
      "cleartext",
      long="cleartext",
      negatable=true,
      about="serve the clear beside TLS on the TLS port",
    ),
    @argparse.FlagArg::FlagArg(
      "h2c",
      long="h2c",
      about="speak HTTP/2 in the clear instead of HTTP/1.1",
    ),
  ]
  for one in refused {
    if !one.1 {
      flags.push(@argparse.FlagArg::FlagArg(one.0, long=one.0, hidden=true))
    }
  }
  let options = [
    text("host", "address to bind", env="MOONCAT_HOST"),
    text("port", "port to bind", env="MOONCAT_PORT"),
    text("backlog", "listen backlog (recorded, not applied)"),
    text("root-path", "path prefix something in front has stripped"),
    text("limit-concurrency", "refuse with 503 above this many in flight"),
    text("limit-max-requests", "stop serving after this many requests"),
    text("max-connections", "make a client wait above this many connections"),
    text("timeout-keep-alive", "seconds an idle keep-alive connection is held"),
    text("timeout-graceful-shutdown", "seconds to wait for requests to drain"),
    text("h11-max-incomplete-event-size", "bytes a request head may reach"),
    text(
      "forwarded-allow-ips", "comma-separated peers whose forwarded headers count",
    ),
    text("log-level", "trace, debug, info, warning, error or critical"),
    text("ws-max-size", "bytes a WebSocket message may reach"),
    text("lifespan", "auto, on or off"),
    text("ssl-certfile", "PEM certificate; serves HTTPS"),
    text("ssl-keyfile", "PEM private key; serves HTTPS"),
  ]
  for one in refused {
    if one.1 {
      options.push(
        @argparse.OptionArg::OptionArg(one.0, long=one.0, hidden=true),
      )
    }
  }
  @argparse.Command::Command(
    "mooncat",
    about="Serve an ASGI application over HTTP/1.1, HTTP/2 or HTTPS.",
    version~,
    flags~,
    options~,
  )
}

///|
fn text(
  name : String,
  about : String,
  env~ : String = "",
) -> @argparse.OptionArg {
  if env == "" {
    @argparse.OptionArg::OptionArg(name, long=name, about~)
  } else {
    @argparse.OptionArg::OptionArg(name, long=name, about~, env~)
  }
}

// ------------------------------------------------------------------ parsing

///|
/// Read a command line into a `Plan`, starting from `base` and overriding only
/// what was given.
///
/// `--help` and `--version` are `argparse`'s: it prints and exits the process,
/// as uvicorn and clap do, so they never come back here.
///
/// One wart worth stating: `Logger` is opaque, so `--log-level` and
/// `--access-log` cannot adjust the one in `base` — either flag replaces it
/// with a fresh logger at the level asked for, which drops a custom `write`.
/// Neither flag leaves `base`'s logger alone.
pub fn parse(
  argv : ArrayView[String],
  base~ : @mooncat.Config = @mooncat.Config::new(),
) -> Plan raise {
  let got = command().parse(argv~)
  for one in refused {
    let given = if one.1 {
      got.values.get(one.0) is Some(_)
    } else {
      got.flags.get(one.0) is Some(_)
    }
    if given {
      raise Unsupported(flag="--" + one.0, why=one.2)
    }
  }
  let config = fold(got, base)
  let tls = certificate(got)
  let h2c = got.flags.get("h2c") is Some(true)
  { config, tls, h2c, }
}

///|
/// Everything the command line said, laid over `base`.
fn fold(
  got : @argparse.Matches,
  base : @mooncat.Config,
) -> @mooncat.Config raise Refused {
  let seconds = (flag : String, value : Int32) => {
    ignore(flag)
    value * 1000
  }
  {
    ..base,
    host: word(got, "host", base.host),
    port: count(got, "port", base.port),
    backlog: count(got, "backlog", base.backlog),
    root_path: word(got, "root-path", base.root_path),
    dual_stack: switched(got, "dual_stack", base.dual_stack),
    reuse_addr: switched(got, "reuse_addr", base.reuse_addr),
    date_header: switched(got, "date_header", base.date_header),
    cleartext: switched(got, "cleartext", base.cleartext),
    proxy_headers: switched(got, "proxy_headers", base.proxy_headers),
    server_headers: if switched(
        got,
        "server_header",
        base.server_headers.length() > 0,
      ) {
      base.server_headers
    } else {
      Map([])
    },
    limit_concurrency: maybe(got, "limit-concurrency", base.limit_concurrency),
    limit_max_requests: maybe(
      got,
      "limit-max-requests",
      base.limit_max_requests,
    ),
    max_connections: maybe(got, "max-connections", base.max_connections),
    graceful_timeout: match reading(got, "timeout-graceful-shutdown") {
      Some(text) =>
        Some(
          seconds(
            "--timeout-graceful-shutdown",
            number("--timeout-graceful-shutdown", text),
          ),
        )
      None => base.graceful_timeout
    },
    timeout_keep_alive: match reading(got, "timeout-keep-alive") {
      Some(text) =>
        seconds("--timeout-keep-alive", number("--timeout-keep-alive", text))
      None => base.timeout_keep_alive
    },
    max_head_size: count(
      got,
      "h11-max-incomplete-event-size",
      base.max_head_size,
    ),
    forwarded_allow_ips: match reading(got, "forwarded-allow-ips") {
      Some(text) => commas(text)
      None => base.forwarded_allow_ips
    },
    ws: { max_size: count(got, "ws-max-size", base.ws.max_size), },
    lifespan: match reading(got, "lifespan") {
      Some("auto") => Auto
      Some("on") => On
      Some("off") => Off
      Some(other) =>
        raise Value(flag="--lifespan", got=other, want="auto, on or off")
      None => base.lifespan
    },
    logger: logger(got, base.logger),
  }
}

///|
/// The certificate, if one was asked for. Both halves or neither.
fn certificate(got : @argparse.Matches) -> @mooncat.TlsCert? raise Refused {
  let cert = reading(got, "ssl-certfile")
  let key = reading(got, "ssl-keyfile")
  match (cert, key) {
    (None, None) => None
    (Some(_), None) =>
      raise Partial(flag="--ssl-certfile", needs="--ssl-keyfile")
    (None, Some(_)) =>
      raise Partial(flag="--ssl-keyfile", needs="--ssl-certfile")
    (Some(cert), Some(key)) =>
      Some({ certificate_file: cert, private_key_file: key, })
  }
}

///|
/// A logger at the level asked for, or `base`'s when neither flag was given.
fn logger(
  got : @argparse.Matches,
  base : @mooncat.Logger,
) -> @mooncat.Logger raise Refused {
  let level = reading(got, "log-level")
  let access = got.flags.get("access_log")
  if level is None && access is None {
    return base
  }
  let level = match level {
    Some(text) => speech(text)
    None => @moonlog.Level::Info
  }
  @mooncat.Logger::new(
    level~,
    access=match access {
      Some(access) => access
      None => true
    },
  )
}

///|
/// uvicorn's level names. `critical` is the one that is not also a `Level`.
fn speech(text : String) -> @moonlog.Level raise Refused {
  match text {
    "trace" => Trace
    "debug" => Debug
    "info" => Info
    "warning" => Warning
    "error" => Error
    "critical" => Fatal
    other =>
      raise Value(
        flag="--log-level",
        got=other,
        want="trace, debug, info, warning, error or critical",
      )
  }
}

// ----------------------------------------------------------------- plumbing

///|
fn reading(got : @argparse.Matches, name : String) -> String? {
  match got.values.get(name) {
    Some(values) => if values.length() > 0 { Some(values[0]) } else { None }
    None => None
  }
}

///|
fn word(got : @argparse.Matches, name : String, fallback : String) -> String {
  match reading(got, name) {
    Some(text) => text
    None => fallback
  }
}

///|
fn count(
  got : @argparse.Matches,
  name : String,
  fallback : Int32,
) -> Int32 raise Refused {
  match reading(got, name) {
    Some(text) => number("--" + name, text)
    None => fallback
  }
}

///|
fn maybe(
  got : @argparse.Matches,
  name : String,
  fallback : Int32?,
) -> Int32? raise Refused {
  match reading(got, name) {
    Some(text) => Some(number("--" + name, text))
    None => fallback
  }
}

///|
fn switched(got : @argparse.Matches, name : String, fallback : Bool) -> Bool {
  match got.flags.get(name) {
    Some(value) => value
    None => fallback
  }
}

///|
fn number(flag : String, text : String) -> Int32 raise Refused {
  guard text.length() > 0 else { raise Value(flag~, got=text, want="a number") }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text[i].to_int()
    guard c >= 0x30 && c <= 0x39 else {
      raise Value(flag~, got=text, want="a number")
    }
    value = value * 10 + (c - 0x30)
  }
  value
}

///|
fn commas(text : String) -> Array[String] {
  let out = []
  let piece = StringBuilder()
  for i = 0; i < text.length(); i = i + 1 {
    let c = text[i].to_int()
    if c == 0x2C {
      let one = piece.to_string()
      if one.length() > 0 {
        out.push(one)
      }
      piece.reset()
    } else if c != 0x20 {
      piece.write_char(c.unsafe_to_char())
    }
  }
  let one = piece.to_string()
  if one.length() > 0 {
    out.push(one)
  }
  out
}
