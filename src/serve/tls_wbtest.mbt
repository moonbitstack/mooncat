// HTTP/2 under TLS and beside HTTP/1.1 on one port, driven by a real HTTP/2 client.

///|
/// A client that trusts exactly the test certificate. It is self-signed and marked as a CA, which
/// path validation refuses as a leaf, so the client pins it instead.
async fn pinned(alpn : Array[String]) -> @tls.Client {
  let der = @x509.pems(@fs.read_file("src/certs/cert.pem").text())[0]
  @tls.Client::new(
    @x509.Roots::new(),
    alpn~,
    verify=Custom((chain, _) => {
      if chain[0] != der {
        fail("not the test certificate")
      }
    }),
  )
}

///|
fn text_app(text : String) -> @moonasgi.AsgiApp {
  (scope, _receive, send) => {
    guard scope is Http(_) else { return }
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(
        body=@utf8.encode(text),
        more_body=false,
      ),
    )
  }
}

///|
async test "h2: a client that picks h2 by ALPN is served HTTP/2 over TLS" {
  let port = 18445
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_tls_config(
        text_app("hello over h2"),
        @config.Config::new(port~, logger=@config.Logger::silent()),
        test_cert(),
      )
    })
    @async.sleep(400)
    let conn = @tcp.dial("127.0.0.1", port~, tls=pinned(["h2", "http/1.1"]))
    assert_eq(conn.alpn(), Some("h2"))
    let (status, headers, body) = h2_request(
      conn, "https", "localhost", "GET", "/",
    )
    assert_eq(status, "200")
    assert_eq(body, b"hello over h2")
    assert_true(has_header(headers, "content-type", "text/plain"))
    let old = @tcp.dial("127.0.0.1", port~, tls=pinned(["http/1.1"]))
    defer old.close()
    assert_eq(old.alpn(), Some("http/1.1"))
    old.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    assert_true(old.read_until("\r\n").unwrap_or("").has_prefix("HTTP/1.1 200"))
    task.cancel()
  })
}

///|
async test "h2: in the clear one port serves HTTP/1.1 and HTTP/2 by prior knowledge" {
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_config(
        text_app("either way"),
        @config.Config::new(port=18446, logger=@config.Logger::silent()),
      )
    })
    @async.sleep(400)
    let (status, _, body) = h2c_request("127.0.0.1", 18446, "GET", "/")
    assert_eq(status, "200")
    assert_eq(body, b"either way")
    let sock = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:18446"))
    defer sock.close()
    sock.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    assert_true(
      sock.read_until("\r\n").unwrap_or("").has_prefix("HTTP/1.1 200"),
    )
    task.cancel()
  })
}

///|
/// Answers with the scope's scheme and HTTP version.
fn scheme_app() -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    guard scope is Http(h) else { return }
    ignore(receive())
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(
      HttpResponseBody(
        body=@utf8.encode("\{h.scheme} \{h.http_version}"),
        more_body=false,
      ),
    )
  }
}

///|
/// Send one HTTP/1.1 request on `conn` and return everything until the peer closes.
async fn h1_exchange(conn : @tcp.Conn) -> String {
  conn.write("GET / HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n")
  let got = StringBuilder()
  while (conn.read_some() catch { _ => None }) is Some(more) {
    got.write_string(@utf8.decode_lossy(more))
  }
  got.to_string()
}

///|
/// The family's rule: TLS takes no port of its own. One listener answers TLS by its handshake
/// record and the clear otherwise, HTTP/1.1 and HTTP/2 both.
async test "tls: one port serves https, http and h2c" {
  let port = 18450
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_tls_config(
        scheme_app(),
        @config.Config::new(port~, logger=@config.Logger::silent()),
        test_cert(),
      )
    })
    @async.sleep(400)
    let secure = h1_exchange(
      @tcp.dial("127.0.0.1", port~, tls=pinned(["http/1.1"])),
    )
    assert_true(secure.has_suffix("https 1.1"))
    let clear = h1_exchange(@tcp.dial("127.0.0.1", port~))
    assert_true(clear.has_suffix("http 1.1"))
    let (status, _, body) = h2c_request("127.0.0.1", port, "GET", "/")
    assert_eq(status, "200")
    assert_eq(body, b"http 2")
    task.cancel()
  })
}

///|
async test "tls: with cleartext off a TLS port does not serve the clear" {
  let port = 18451
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_tls_config(
        scheme_app(),
        @config.Config::new(
          port~,
          cleartext=false,
          logger=@config.Logger::silent(),
        ),
        test_cert(),
      )
    })
    @async.sleep(400)
    let clear = h1_exchange(@tcp.dial("127.0.0.1", port~))
    assert_false(clear.contains("HTTP/1.1 200"))
    let secure = h1_exchange(
      @tcp.dial("127.0.0.1", port~, tls=pinned(["http/1.1"])),
    )
    assert_true(secure.has_suffix("https 1.1"))
    task.cancel()
  })
}

///|
async test "tls: a certificate loads with the TLS 1.2 suites it is given" {
  let chosen = @record.all12[:2].to_owned()
  assert_eq(test_cert().load(suites12=chosen).suites12, chosen)
  assert_eq(test_cert().load().suites12, @tls.suites12)
}

///|
async test "resumption is on unless the caller turns it off, and 0-RTT stays off whatever it says" {
  assert_true(test_cert().load().tickets.is_on())
  assert_false(test_cert().load(tickets=@tls.tickets).tickets.is_on())
  let key = Bytes::make(32, b'')
  let on = test_cert().load(tickets=@tls.Tickets::new([key][:], early=1024))
  assert_true(on.tickets.is_on())
  assert_eq(on.tickets.early, 0)
}

///|
/// A key's public half, encoded, which is what tells two keys apart.
fn public_of(key : @x509.PrivateKey) -> Bytes {
  @x509.Spki::encode(key.public())
}

///|
/// Whether reading `cert` is refused.
async fn refused(cert : TlsCert) -> Bool {
  try {
    ignore(cert.read())
    false
  } catch {
    _ => true
  }
}

///|
async test "an encrypted key opens with its password and gives the plain key" {
  let plain = test_cert().read()
  let encrypted = TlsCert::pem(
    "src/certs/cert.pem",
    "src/certs/key.enc.pem",
    password="moon",
  ).read()
  assert_eq(encrypted.0, plain.0)
  assert_eq(public_of(encrypted.1), public_of(plain.1))
  assert_true(
    refused(
      TlsCert::pem(
        "src/certs/cert.pem",
        "src/certs/key.enc.pem",
        password="sun",
      ),
    ),
  )
  // Without a password the encrypted key is not a key at all.
  assert_true(
    refused(TlsCert::pem("src/certs/cert.pem", "src/certs/key.enc.pem")),
  )
}

///|
async test "a PKCS#12 file gives the PEM pair's leaf and key, and a server takes them" {
  let plain = test_cert().read()
  let pfx = TlsCert::pkcs12("src/certs/server.p12", password="moon")
  let (chain, key) = pfx.read()
  assert_eq(chain[0], plain.0[0])
  assert_eq(public_of(key), public_of(plain.1))
  // The server checks at startup that the key is the leaf's.
  ignore(pfx.load())
  assert_true(refused(TlsCert::pkcs12("src/certs/server.p12", password="sun")))
}
