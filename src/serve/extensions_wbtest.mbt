// The ASGI extensions mooncat honours, and the scope HTTP/2 hands an application, which must be
// the one HTTP/1.1 hands it.

///|
/// An application that reports what its scope says, one `key=value` per line.
fn reporting() -> @moonasgi.AsgiApp {
  (scope, _receive, send) => {
    guard scope is Http(h) else { return }
    let ext = h.extensions
    let lines = [
      "path=\{h.path}",
      "raw=\{@utf8.decode_lossy(h.raw_path[:])}",
      "root=\{h.root_path}",
      "scheme=\{h.scheme}",
      "client=\{h.client is Some(_)}",
      "early_hint=\{ext.http_response_early_hint}",
      "trailers=\{ext.http_response_trailers}",
      "tls_version=\{ext.tls.bind(t => t.tls_version).unwrap_or(0)}",
      "suite=\{ext.tls.bind(t => t.cipher_suite).unwrap_or(0)}",
      "cert=\{ext.tls.bind(t => t.server_cert).map(c => c.has_prefix("-----BEGIN CERTIFICATE-----")).unwrap_or(false)}",
    ]
    send(HttpResponseStart(status=200, headers=[], trailers=false))
    send(HttpResponseBody(body=@utf8.encode(lines.join("\n")), more_body=false))
  }
}

///|
/// An application that sends a 103, then its answer with trailers.
fn hinting() -> @moonasgi.AsgiApp {
  (_scope, _receive, send) => {
    send(HttpResponseEarlyHint(links=["</style.css>; rel=preload"]))
    send(
      HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=true,
      ),
    )
    send(HttpResponseBody(body=b"hello", more_body=false))
    send(HttpResponseTrailers(headers=[("x-check", "ok")], more_trailers=false))
  }
}

///|
async test "extensions: under TLS the scope carries the version, the suite and the certificate, on both versions" {
  let port = 18447
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_tls_config(
        reporting(),
        @config.Config::new(
          port~,
          root_path="/api",
          logger=@config.Logger::silent(),
        ),
        test_cert(),
      )
    })
    @async.sleep(400)
    let h2 = @tcp.dial("127.0.0.1", port~, tls=pinned(["h2"]))
    let suite = h2.tls().bind(t => t.suite()).map(s => s.code()).unwrap_or(-1)
    let (_, _, two) = h2_request(h2, "https", "localhost", "GET", "/a%2Fb?q=1")
    let seen = @utf8.decode_lossy(two[:])
    for
      line in [
        "path=/a/b",
        "raw=/a%2Fb",
        "root=/api",
        "scheme=https",
        "client=true",
        "early_hint=true",
        "trailers=true",
        "tls_version=772",
        "suite=\{suite}",
        "cert=true",
      ] {
      assert_true(seen.contains(line), msg="\{line} in \{seen}")
    }
    let h1 = @tcp.dial("127.0.0.1", port~, tls=pinned(["http/1.1"]))
    defer h1.close()
    h1.write(
      "GET /a%2Fb HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    )
    let one = h1.read_all().text()
    for
      line in [
        "path=/a/b", "root=/api", "scheme=https", "tls_version=772", "cert=true",
      ] {
      assert_true(one.contains(line), msg="\{line} in \{one}")
    }
    task.cancel()
  })
}

///|
async test "extensions: a 103 goes before the answer and trailers after it, over HTTP/1.1" {
  let port = 18448
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_config(
        hinting(),
        @config.Config::new(port~, logger=@config.Logger::silent()),
      )
    })
    @async.sleep(400)
    let sock = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
    defer sock.close()
    sock.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    let text = sock.read_all().text()
    assert_true(
      text.has_prefix(
        "HTTP/1.1 103 Early Hints\r\nlink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\n",
      ),
      msg=text,
    )
    assert_true(text.contains("transfer-encoding: chunked\r\n"), msg=text)
    assert_true(
      text.has_suffix("5\r\nhello\r\n0\r\nx-check: ok\r\n\r\n"),
      msg=text,
    )
    task.cancel()
  })
}

///|
async test "extensions: a 103 and trailers over HTTP/2" {
  let port = 18449
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_tls_config(
        hinting(),
        @config.Config::new(port~, logger=@config.Logger::silent()),
        test_cert(),
      )
    })
    @async.sleep(400)
    let conn = @tcp.dial("127.0.0.1", port~, tls=pinned(["h2"]))
    let (status, headers, body) = h2_request(
      conn, "https", "localhost", "GET", "/",
    )
    assert_eq(status, "200")
    assert_eq(body, b"hello")
    assert_true(has_header(headers, "link", "</style.css>; rel=preload"))
    assert_true(has_header(headers, "x-check", "ok"))
    task.cancel()
  })
}
