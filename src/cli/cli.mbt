///|
/// Why a command line was not accepted.
///
/// Unknown flags and missing values are `argparse`'s to report — it already
/// prints what clap prints. These three are mooncat's own.
#derive(Eq, Debug)
pub(all) suberror Refused {
  /// A value that is not what the flag takes. `want` names the shape, such as
  /// `"a number"` or the list of words a choice allows.
  Value(flag~ : String, got~ : String, want~ : String)
  /// A uvicorn flag mooncat cannot honour, and the reason.
  Unsupported(flag~ : String, why~ : String)
  /// Half of a pair. `--ssl-certfile` without `--ssl-keyfile` is not a
  /// certificate.
  Partial(flag~ : String, needs~ : String)
}

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
  http3 : Bool
  // The suites `--ssl-ciphers` names, by TLS version; absent, moontls's preset for that version.
  suites : Array[@record.Suite]?
  suites12 : Array[@record.Suite12]?
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
    "reload", false, "a save cannot change a compiled binary; run the server with mctl serve --reload, which rebuilds and restarts it",
  ),
  ("reload-dir", true, "see --reload"),
  ("reload-include", true, "see --reload"),
  ("reload-exclude", true, "see --reload"),
  ("reload-delay", true, "see --reload"),
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
    "ssl-version", true, "versions are set on @tls.Server, and serve_tls_server takes it",
  ),
  ("ssl-cert-reqs", true, "client certificates are not requested"),
  ("ssl-ca-certs", true, "client certificates are not requested"),
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
    @argparse.FlagArg::FlagArg(
      "http3",
      long="http3",
      about="serve HTTP/3 on UDP beside HTTPS, on the same port",
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
    text("workers", "processes to serve from (Linux)", env="WEB_CONCURRENCY"),
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
    text("ws-max-queue", "WebSocket messages waiting for the application"),
    text(
      "ws-ping-interval", "seconds between keepalive pings; 0 turns them off",
    ),
    text("ws-ping-timeout", "seconds a pong may take; 0 waits for ever"),
    text(
      "ws-per-message-deflate", "accept WebSocket compression: true or false",
    ),
    text("lifespan", "auto, on or off"),
    text(
      "early-data", "accept, refuse or off: what a request sent in 0-RTT gets",
    ),
    text("ssl-certfile", "PEM certificate; serves HTTPS"),
    text("ssl-keyfile", "PEM private key; serves HTTPS"),
    text("ssl-keyfile-password", "password of the key file or the PKCS#12 file"),
    text(
      "ssl-pkcs12", "PKCS#12 file (.p12, .pfx) holding the chain and the key; serves HTTPS",
    ),
    text(
      "ssl-ciphers", "TLS 1.3 and 1.2 suites to accept by IANA name, colon-separated, best first",
    ),
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
    about="Serve an ASGI application over HTTP/1.1, HTTP/2, HTTPS or HTTP/3.",
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
  let http3 = got.flags.get("http3") is Some(true)
  if http3 && tls is None {
    raise Unsupported(
      flag="--http3",
      why="QUIC needs --ssl-certfile or --ssl-pkcs12",
    )
  }
  let (suites, suites12) = match reading(got, "ssl-ciphers") {
    Some(text) => cipher_list(text)
    None => (None, None)
  }
  { config, tls, h2c, http3, suites, suites12, }
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
    workers: count(got, "workers", base.workers),
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
    ws: {
      max_size: count(got, "ws-max-size", base.ws.max_size),
      max_queue: count(got, "ws-max-queue", base.ws.max_queue),
      ping_interval: pause(got, "ws-ping-interval", base.ws.ping_interval),
      ping_timeout: pause(got, "ws-ping-timeout", base.ws.ping_timeout),
      deflate: match reading(got, "ws-per-message-deflate") {
        Some("true") => true
        Some("false") => false
        Some(other) =>
          raise Value(
            flag="--ws-per-message-deflate",
            got=other,
            want="true or false",
          )
        None => base.ws.deflate
      },
    },
    lifespan: match reading(got, "lifespan") {
      Some("auto") => Auto
      Some("on") => On
      Some("off") => Off
      Some(other) =>
        raise Value(flag="--lifespan", got=other, want="auto, on or off")
      None => base.lifespan
    },
    early_data: match reading(got, "early-data") {
      Some("accept") => @mooncat.EarlyData::Accept
      Some("refuse") => @mooncat.EarlyData::Refuse
      Some("off") => @mooncat.EarlyData::Off
      Some(other) =>
        raise Value(
          flag="--early-data",
          got=other,
          want="accept, refuse or off",
        )
      None => base.early_data
    },
    logger: logger(got, base.logger),
  }
}

///|
/// The certificate, if one was asked for: both PEM halves, or one PKCS#12 file, or neither.
fn certificate(got : @argparse.Matches) -> @mooncat.TlsCert? raise Refused {
  let cert = reading(got, "ssl-certfile")
  let key = reading(got, "ssl-keyfile")
  let pfx = reading(got, "ssl-pkcs12")
  let password = reading(got, "ssl-keyfile-password")
  match (cert, key, pfx) {
    (None, None, None) => {
      if password is Some(_) {
        raise Partial(flag="--ssl-keyfile-password", needs="--ssl-keyfile")
      }
      None
    }
    (None, None, Some(file)) =>
      Some(@mooncat.TlsCert::pkcs12(file, password=password.unwrap_or("")))
    (Some(_), _, Some(_)) | (_, Some(_), Some(_)) =>
      raise Unsupported(
        flag="--ssl-pkcs12",
        why="the PKCS#12 file holds the chain and the key; leave out --ssl-certfile and --ssl-keyfile",
      )
    (Some(_), None, None) =>
      raise Partial(flag="--ssl-certfile", needs="--ssl-keyfile")
    (None, Some(_), None) =>
      raise Partial(flag="--ssl-keyfile", needs="--ssl-certfile")
    (Some(cert), Some(key), None) =>
      Some(@mooncat.TlsCert::pem(cert, key, password?))
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
    None => @moonlog.info
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
/// uvicorn's level names; `warning` and `critical` are moonlog's `warn` and `fatal`.
fn speech(text : String) -> @moonlog.Level raise Refused {
  match text {
    "trace" => @moonlog.trace
    "debug" => @moonlog.debug
    "info" => @moonlog.info
    "warning" => @moonlog.warn
    "error" => @moonlog.error
    "critical" => @moonlog.fatal
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
/// A time in seconds as milliseconds, where 0 means none at all.
fn pause(
  got : @argparse.Matches,
  name : String,
  fallback : Int32?,
) -> Int32? raise Refused {
  match reading(got, name) {
    Some(text) =>
      match number("--" + name, text) {
        0 => None
        seconds => Some(seconds * 1000)
      }
    None => fallback
  }
}

///|
/// The suites `--ssl-ciphers` names, colon-separated in preference order as OpenSSL writes them,
/// by TLS version. A version none of them belongs to keeps its preset, so restricting 1.3 does
/// not turn 1.2 off.
fn cipher_list(
  text : String,
) -> (Array[@record.Suite]?, Array[@record.Suite12]?) raise Refused {
  let suites : Array[@record.Suite] = []
  let suites12 : Array[@record.Suite12] = []
  for name in text.split(":") {
    match name.to_owned() {
      "TLS_AES_128_GCM_SHA256" => suites.push(Aes128Gcm)
      "TLS_AES_256_GCM_SHA384" => suites.push(Aes256Gcm)
      "TLS_CHACHA20_POLY1305_SHA256" => suites.push(ChaCha20Poly1305)
      other =>
        if @record.all12.filter(s => s.name() == other) is [suite] {
          suites12.push(suite)
        } else {
          raise Value(
            flag="--ssl-ciphers",
            got=other,
            want="a TLS 1.3 or 1.2 suite by its IANA name",
          )
        }
    }
  }
  (
    if suites.is_empty() {
      None
    } else {
      Some(suites)
    },
    if suites12.is_empty() {
      None
    } else {
      Some(suites12)
    },
  )
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
