///|
/// The WebSocket knobs uvicorn exposes on its own config (`--ws-max-size`).
///
/// `max_size` is the ceiling on a received payload, in bytes: it bounds a single frame and, across
/// continuation frames, a reassembled message, and a peer that announces more fails the connection
/// with `1009`. It is the knob with teeth on the receive side — an unbounded length is exactly what
/// a hostile client sends.
///
/// uvicorn's remaining WebSocket knobs are not here rather than here-and-ignored:
/// `--ws-ping-interval` / `--ws-ping-timeout` need a heartbeat task alongside a reader that can be
/// interrupted between messages and resumed, `--ws-max-queue` needs that same reader pumping a
/// bounded queue, and neither is expressible while a native blocking read cannot be cancelled and
/// resumed mid-stream; `--ws-per-message-deflate` needs a raw DEFLATE codec, which the async
/// library's `gzip` package (gzip-framed streams only) does not provide. Accepting the extension
/// without one would corrupt every frame.
pub(all) struct WsConfig {
  max_size : Int
}

///|
/// Build a `WsConfig`, defaulting `max_size` to uvicorn's own 16 MiB.
pub fn WsConfig::new(max_size? : Int = ws_max_size) -> WsConfig {
  { max_size, }
}

///|
/// Server configuration (← uvicorn `Config`): the bind address, the listen
/// backlog, and the HTTP/1.1 transport knobs the `moonbitlang/async` server
/// exposes. Constructed once and handed to `serve_config`.
///
/// `backlog` mirrors uvicorn's `listen(2)` backlog. The current
/// `moonbitlang/async` transport does not expose a backlog setter on its TCP
/// listener — `TcpServer` calls `listen()` itself with a fixed depth and offers
/// no way to re-`listen` — so the value is recorded on the config for parity and
/// future use but is not applied to the socket. This is a transport-capability
/// gap, not a behavioural choice, and it is the one field here that does nothing.
///
/// The remaining fields map one-to-one onto knobs mooncat *does* honour:
/// `dual_stack` / `reuse_addr` on the listening socket, `server_headers`
/// stamped onto every response (uvicorn's `Server:` header lives here),
/// `max_connections` for the parallel-client ceiling, and `allow_failure` for
/// whether a handler error tears the whole server down.
pub(all) struct Config {
  host : String
  port : Int
  backlog : Int
  dual_stack : Bool
  reuse_addr : Bool
  server_headers : Map[String, String]
  max_connections : Int?
  allow_failure : Bool
  graceful_timeout : Int?
  // The path prefix this app is mounted under when something in front strips it
  // (← uvicorn's `--root-path`). It reaches the app as `scope["root_path"]`, which
  // is what lets the app build correct absolute URLs for itself.
  root_path : String
  // What the server says while it runs. Off by default in the sense that a caller
  // can hand in `Logger::silent()`, but a server that reports nothing is one nobody
  // can operate, so the default talks.
  logger : Logger
  // How long an idle keep-alive connection is held open waiting for the next request,
  // in milliseconds (← uvicorn's `--timeout-keep-alive`). A connection nobody is using
  // still costs a socket and a task, and a peer that opens many and sends nothing is
  // how a server runs out of both.
  timeout_keep_alive : Int
  // Stop serving after this many requests (← uvicorn's `--limit-max-requests`), the
  // knob a supervisor uses to recycle a worker before it accumulates whatever it
  // accumulates. `None` serves forever.
  limit_max_requests : Int?
  // The concurrent-request ceiling above which a request is refused with `503`
  // (← uvicorn's `--limit-concurrency`). Distinct from `max_connections`, which makes
  // a client *wait* for a slot; this one answers rather than queues.
  limit_concurrency : Int?
  // The cap on a request's head, request line and header block together, in bytes
  // (← uvicorn's `--h11-max-incomplete-event-size`). A peer that never sends the
  // terminating blank line must not be able to grow the buffer without limit.
  // Applies to the connections mooncat parses itself (HTTPS, and anything else on
  // the self-built HTTP/1.1 codec); the async library's own `ServerConnection`,
  // which the plaintext paths use, bounds its head by rules it does not expose.
  max_head_size : Int
  // Whether to stamp a `Date` header on every response (← uvicorn's `--date-header`).
  date_header : Bool
  // Whether to trust `X-Forwarded-For` / `X-Forwarded-Proto` from a peer in
  // `forwarded_allow_ips` (← uvicorn's `--proxy-headers`, on by default).
  proxy_headers : Bool
  // The peers whose forwarded headers are believed (← uvicorn's
  // `--forwarded-allow-ips`, `127.0.0.1` by default). A single `"*"` trusts every
  // peer, which is only ever right when nothing but a proxy can reach the port.
  forwarded_allow_ips : Array[String]
  // The WebSocket receive limits.
  ws : WsConfig
}

///|
/// The port every server in this family listens on unless told otherwise.
///
/// Not 8000, which is uvicorn's, and not 8080: on a development machine those
/// are taken by whatever ran last. One number of our own means every example,
/// every README and every round of integration testing agree without anyone
/// having to say which port they meant. HTTP, WebSocket, HTTP/2 and gRPC all
/// share it — one listener tells them apart — and QUIC takes the same number on
/// UDP, which is a different port space.
pub let port : Int = 12000

///|
/// Build a `Config`, defaulting to uvicorn's own defaults: host `127.0.0.1`,
/// port `12000`, backlog `2048`, a 5-second idle keep-alive timeout, a 16 KiB
/// request-head cap, the `Date` header on, proxy headers trusted from
/// `127.0.0.1`, and no request-count or concurrency limit. Transport knobs
/// default to the async server's own defaults: `reuse_addr` on (uvicorn sets
/// `SO_REUSEADDR`), single-stack binding, no extra response headers, an
/// unbounded connection ceiling, and `allow_failure` on so a single failing
/// handler never crashes the listener.
///
/// `graceful_timeout` bounds how long `serve_graceful` waits for in-flight
/// requests to drain before it runs lifespan shutdown anyway (← uvicorn's
/// `timeout_graceful_shutdown`); `None` waits until the last request finishes,
/// as uvicorn does by default.
pub fn Config::new(
  host? : String = "127.0.0.1",
  port? : Int = port,
  backlog? : Int = 2048,
  dual_stack? : Bool = false,
  reuse_addr? : Bool = true,
  server_headers? : Map[String, String] = Map([("server", "mooncat")]),
  max_connections? : Int,
  allow_failure? : Bool = true,
  graceful_timeout? : Int,
  root_path? : String = "",
  logger? : Logger = Logger::new(),
  timeout_keep_alive? : Int = 5000,
  limit_max_requests? : Int,
  limit_concurrency? : Int,
  max_head_size? : Int = 16 * 1024,
  date_header? : Bool = true,
  proxy_headers? : Bool = true,
  forwarded_allow_ips? : Array[String] = ["127.0.0.1"],
  ws? : WsConfig = WsConfig::new(),
) -> Config {
  {
    host,
    port,
    backlog,
    dual_stack,
    reuse_addr,
    server_headers,
    max_connections,
    allow_failure,
    graceful_timeout,
    root_path,
    logger,
    timeout_keep_alive,
    limit_max_requests,
    limit_concurrency,
    max_head_size,
    date_header,
    proxy_headers,
    forwarded_allow_ips,
    ws,
  }
}

///|
/// The `host:port` string used to resolve the listen address.
pub fn Config::bind(self : Config) -> String {
  "\{self.host}:\{self.port}"
}
