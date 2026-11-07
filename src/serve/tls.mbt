///|
/// Where the certificate chain and private key an HTTPS server presents come from. The same files
/// serve on every platform: the TLS is moontls, not the system's.
pub(all) enum TlsCert {
  /// PEM files (← uvicorn's `ssl_certfile`, `ssl_keyfile` and `ssl_keyfile_password`). The chain
  /// file holds the leaf first, then any intermediates; the key file holds a `PRIVATE KEY`,
  /// `EC PRIVATE KEY` or `RSA PRIVATE KEY`, or an `ENCRYPTED PRIVATE KEY` opened with `password`.
  Pem(
    certificate_file~ : String,
    private_key_file~ : String,
    password~ : String?
  )
  /// A PKCS#12 file, `.p12` or `.pfx` (RFC 7292), holding the chain and the key under one password
  /// (← Tomcat's `PKCS12` keystore, Kestrel's `.pfx`). An empty password opens an unprotected one.
  Pkcs12(file~ : String, password~ : String)
}

///|
/// A chain and key in PEM files.
pub fn TlsCert::pem(
  certificate_file : String,
  private_key_file : String,
  password? : String,
) -> TlsCert {
  Pem(certificate_file~, private_key_file~, password~)
}

///|
/// A chain and key in one PKCS#12 file.
pub fn TlsCert::pkcs12(file : String, password~ : String = "") -> TlsCert {
  Pkcs12(file~, password~)
}

///|
/// The chain, leaf first, and the key the files hold. A PKCS#12 file does not promise an order,
/// so the certificate that holds the key's public half is moved to the front.
pub async fn TlsCert::read(self : TlsCert) -> (Array[Bytes], @x509.PrivateKey) {
  match self {
    Pem(certificate_file~, private_key_file~, password~) => {
      let key_text = @fs.read_file(private_key_file).text()
      let key = match password {
        Some(password) =>
          @x509.PrivateKey::pem_encrypted(key_text, passphrase=password)
        None => @x509.PrivateKey::pem(key_text)
      }
      (@x509.pems(@fs.read_file(certificate_file).text()), key)
    }
    Pkcs12(file~, password~) => {
      let pfx = @pkcs12.parse(@fs.read_file(file).binary()[:])
      let contents = pfx.contents(passphrase=password)
      guard contents.key is Some(der) else {
        raise @pkcs12.Refused::Malformed(
          "the PKCS#12 file holds no private key",
        )
      }
      let key = @x509.PrivateKey::read(der[:])
      let public = key.public()
      let leaf = contents.certs.search_by(cert => {
        @x509.parse(cert[:]).spki.holds(public) catch {
          _ => false
        }
      })
      let chain = match leaf {
        Some(at) =>
          [contents.certs[at]] +
          contents.certs.filter(cert => cert != contents.certs[at])
        None => contents.certs
      }
      (chain, key)
    }
  }
}

///|
/// The application protocols a TLS listener offers, in preference order: HTTP/2 first, as
/// hypercorn and nginx do, falling back to HTTP/1.1.
pub let alpn : Array[String] = ["h2", "http/1.1"]

///|
/// Read the files into a TLS server configuration. A key that is not the leaf's is refused here,
/// at startup, rather than by every client's handshake.
///
/// Session resumption is on, as it is by default in nginx, Go and OpenSSL, under a ticket key made
/// here for this process. Pass `tickets` to choose the keys, which is how several workers come to
/// share them, or `@tls.tickets` to turn it off. A ticket this process cannot open costs a full
/// handshake and nothing else.
///
/// `early` is how much a client may send before its handshake finishes, under a ticket this server
/// issued: 0, the default, offers none. Early data over TLS on a TCP connection is not taken —
/// a request has to be answered before it can be judged, and a byte stream has no way to hold one
/// back — so only a QUIC listener asks for it.
pub async fn TlsCert::load(
  self : TlsCert,
  alpn~ : Array[String] = alpn,
  suites~ : Array[@record.Suite] = @tls.suites,
  suites12~ : Array[@record.Suite12] = @tls.suites12,
  tickets? : @tls.Tickets,
  early~ : Int32 = 0,
) -> @tls.Server {
  let tickets = match (tickets, @env.rand(32)) {
    (Some(tickets), _) => tickets
    (None, Some(key)) => @tls.Tickets::new([key][:])
    // No entropy to make a key with, so no tickets.
    (None, None) => @tls.tickets
  }
  let (chain, key) = self.read()
  @tls.Server::new(chain, key, alpn~, suites~, suites12~, tickets={
    ..tickets,
    early,
  })
}

///|
/// Serve a moonasgi ASGI application over native HTTP/1.1 **over TLS** (HTTPS,
/// ← uvicorn's `--ssl-certfile`/`--ssl-keyfile`). Convenience wrapper over
/// `serve_tls_config` that builds the `Config` from `host`/`port`/`backlog` and
/// the certificate paths.
///
/// Runs the full ASGI lifespan protocol around the accept loop (startup before
/// the listener binds, shutdown on exit — even under cancellation), then, for
/// every accepted connection, completes a TLS handshake and serves HTTP/2 when
/// ALPN settles on `h2`, HTTP/1.1 otherwise.
///
/// A WebSocket upgrade on an HTTP/1.1 connection is served too (`wss://`): the
/// 101, the subprotocol echo and the frames all travel over the encrypted stream.
pub async fn serve_tls(
  app : @moonasgi.AsgiApp,
  certificate_file~ : String,
  private_key_file~ : String,
  password? : String,
  host~ : String = "127.0.0.1",
  port~ : Int32 = @config.port,
  backlog~ : Int32 = 2048,
  listening? : Listening,
) -> Unit {
  serve_tls_config(
    app,
    @config.Config::new(host~, port~, backlog~),
    TlsCert::pem(certificate_file, private_key_file, password?),
    listening?,
  )
}

///|
/// Serve a moonasgi ASGI application over HTTPS under an explicit `Config` and
/// `TlsCert`. Mirrors `serve_config`: lifespan startup is driven before the
/// listener binds and shutdown on the way out (guarded by `protect_from_cancel`
/// so it still runs when the serving task is cancelled), and each accepted
/// connection completes a TLS handshake within `timeout_handshake` and then runs
/// the same loop as a plain one.
pub async fn serve_tls_config(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  cert : TlsCert,
  listening? : Listening,
) -> Unit {
  serve_tls_server(app, config, cert.load(), listening?)
}

///|
/// Serve over HTTPS with a TLS configuration built by the caller: the suites, the groups, the
/// ALPN list and the certificates are all `server`'s. `serve_tls_config` is this with the
/// configuration read from PEM files.
pub async fn serve_tls_server(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  server : @tls.Server,
  listening? : Listening,
) -> Unit {
  run(app, config, ShutdownHandle::new(), Some(server), Both, listening?)
}

///|
/// Serve over HTTPS with another listener beside the TCP one, which runs from the moment the
/// application has started until the requests in flight everywhere have drained.
///
/// `alt_svc` is a header value to advertise the neighbour with, in which `{port}` is replaced by the
/// port the socket actually got — which is the only way to name it when the caller asked for port 0.
pub async fn serve_tls_beside(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  server : @tls.Server,
  beside : async (Site) -> Unit,
  alt_svc~ : String = "",
  listening? : Listening,
) -> Unit {
  run(
    app,
    config,
    ShutdownHandle::new(),
    Some(server),
    Both,
    beside~,
    alt_svc~,
    listening?,
  )
}

///|
/// Self-signed localhost material for the integration tests below, generated by
/// `scripts/certs/gen-cert.sh`.
fn test_cert() -> TlsCert {
  TlsCert::pem("src/certs/cert.pem", "src/certs/key.pem")
}

///|
/// Real HTTPS round-trip: a genuine `@http` TLS client performs `GET /` over an
/// encrypted connection to a `serve_tls`-served app and observes `200` + the
/// exact body. The client is the system's TLS (OpenSSL or SChannel), so this is
/// moontls against another implementation, through the HTTP/1.1 codec to the app.
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
    let listening = Listening::new()
    let task = g.spawn(() => {
      serve_tls_config(
        app,
        @config.Config::new(port=0),
        test_cert(),
        listening~,
      )
    })
    let client = @http.Client::Client(
      "https://" + listening.addr().to_string(),
      trust=NoVerification,
    )
    let resp = client.get("/")
    assert_eq(resp.code, 200)
    assert_eq(client.read_all().text(), "secure hello over tls")
    client.close()
    task.cancel()
  })
}
