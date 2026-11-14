///|
/// A connection's inbox over a pipe that already holds `wire` and is closed.
async fn inbox_of(wire : String) -> Inbox {
  let (r, w) = @pipe.pipe()
  w.write(@utf8.encode(wire))
  w.close()
  Inbox::new(r)
}

///|
/// Two requests in one segment are two requests.
///
/// A client that pipelines sends the second before the first is answered, and
/// `read_some` hands both back together. The inbox exists so that the second is still
/// there when the connection loop asks for it; before it, the octets past the first
/// head were whatever the read happened to leave in the reader.
async test "http1: two pipelined requests in one segment are both read" {
  let inbox = inbox_of(
    "GET /a HTTP/1.1\r\nhost: x\r\n\r\nGET /b HTTP/1.1\r\nhost: x\r\n\r\n",
  )
  let config = @config.Config::new(timeout_keep_alive=3000)
  guard next_head(inbox, config) is Some(first) else {
    fail("the first request should be read")
  }
  assert_eq(first.target, "/a")
  guard next_head(inbox, config) is Some(second) else {
    fail("the second request was in the same segment and should be read too")
  }
  assert_eq(second.target, "/b")
  // And then the peer has closed.
  assert_eq(next_head(inbox, config) is None, true)
}

///|
/// A body read after the head takes exactly its length, leaving the next request.
async test "http1: a sized body followed by the next request leaves that request intact" {
  let inbox = inbox_of(
    "POST /p HTTP/1.1\r\nhost: x\r\ncontent-length: 5\r\n\r\nhelloGET /q HTTP/1.1\r\nhost: x\r\n\r\n",
  )
  let config = @config.Config::new(timeout_keep_alive=3000)
  guard next_head(inbox, config) is Some(post) else {
    fail("the POST should be read")
  }
  assert_eq(post.body, Sized(5))
  assert_eq(inbox.exactly(5), b"hello")
  guard next_head(inbox, config) is Some(next) else {
    fail("the request after the body should be read")
  }
  assert_eq(next.target, "/q")
}

///|
/// The same for a chunked body, whose end is only known by reading it.
async test "http1: a chunked body followed by the next request leaves that request intact" {
  let inbox = inbox_of(
    "POST /c HTTP/1.1\r\nhost: x\r\ntransfer-encoding: chunked\r\n\r\n" +
    "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" +
    "GET /after HTTP/1.1\r\nhost: x\r\n\r\n",
  )
  let config = @config.Config::new(timeout_keep_alive=3000)
  guard next_head(inbox, config) is Some(post) else {
    fail("the POST should be read")
  }
  assert_eq(post.body, Chunked)
  assert_eq(inbox.chunks(), b"hello world")
  guard next_head(inbox, config) is Some(next) else {
    fail("the request after the chunked body should be read")
  }
  assert_eq(next.target, "/after")
}

///|
/// A head that smuggles is refused at the connection, not handed to the app.
///
/// The checks are moonhttp's; what this proves is that the server acts on them — a
/// refused head ends the connection rather than reaching dispatch.
async test "http1: a request that tries to smuggle a second one is not read" {
  let inbox = inbox_of(
    "POST / HTTP/1.1\r\nhost: x\r\ncontent-length: 5\r\ntransfer-encoding: chunked\r\n\r\n",
  )
  assert_eq(
    next_head(inbox, @config.Config::new(timeout_keep_alive=3000)) is None,
    true,
  )
}

///|
test "a request path is percent-decoded, and a stray escape is kept as written" {
  assert_eq(@utf8.decode_lossy(percent_decode("/a%20b/%E6%97%A5")), "/a b/日")
  assert_eq(percent_decode("/100%/%zz/%4"), b"/100%/%zz/%4")
}

///|
/// The whole of a sized body, for tests that check what follows it.
async fn Inbox::exactly(self : Inbox, n : Int32) -> Bytes {
  let buf = Buffer()
  while buf.length() < n {
    let part = self.upto(n - buf.length())
    if part.length() == 0 {
      break
    }
    buf.write_bytes(part)
  }
  buf.to_bytes()
}

///|
/// The whole of a chunked body, decoded.
async fn Inbox::chunks(self : Inbox) -> Bytes {
  let buf = Buffer()
  while self.next_chunk() is Some(part) {
    buf.write_bytes(part)
  }
  buf.to_bytes()
}

///|
async test "http1: a chunked request body decodes to the joined chunk data" {
  let (r, w) = @pipe.pipe()
  // Two data chunks ("hello" + " world") then the terminating zero chunk.
  w.write(b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
  w.close()
  assert_eq(Inbox::new(r).chunks() == b"hello world", true)
}

///|
async test "http1: a chunked body with a chunk extension and a trailer decodes cleanly" {
  let (r, w) = @pipe.pipe()
  // A chunk-size line carries a `;ext`, and a trailer field follows the zero chunk.
  w.write(b"4;n=v\r\ndata\r\n0\r\nx-checksum: 1\r\n\r\n")
  w.close()
  assert_eq(Inbox::new(r).chunks() == b"data", true)
}

///|
/// Send `raw` to a fresh server and return everything it answers before closing.
async fn exchange(raw : Bytes, config~ : @config.Config) -> String {
  let mut answer = ""
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(_) else { return }
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let listening = Listening::new()
    // Port 0: the system picks one, and the listener says which, so two of these can run at once.
    let srv = g.spawn(() => {
      serve_config(app, { ..config, port: 0, }, listening~)
    })
    let tcp = @socket.Tcp::connect(listening.addr())
    defer tcp.close()
    tcp.write(raw)
    answer = @utf8.decode_lossy(tcp.read_all().binary())
    srv.cancel()
  })
  answer
}

///|
/// uvicorn answers a request it cannot parse with `400` and a line saying so, rather than
/// dropping the connection and leaving the client to guess.
async test "a malformed request is answered 400 before the connection closes" {
  let answer = exchange(
    b"NOT HTTP AT ALL\r\n\r\n",
    config=@config.Config::new(logger=@config.Logger::silent()),
  )
  assert_true(answer.has_prefix("HTTP/1.1 400 Bad Request\r\n"))
  assert_true(answer.has_suffix("Invalid HTTP request received."))
}

///|
/// A head past `max_head_size` is the one refusal with its own status (RFC 6585 §5).
async test "a head past max_head_size is answered 431" {
  let big = "GET / HTTP/1.1\r\nhost: x\r\nx-filler: " +
    "a".repeat(200) +
    "\r\n\r\n"
  let answer = exchange(
    @utf8.encode(big),
    config=@config.Config::new(
      max_head_size=64,
      logger=@config.Logger::silent(),
    ),
  )
  assert_true(answer.has_prefix("HTTP/1.1 431 "))
}

///|
/// A chunked body reaches the app one chunk per event, as it arrives, then an empty
/// final event; it is not collected first.
async test "a chunked request body is delivered chunk by chunk" {
  let inbox = inbox_of("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
  let req = h1("POST", "HTTP/1.1", "transfer-encoding: chunked\r\n")
  let seen : Array[(String, Bool)] = []
  let app : @moonasgi.AsgiApp = (_scope, receive, send) => {
    for ;; {
      match receive() {
        HttpRequest(body~, more_body~) => {
          seen.push((@utf8.decode_lossy(body), more_body))
          if !more_body {
            break
          }
        }
        _ => break
      }
    }
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
  }
  let (_r, w) = @pipe.pipe()
  let keep = dispatch_http1(app, req, inbox, w)
  assert_eq(seen, [("hello", true), (" world", true), ("", false)])
  assert_true(keep)
}

///|
/// A body the app never read is still on the wire; keeping the connection would read it as
/// the next request, so the connection closes instead.
async test "a request body left unread closes the connection" {
  let inbox = inbox_of("hello")
  let req = h1("POST", "HTTP/1.1", "content-length: 5\r\n")
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
  }
  let (_r, w) = @pipe.pipe()
  assert_false(dispatch_http1(app, req, inbox, w))
}

///|
/// Read off `sock` until `marker` has arrived, failing past two seconds.
async fn read_until_marker(sock : @socket.Tcp, marker : String) -> String {
  let got = StringBuilder()
  let ok = @async.with_timeout_opt(2000, () => {
    while !got.to_string().contains(marker) {
      guard sock.read_some() is Some(more) else { break }
      got.write_string(@utf8.decode_lossy(more))
    }
  })
  guard ok is Some(_) else { fail("no \{marker} within two seconds") }
  got.to_string()
}

///|
/// uvicorn's rule over HTTP/1.1 too: an application listening for the client going while it
/// streams hears `http.disconnect` after its last chunk, not as soon as the body is read.
async test "http1: http.disconnect comes after the response, not straight after the body" {
  @async.with_task_group(g => {
    let order : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      ignore(receive())
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      @async.with_task_group(inner => {
        inner.spawn_bg(() => {
          if receive() is HttpDisconnect {
            order.push("disconnect")
          }
        })
        send(HttpResponseBody(body=b"tick", more_body=true))
        @async.sleep(200)
        order.push("last chunk")
        send(HttpResponseBody(body=b"", more_body=false))
      })
    }
    let listening = Listening::new()
    let task = g.spawn(() => {
      serve_config(
        app,
        @config.Config::new(port=0, logger=@config.Logger::silent()),
        listening~,
      )
    })
    let sock = @socket.Tcp::connect(listening.addr())
    sock.write(b"GET /stream HTTP/1.1\r\nhost: x\r\n\r\n")
    let text = read_until_marker(sock, "0\r\n\r\n")
    assert_true(text.contains("tick"))
    @async.sleep(50)
    assert_eq(order, ["last chunk", "disconnect"])
    sock.close()
    task.cancel()
  })
}

///|
async test "http1: a client that leaves mid-response is heard as http.disconnect" {
  @async.with_task_group(g => {
    let heard : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      ignore(receive())
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=b"first", more_body=true))
      if receive() is HttpDisconnect {
        heard.push("disconnect")
      }
    }
    let listening = Listening::new()
    let task = g.spawn(() => {
      serve_config(
        app,
        @config.Config::new(port=0, logger=@config.Logger::silent()),
        listening~,
      )
    })
    let sock = @socket.Tcp::connect(listening.addr())
    sock.write(b"GET / HTTP/1.1\r\nhost: x\r\n\r\n")
    ignore(read_until_marker(sock, "first"))
    sock.close()
    let reached = @async.with_timeout_opt(2000, () => {
      while heard.is_empty() {
        @async.sleep(10)
      }
    })
    assert_true(reached is Some(_))
    task.cancel()
  })
}

///|
async test "what RFC 9112 says to refuse is answered, and one empty line before a request is not refused" {
  let cases = [
    ("GET / HTTP/1.1\r\n\r\n", "400"),
    ("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", "400"),
    ("GET / HTTP/1.1\r\nHost: x\r\nA: b\u{0}c\r\n\r\n", "400"),
    ("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: xchunked\r\n\r\n", "400"),
    (
      "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", "501",
    ),
    ("GET / HTTP/2.0\r\nHost: x\r\n\r\n", "505"),
    ("\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "200"),
  ]
  for case in cases {
    let (wire, status) = case
    let answer = exchange(
      @utf8.encode(wire),
      config=@config.Config::new(logger=@config.Logger::silent()),
    )
    assert_true(answer.has_prefix("HTTP/1.1 \{status} "))
  }
}

///|
/// Run `app` for a GET over pipes, and return the octets the client has once it holds a whole
/// head, with the app still waiting for `seen` (an event stream's next event). A server that
/// held the head until the first body never gets there; `None` is that.
async fn head_while_waiting(
  version : String,
  app : (Ref[Bool], @cond_var.Cond) -> @moonasgi.AsgiApp,
) -> (Bytes, Bytes)? {
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (resp_r, resp_w) = @pipe.pipe()
  let seen = Ref(false)
  let signal = @cond_var.Cond()
  @async.with_timeout_opt(5000, () => {
    @async.with_task_group(g => {
      g.spawn_bg(() => {
        let _ = dispatch_http1(
          app(seen, signal),
          h1_req(version),
          Inbox::new(req_r),
          resp_w,
        )
        resp_w.close()
      })
      let buf = Buffer()
      while !bytes_has(buf.to_bytes(), b"\r\n\r\n") {
        guard resp_r.read_some() is Some(piece) else { break }
        buf.write_bytes(piece)
      }
      let head = buf.to_bytes()
      seen.val = true
      signal.broadcast()
      (head, drain_pipe(resp_r))
    })
  })
}

///|
/// An event stream sends its head and then waits for something to happen.
fn stream_app(seen : Ref[Bool], signal : @cond_var.Cond) -> @moonasgi.AsgiApp {
  (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/event-stream")],
        trailers=false,
      ),
    )
    while !seen.val {
      signal.wait()
    }
    send(
      @moonasgi.Event::HttpResponseBody(body=b"data: one\n\n", more_body=false),
    )
  }
}

///|
async test "http1: a head followed by a wait is written before the first event" {
  guard head_while_waiting("HTTP/1.1", stream_app) is Some((head, rest)) else {
    fail("the head never reached the client while the app waited")
  }
  assert_eq(bytes_has(head, b"HTTP/1.1 200 OK\r\n"), true)
  assert_eq(bytes_has(head, b"content-type: text/event-stream"), true)
  // Framed as a stream, since the length was not known when it went out.
  assert_eq(bytes_has(head, b"transfer-encoding: chunked"), true)
  assert_eq(bytes_has(head, b"data: one"), false)
  // The event follows as a chunk, and the stream ends with the zero chunk.
  assert_eq(rest, b"b\r\ndata: one\n\n\r\n0\r\n\r\n")
}

///|
async test "http1: on HTTP/1.0 a head followed by a wait is written close-delimited" {
  guard head_while_waiting("HTTP/1.0", stream_app) is Some((head, rest)) else {
    fail("the head never reached the client while the app waited")
  }
  assert_eq(bytes_has(head, b"HTTP/1.0 200 OK\r\n"), true)
  assert_eq(bytes_has(head, b"transfer-encoding"), false)
  assert_eq(bytes_has(head, b"content-length"), false)
  assert_eq(bytes_has(head, b"connection: close"), true)
  assert_eq(rest, b"data: one\n\n")
}

///|
async test "http1: a head and a body sent back to back keep content-length" {
  let resp = run_h1(h1_req("HTTP/1.1"))
  assert_eq(bytes_has(resp, b"content-length: 2"), true)
  assert_eq(bytes_has(resp, b"transfer-encoding"), false)
}

///|
/// An app that sends only its head and returns gets the empty answer it always did.
async test "http1: a head with no body is still answered with content-length 0" {
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (resp_r, resp_w) = @pipe.pipe()
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
  }
  let _ = dispatch_http1(app, h1_req("HTTP/1.1"), Inbox::new(req_r), resp_w)
  resp_w.close()
  let resp = drain_pipe(resp_r)
  assert_eq(bytes_has(resp, b"content-length: 0"), true)
  assert_eq(bytes_has(resp, b"transfer-encoding"), false)
}
