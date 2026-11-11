///|
/// The WebSocket knobs uvicorn exposes (`--ws-max-size`, `--ws-max-queue`, `--ws-ping-interval`,
/// `--ws-ping-timeout`, `--ws-per-message-deflate`), with its defaults.
///
/// `max_size` is the ceiling on a received payload, in bytes: it bounds a single frame and, across
/// continuation frames, a reassembled message, and a peer that announces more fails the connection
/// with `1009`.
///
/// `max_queue` is how many received messages wait for the application. Once it is full nothing more
/// is read from the socket, so a client that outruns its application is held back by TCP.
///
/// `ping_interval` is the milliseconds between keepalive pings, and `ping_timeout` how long a pong
/// may take before the connection fails with `1011`. `None` turns either off.
///
/// `deflate` accepts permessage-deflate (RFC 7692) when a client offers it.
pub(all) struct WsConfig {
  max_size : Int32
  max_queue : Int32
  ping_interval : Int32?
  ping_timeout : Int32?
  deflate : Bool
}

///|
/// How many received messages wait for the application (uvicorn's `--ws-max-queue`).
pub let ws_max_queue : Int32 = 32

///|
/// The milliseconds between pings, and the wait for a pong (uvicorn's 20 seconds each).
pub let ws_ping : Int32 = 20000

///|
/// A `WsConfig` from uvicorn's defaults, `max_size` its 16 MiB.
pub fn WsConfig::new(
  max_size~ : Int32 = @ws.limit,
  max_queue~ : Int32 = ws_max_queue,
  ping_interval~ : Int32? = Some(ws_ping),
  ping_timeout~ : Int32? = Some(ws_ping),
  deflate~ : Bool = true,
) -> WsConfig {
  { max_size, max_queue, ping_interval, ping_timeout, deflate, }
}

///|
/// How the server runs the lifespan protocol (← uvicorn's `--lifespan`).
#derive(Eq, Debug)
pub(all) enum Lifespan {
  /// Run it, and carry on without it when the application fails on the lifespan scope, as one
  /// that serves only HTTP does.
  Auto
  /// Run it, and refuse to start when the application fails on it.
  On
  /// Do not run it.
  Off
}

///|
pub extend Lifespan with Eq::{equal, not_equal}

///|
pub extend Lifespan with Debug::{to_repr}

///|
/// What the server does with a request a client sent before its handshake had finished — early
/// data, in the TLS 1.3 and QUIC sense (RFC 8446 §4.2.10, RFC 9000 §12). Such a request can be
/// replayed by whoever saw it, so RFC 8470 makes it the origin's to judge. `Off` is the default:
/// a replayable request is only taken when the server was explicitly configured to take it.
#derive(Eq, Debug)
pub(all) enum EarlyData {
  /// Take it, and tell the application the request may be a replay. Explicit opt-in.
  Accept
  /// Answer `425 Too Early` and never run the application.
  Refuse
  /// Do not offer it: no ticket carries an allowance, so no client can send any.
  Off
}

///|
pub extend EarlyData with Eq::{equal, not_equal}

///|
pub extend EarlyData with Debug::{to_repr}

///|
/// How much a client may send in 0-RTT under one ticket, in bytes: 16 KiB, room for a request
/// head and a small body, small enough that replaying one costs little.
pub let early_data_size : Int32 = 16384

///|
/// The HTTP/2 knobs. The stream ceiling, header-list cap and frame cap are hypercorn's
/// (`h2_max_concurrent_streams`, `h2_max_header_list_size`, `h2_max_inbound_frame_size`). The
/// receive windows are Go's server's (`MaxUploadBufferPerStream`, `MaxUploadBufferPerConnection`):
/// the protocol's own 64 KiB lets a client upload one window per round trip.
///
/// A stream's window comes back as the application takes its body, so a client cannot get further
/// ahead of an application than `window` octets on a stream and `connection_window` in all.
pub(all) struct H2Config {
  max_streams : Int32
  max_header_list : Int32
  max_frame : Int32
  window : Int32
  connection_window : Int32
}

///|
/// A `H2Config` with every field at its default: 100 concurrent streams, a 64 KiB field block,
/// 16 KiB frames, and 1 MiB of flow-control window on a stream and on the connection.
pub fn H2Config::new(
  max_streams~ : Int32 = 100,
  max_header_list~ : Int32 = 1 << 16,
  max_frame~ : Int32 = 1 << 14,
  window~ : Int32 = 1 << 20,
  connection_window~ : Int32 = 1 << 20,
) -> H2Config {
  { max_streams, max_header_list, max_frame, window, connection_window, }
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
  port : Int32
  backlog : Int32
  dual_stack : Bool
  reuse_addr : Bool
  server_headers : Map[String, String]
  max_connections : Int32?
  allow_failure : Bool
  graceful_timeout : Int32?
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
  timeout_keep_alive : Int32
  // How long a TLS handshake may take, in milliseconds (← hypercorn's and asyncio's
  // `ssl_handshake_timeout`, 60 seconds). A peer that connects and never finishes the
  // handshake holds a connection slot the way an idle keep-alive one does.
  timeout_handshake : Int32
  // Stop serving after this many requests (← uvicorn's `--limit-max-requests`), the
  // knob a supervisor uses to recycle a worker before it accumulates whatever it
  // accumulates. `None` serves forever.
  limit_max_requests : Int32?
  // The concurrent-request ceiling above which a request is refused with `503`
  // (← uvicorn's `--limit-concurrency`). Distinct from `max_connections`, which makes
  // a client *wait* for a slot; this one answers rather than queues.
  limit_concurrency : Int32?
  // The cap on a request's head, request line and header block together, in bytes
  // (← uvicorn's `--h11-max-incomplete-event-size`). A peer that never sends the
  // terminating blank line must not be able to grow the buffer without limit.
  max_head_size : Int32
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
  // The HTTP/2 stream and flow-control limits.
  h2 : H2Config
  // Whether and how the lifespan protocol runs (← uvicorn's `--lifespan`, `auto` by default).
  lifespan : Lifespan
  // Whether a TLS listener also serves the clear on the same port: a connection that opens with
  // a TLS handshake record is served TLS, any other plain HTTP. The family serves both on one
  // port rather than keeping a second one for TLS.
  cleartext : Bool
  // How many processes serve (← uvicorn's `--workers`). Above 1 the process that was started only
  // supervises: it runs this same program that many times and replaces any that die. Linux only,
  // because that is where the kernel shares a port across processes.
  workers : Int32
  // What a request that arrived in 0-RTT gets: taken and marked, answered `425`, or not offered at
  // all (RFC 8470). Only a listener that can take early data — TLS 1.3 over QUIC — reads it.
  early_data : EarlyData
  // How much early data one ticket allows, in bytes.
  early_data_size : Int32
}

///|
/// The default port for the TCP serving entry points.
///
/// HTTP/1.1, WebSocket upgrades and HTTP/2 share one listener, told apart by ALPN
/// under TLS and by the HTTP/2 preface in the clear. `quic_serve` takes an explicit
/// UDP address; it may use the same number because UDP and TCP have separate port
/// spaces.
pub let port : Int32 = 12000

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
///
/// `early_data` defaults to `Off`: early data can be replayed (RFC 8470 §2), so
/// taking it is an explicit decision, not a side effect of enabling HTTP/3.
/// nginx takes the same side with `ssl_early_data`, off unless switched on.
pub fn Config::new(
  host~ : String = "127.0.0.1",
  port~ : Int32 = port,
  backlog~ : Int32 = 2048,
  dual_stack~ : Bool = false,
  reuse_addr~ : Bool = true,
  server_headers~ : Map[String, String] = Map([("server", "mooncat")]),
  max_connections? : Int32,
  allow_failure~ : Bool = true,
  graceful_timeout? : Int32,
  root_path~ : String = "",
  logger~ : Logger = Logger::new(),
  timeout_keep_alive~ : Int32 = 5000,
  timeout_handshake~ : Int32 = 60000,
  limit_max_requests? : Int32,
  limit_concurrency? : Int32,
  max_head_size~ : Int32 = 16 * 1024,
  date_header~ : Bool = true,
  proxy_headers~ : Bool = true,
  forwarded_allow_ips~ : Array[String] = ["127.0.0.1"],
  ws~ : WsConfig = WsConfig::new(),
  h2~ : H2Config = H2Config::new(),
  lifespan~ : Lifespan = Auto,
  cleartext~ : Bool = true,
  workers~ : Int32 = 1,
  early_data~ : EarlyData = Off,
  early_data_size~ : Int32 = early_data_size,
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
    timeout_handshake,
    limit_max_requests,
    limit_concurrency,
    max_head_size,
    date_header,
    proxy_headers,
    forwarded_allow_ips,
    ws,
    h2,
    lifespan,
    cleartext,
    workers,
    early_data,
    early_data_size,
  }
}

///|
/// The `host:port` string used to resolve the listen address.
pub fn Config::bind(self : Config) -> String {
  "\{self.host}:\{self.port}"
}
