///|
/// TLS certificate material for HTTPS serving (← uvicorn's `ssl_certfile` /
/// `ssl_keyfile`). The backend the `moonbitlang/async` TLS layer uses is
/// platform-specific, so both forms are carried:
///
/// * `certificate_file` + `private_key_file` — PEM files, used by the OpenSSL
///   backend (Linux / macOS, the CI platforms);
/// * `pfx_file` — a PKCS#12 bundle, used by the SChannel backend (Windows).
///
/// `serve_tls` picks the right pair at compile time. Supply whichever your
/// deployment targets; a self-signed `certs/` pair for tests is generated with
/// `scripts/gen_test_cert.sh`.
pub(all) struct TlsCert {
  certificate_file : String
  private_key_file : String
  pfx_file : String
}

///|
/// Wrap an accepted TCP connection in a TLS server session on the OpenSSL
/// backend, reading the certificate/key from PEM files.
///
/// The async library marks its TLS-server constructor `#internal` ("for
/// internal testing only") — it is the only server-side TLS entry point it
/// exposes, and its own test suite drives HTTPS through exactly this call. The
/// package opts in via `warnings = "-alert_internal"` in `moon.pkg`; when the
/// library graduates a public TLS-server API mooncat will move to it. This is
/// the sole such opt-in and is the documented TLS boundary (README §TLS).
#cfg(not(platform="windows"))
async fn tls_accept(conn : @socket.Tcp, cert : TlsCert) -> @tls.Tls {
  @tls.Tls::server_from_pair(
    conn,
    conn,
    private_key_file=cert.private_key_file,
    private_key_type=PEM,
    certificate_file=cert.certificate_file,
    certificate_type=PEM,
  )
}

///|
/// Wrap an accepted TCP connection in a TLS server session on the SChannel
/// backend (Windows), reading the certificate + key from a PKCS#12 bundle.
/// See `tls_accept` (OpenSSL) for the `#internal` opt-in rationale.
#cfg(platform="windows")
async fn tls_accept(conn : @socket.Tcp, cert : TlsCert) -> @tls.Tls {
  @tls.Tls::server_from_pair(conn, conn, pfx_file=cert.pfx_file)
}

///|
/// Handle one accepted TCP connection as an HTTPS connection: perform the TLS
/// handshake, then loop the self-built HTTP/1.1 codec (`parse_http1_request` +
/// `dispatch_http1`) over the encrypted stream, honouring keep-alive, until the
/// peer closes or asks to close. The TLS session is always torn down on the way
/// out. A handshake or I/O failure raises and is contained by the accept loop's
/// `allow_failure`, exactly as a bad plaintext connection would be.
async fn handle_https_conn(
  app : @moonasgi.AsgiApp,
  conn : @socket.Tcp,
  peer : @socket.Addr,
  cert : TlsCert,
  config : Config,
) -> Unit {
  let tls = tls_accept(conn, cert)
  defer tls.close()
  for ;; {
    guard next_head(tls, config) is Some(req) else { break }
    let keep = dispatch_http1(
      app,
      req,
      tls,
      tls,
      scheme="https",
      config~,
      client_addr=peer,
    )
    if !keep {
      break
    }
  }
}

///|
/// Serve a moonasgi ASGI application over native HTTP/1.1 **over TLS** (HTTPS,
/// ← uvicorn's `--ssl-certfile`/`--ssl-keyfile`). Convenience wrapper over
/// `serve_tls_config` that builds the `Config` from `host`/`port`/`backlog` and
/// the certificate paths.
///
/// Runs the full ASGI lifespan protocol around the accept loop (startup before
/// the listener binds, shutdown on exit — even under cancellation), then, for
/// every accepted connection, completes a TLS handshake and drives the app
/// through the encrypted HTTP/1.1 codec.
///
/// WebSocket-over-TLS (`wss://`) is not bridged here: the async websocket
/// upgrade requires an `@http.ServerConnection`, which is welded to
/// `@socket.Tcp` and cannot wrap a `@tls.Tls` stream. Plaintext `serve` retains
/// full WebSocket support; this is a transport-capability boundary, not a
/// behavioural choice (README §TLS).
pub async fn serve_tls(
  app : @moonasgi.AsgiApp,
  certificate_file~ : String,
  private_key_file~ : String,
  pfx_file~ : String,
  host? : String = "127.0.0.1",
  port? : Int = port,
  backlog? : Int = 2048,
) -> Unit {
  serve_tls_config(app, Config::new(host~, port~, backlog~), {
    certificate_file,
    private_key_file,
    pfx_file,
  })
}

///|
/// Serve a moonasgi ASGI application over HTTPS under an explicit `Config` and
/// `TlsCert`. Mirrors `serve_config`: lifespan startup is driven before the
/// listener binds and shutdown on the way out (guarded by `protect_from_cancel`
/// so it still runs when the serving task is cancelled), and each accepted
/// connection is handled by `handle_https_conn`.
pub async fn serve_tls_config(
  app : @moonasgi.AsgiApp,
  config : Config,
  cert : TlsCert,
) -> Unit {
  @async.with_task_group(g => {
    let lifespan = Lifespan::new(app)
    let task = lifespan.spawn(g)
    lifespan.startup(task)
    let server = @socket.TcpServer(
      @socket.Addr::parse(config.bind()),
      dual_stack=config.dual_stack,
      reuse_addr=config.reuse_addr,
    )
    defer {
      @async.protect_from_cancel(() => lifespan.shutdown(task) catch { _ => () })
      server.close()
    }
    server.run_forever(
      (conn, addr) => handle_https_conn(app, conn, addr, cert, config),
      allow_failure=config.allow_failure,
      max_connections?=config.max_connections,
    )
  })
}

///|
/// Self-signed localhost material for the integration tests below, generated by
/// `scripts/gen_test_cert.sh`. PEM for OpenSSL platforms, PKCS#12 for Windows.
fn test_cert() -> TlsCert {
  {
    certificate_file: "certs/cert.pem",
    private_key_file: "certs/key.pem",
    pfx_file: "certs/dev.pfx",
  }
}

///|
/// Real HTTPS round-trip: a genuine `@http` TLS client performs `GET /` over an
/// encrypted connection to a `serve_tls`-served app and observes `200` + the
/// exact body. Proves the TLS handshake, the self-built HTTP/1.1 codec over the
/// `@tls.Tls` stream, and the moonasgi SEAM all cooperate end to end.
async test "https: real TLS client GET returns 200 with body" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[("content-type", "text/plain")],
          trailers=false,
        ),
      )
      send(
        @moonasgi.Event::HttpResponseBody(
          body=b"secure hello over tls",
          more_body=false,
        ),
      )
    }
    let task = g.spawn(() => {
      serve_tls_config(app, Config::new(port=18443), test_cert())
    })
    @async.sleep(400)
    let client = @http.Client::Client(
      "https://127.0.0.1:18443",
      trust=NoVerification,
    )
    let resp = client.get("/")
    assert_eq(resp.code, 200)
    assert_eq(client.read_all().text(), "secure hello over tls")
    client.close()
    task.cancel()
  })
}
