// HTTP/2 under TLS and beside HTTP/1.1 on one port, driven by a real HTTP/2 client.

///|
/// A client that trusts exactly the test certificate. It is self-signed and marked as a CA, which
/// path validation refuses as a leaf, so the client pins it instead.
async fn pinned(alpn : Array[String]) -> @tls.Client {
  let der = @x509.pems(@fs.read_file(test_cert().certificate_file).text())[0]
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
