///|
/// An HTTP/2 client on moonhttp's state machine that keeps any number of streams open, which is
/// what it takes to see one stream overtake another or a reset reach the application.
priv struct Peer {
  sock : @socket.Tcp
  wire : @http2.Conn
  replies : Map[Int32, Reply]
  finished : Array[Int32]
  mut goaway : Bool
  mut closed : Bool
}

///|
priv struct Reply {
  mut status : String
  headers : Array[(String, String)]
  body : @buffer.Buffer
  trailers : Array[(String, String)]
  hints : Array[(String, String)]
  mut reset : Int32?
  mut done : Bool
}

///|
async fn Peer::connect(port : Int32, settings? : @http2.Settings) -> Peer {
  let sock = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
  let wire = @http2.Conn::new(
    Client,
    settings=settings.unwrap_or(@http2.settings),
  )
  let peer = {
    sock,
    wire,
    replies: Map([]),
    finished: [],
    goaway: false,
    closed: false,
  }
  peer.flush()
  peer
}

///|
async fn Peer::flush(self : Peer) -> Unit {
  let out = self.wire.take()
  if out.length() > 0 {
    self.sock.write(out)
  }
}

///|
/// Open a stream with a request head.
async fn Peer::request(
  self : Peer,
  verb : String,
  path : String,
  end~ : Bool = true,
) -> Int32 {
  let id = self.wire.next_stream()
  self.wire.headers(
    id,
    [
      @header.Header::of(":method", verb),
      @header.Header::of(":scheme", "http"),
      @header.Header::of(":path", path),
      @header.Header::of(":authority", "127.0.0.1"),
    ],
    end~,
  )
  self.replies[id] = {
    status: "",
    headers: [],
    body: @buffer.Buffer(),
    trailers: [],
    hints: [],
    reset: None,
    done: false,
  }
  self.flush()
  id
}

///|
async fn Peer::data(self : Peer, id : Int32, data : Bytes, end~ : Bool) -> Unit {
  self.wire.data(id, data[:], end~)
  self.flush()
}

///|
/// Read until one event has been applied to the replies.
async fn Peer::step(self : Peer) -> Unit {
  let event = self.wire.next()
  match event {
    NeedData => {
      self.flush()
      self.wire.receive(self.sock.read_some().unwrap_or(b"")[:])
    }
    Informational(stream~, fields~) =>
      for f in fields {
        self.replies[stream].hints.push(f.ascii())
      }
    Response(stream~, fields~) =>
      for f in fields {
        let (name, value) = f.ascii()
        if name == ":status" {
          self.replies[stream].status = value
        } else {
          self.replies[stream].headers.push((name, value))
        }
      }
    Trailers(stream~, fields~) =>
      for f in fields {
        self.replies[stream].trailers.push(f.ascii())
      }
    Data(stream~, data~) => {
      self.replies[stream].body.write_bytes(data)
      self.wire.acknowledge(stream, data.length())
    }
    End(stream~) => {
      self.replies[stream].done = true
      self.finished.push(stream)
    }
    Reset(stream~, code~, ..) => {
      self.replies[stream].reset = Some(code)
      self.replies[stream].done = true
      self.finished.push(stream)
    }
    GoAway(..) => self.goaway = true
    Closed => self.closed = true
    _ => ()
  }
}

///|
/// Read until every stream in `ids` has ended or been reset, failing past two seconds rather than
/// hanging the suite.
async fn Peer::wait(self : Peer, ids : Array[Int32]) -> Unit {
  let ok = @async.with_timeout_opt(2000, () => {
    while ids.iter().any(id => !self.replies[id].done) && !self.closed {
      self.step()
    }
  })
  guard ok is Some(_) else { fail("streams did not finish") }
}

///|
fn Reply::header(self : Reply, name : String) -> String? {
  self.headers.iter().find_first(h => h.0 == name).map(h => h.1)
}

///|
fn Reply::text(self : Reply) -> String {
  @utf8.decode_lossy(self.body.to_bytes())
}

///|
fn answer(text : String) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    guard scope is Http(_) else { return }
    ignore(receive())
    send(
      HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(HttpResponseBody(body=@utf8.encode(text), more_body=false))
  }
}

///|
fn quiet(port : Int32) -> @config.Config {
  @config.Config::new(port~, logger=@config.Logger::silent())
}

///|
async test "h2c: a GET is answered with status, body, and the server's own headers" {
  @async.with_task_group(g => {
    let task = g.spawn(() => serve_h2c(answer("hello over h2c"), port=18300))
    @async.sleep(250)
    let peer = Peer::connect(18300)
    let id = peer.request("GET", "/")
    peer.wait([id])
    let r = peer.replies[id]
    assert_eq(r.status, "200")
    assert_eq(r.text(), "hello over h2c")
    assert_eq(r.header("content-type"), Some("text/plain"))
    assert_eq(r.header("server"), Some("mooncat"))
    assert_true(
      r.header("date").map(d => d.has_suffix(" GMT")).unwrap_or(false),
    )
    task.cancel()
  })
}

///|
async test "h2c: a request body reaches the application piece by piece as it arrives" {
  @async.with_task_group(g => {
    let seen : Array[(String, Bool)] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      for ;; {
        guard receive() is HttpRequest(body~, more_body~) else { break }
        seen.push((@utf8.decode_lossy(body), more_body))
        if !more_body {
          break
        }
      }
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=b"ok", more_body=false))
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18301)))
    @async.sleep(250)
    let peer = Peer::connect(18301)
    let id = peer.request("POST", "/up", end=false)
    peer.data(id, b"ab", end=false)
    @async.sleep(150)
    peer.data(id, b"cd", end=true)
    peer.wait([id])
    assert_eq(peer.replies[id].text(), "ok")
    assert_eq(seen, [("ab", true), ("cd", false)])
    task.cancel()
  })
}

///|
/// RFC 9113 §6.9: a client that grants 100 octets gets the response 100 octets at a time.
async test "h2c: a large response keeps to the peer's stream window" {
  @async.with_task_group(g => {
    let payload = Bytes::make(1000, b'z')
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      ignore(receive())
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=payload, more_body=false))
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18302)))
    @async.sleep(250)
    let peer = Peer::connect(
      18302,
      settings=@http2.Settings::new(initial_window_size=100),
    )
    let id = peer.request("GET", "/big")
    let sizes = []
    let ok = @async.with_timeout_opt(2000, () => {
      while !peer.replies[id].done {
        let before = peer.replies[id].body.length()
        peer.step()
        let after = peer.replies[id].body.length()
        if after > before {
          sizes.push(after - before)
        }
      }
    })
    assert_true(ok is Some(_))
    assert_eq(sizes[0], 100)
    assert_true(sizes.iter().all(n => n <= 100))
    assert_eq(peer.replies[id].body.length(), 1000)
    task.cancel()
  })
}

///|
async test "h2c: streams on one connection run at once, so a slow one is overtaken" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(h) else { return }
      ignore(receive())
      if h.path == "/slow" {
        @async.sleep(400)
      }
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=@utf8.encode(h.path), more_body=false))
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18303)))
    @async.sleep(250)
    let peer = Peer::connect(18303)
    let slow = peer.request("GET", "/slow")
    let fast = peer.request("GET", "/fast")
    peer.wait([slow, fast])
    assert_eq(peer.finished, [fast, slow])
    assert_eq(peer.replies[slow].text(), "/slow")
    assert_eq(peer.replies[fast].text(), "/fast")
    task.cancel()
  })
}

///|
/// uvicorn's rule: once the body is delivered, `receive` waits for the response to finish or the
/// client to leave. An application listening for the disconnect while it streams must not hear
/// one before its last chunk.
async test "h2c: http.disconnect comes after the response, not straight after the body" {
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
        @async.sleep(200)
        send(HttpResponseBody(body=b"tick", more_body=true))
        order.push("last chunk")
        send(HttpResponseBody(body=b"", more_body=false))
      })
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18304)))
    @async.sleep(250)
    let peer = Peer::connect(18304)
    let id = peer.request("GET", "/stream")
    peer.wait([id])
    @async.sleep(50)
    assert_eq(peer.replies[id].text(), "tick")
    assert_eq(order, ["last chunk", "disconnect"])
    task.cancel()
  })
}

///|
async test "h2c: a client reset reaches the application as http.disconnect" {
  @async.with_task_group(g => {
    let heard = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      ignore(receive())
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=b"first", more_body=true))
      heard.push(receive())
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18305)))
    @async.sleep(250)
    let peer = Peer::connect(18305)
    let id = peer.request("GET", "/")
    let ok = @async.with_timeout_opt(2000, () => {
      while peer.replies[id].body.length() == 0 {
        peer.step()
      }
    })
    assert_true(ok is Some(_))
    peer.wire.reset(id, code=@http2.error_cancel)
    peer.flush()
    let reached = @async.with_timeout_opt(2000, () => {
      while heard.is_empty() {
        @async.sleep(10)
      }
    })
    assert_true(reached is Some(_))
    assert_true(heard is [HttpDisconnect])
    task.cancel()
  })
}

///|
async test "h2c: a HEAD answer carries the head and no body" {
  @async.with_task_group(g => {
    let task = g.spawn(() => serve_h2c_config(answer("body"), quiet(18306)))
    @async.sleep(250)
    let peer = Peer::connect(18306)
    let id = peer.request("HEAD", "/")
    peer.wait([id])
    assert_eq(peer.replies[id].status, "200")
    assert_eq(peer.replies[id].body.length(), 0)
    task.cancel()
  })
}

///|
async test "h2c: early hints and trailers go out as heads of their own" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      ignore(receive())
      send(HttpResponseEarlyHint(links=["</app.css>; rel=preload"]))
      send(HttpResponseStart(status=200, headers=[], trailers=true))
      send(HttpResponseBody(body=b"data", more_body=false))
      send(HttpResponseTrailers(headers=[("x-sum", "42")], more_trailers=false))
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18307)))
    @async.sleep(250)
    let peer = Peer::connect(18307)
    let id = peer.request("GET", "/")
    peer.wait([id])
    let r = peer.replies[id]
    assert_eq(r.hints, [(":status", "103"), ("link", "</app.css>; rel=preload")])
    assert_eq(r.text(), "data")
    assert_eq(r.trailers, [("x-sum", "42")])
    task.cancel()
  })
}

///|
async test "h2c: a failure before the answer is a 500, after it a reset" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(h) else { return }
      ignore(receive())
      if h.path == "/late" {
        send(HttpResponseStart(status=200, headers=[], trailers=false))
        send(HttpResponseBody(body=b"half", more_body=true))
      }
      fail("handler blew up")
    }
    let task = g.spawn(() => serve_h2c_config(app, quiet(18308)))
    @async.sleep(250)
    let peer = Peer::connect(18308)
    let early = peer.request("GET", "/early")
    let late = peer.request("GET", "/late")
    peer.wait([early, late])
    assert_eq(peer.replies[early].status, "500")
    assert_eq(peer.replies[late].reset, Some(@http2.error_internal_error))
    task.cancel()
  })
}

///|
async test "h2c: past limit_concurrency a stream is answered 503" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(h) else { return }
      ignore(receive())
      if h.path == "/slow" {
        @async.sleep(400)
      }
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=b"ok", more_body=false))
    }
    let task = g.spawn(() => {
      serve_h2c_config(
        app,
        @config.Config::new(
          port=18309,
          limit_concurrency=1,
          logger=@config.Logger::silent(),
        ),
      )
    })
    @async.sleep(250)
    let peer = Peer::connect(18309)
    let slow = peer.request("GET", "/slow")
    @async.sleep(100)
    let extra = peer.request("GET", "/extra")
    peer.wait([slow, extra])
    assert_eq(peer.replies[slow].status, "200")
    assert_eq(peer.replies[extra].status, "503")
    task.cancel()
  })
}

///|
async test "h2c: limit_max_requests counts streams and stops the server with a GOAWAY" {
  @async.with_task_group(g => {
    let srv = g.spawn(() => {
      serve_h2c_config(
        answer("ok"),
        @config.Config::new(
          port=18310,
          limit_max_requests=2,
          logger=@config.Logger::silent(),
        ),
      )
    })
    @async.sleep(250)
    let peer = Peer::connect(18310)
    let a = peer.request("GET", "/a")
    let b = peer.request("GET", "/b")
    peer.wait([a, b])
    let saw = @async.with_timeout_opt(2000, () => {
      while !peer.goaway && !peer.closed {
        peer.step()
      }
    })
    assert_true(saw is Some(_))
    assert_true(peer.goaway)
    peer.sock.close()
    let stopped = @async.with_timeout_opt(5000, () => srv.wait())
    if stopped is None {
      srv.cancel()
    }
    assert_true(stopped is Some(_))
  })
}

///|
async test "h2c: a connection idle past timeout_keep_alive is sent a GOAWAY and closed" {
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_h2c_config(
        answer("ok"),
        @config.Config::new(
          port=18311,
          timeout_keep_alive=200,
          logger=@config.Logger::silent(),
        ),
      )
    })
    @async.sleep(250)
    let peer = Peer::connect(18311)
    let id = peer.request("GET", "/")
    peer.wait([id])
    let ended = @async.with_timeout_opt(3000, () => {
      while !peer.closed {
        peer.step()
      }
    })
    assert_true(ended is Some(_))
    assert_true(peer.goaway)
    task.cancel()
  })
}

///|
async test "h2c: streams past Config.h2.max_streams are refused" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      ignore(receive())
      @async.sleep(300)
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(HttpResponseBody(body=b"ok", more_body=false))
    }
    let task = g.spawn(() => {
      serve_h2c_config(
        app,
        @config.Config::new(
          port=18312,
          h2=@config.H2Config::new(max_streams=1),
          logger=@config.Logger::silent(),
        ),
      )
    })
    @async.sleep(250)
    let peer = Peer::connect(18312)
    // The server's SETTINGS arrive before the limit is known on this side.
    let first = peer.request("GET", "/one")
    let ok = @async.with_timeout_opt(1000, () => {
      while peer.wire.peer_settings().max_concurrent_streams is None {
        peer.step()
      }
    })
    assert_true(ok is Some(_))
    let second = peer.request("GET", "/two") catch { _ => -1 }
    peer.wait([first])
    assert_eq(peer.replies[first].status, "200")
    if second > 0 {
      peer.wait([second])
      assert_eq(peer.replies[second].reset, Some(@http2.error_refused_stream))
    }
    task.cancel()
  })
}

///|
async test "h2c: the access log has one line per stream" {
  @async.with_task_group(g => {
    let lines : Array[String] = []
    let task = g.spawn(() => {
      serve_h2c_config(
        answer("ok"),
        @config.Config::new(
          port=18313,
          logger=@config.Logger::new(write=line => lines.push(line)),
        ),
      )
    })
    @async.sleep(250)
    let peer = Peer::connect(18313)
    let id = peer.request("GET", "/logged")
    peer.wait([id])
    @async.sleep(50)
    assert_true(lines.iter().any(l => l.contains("\"GET /logged HTTP/2\" 200")))
    task.cancel()
  })
}

///|
/// One request on a moonnet connection, in the clear or under TLS, by moonhttp's state machine:
/// `(:status, every field of every head, body)`. The heads include a 103's and the trailers, so a
/// test can look for any of them in one list.
async fn h2_request(
  conn : @tcp.Conn,
  scheme : String,
  host : String,
  verb : String,
  path : String,
  body~ : Bytes = b"",
) -> (String, Array[(String, String)], Bytes) {
  let wire = @http2.Conn::new(Client)
  let flush = async fn() {
    let out = wire.take()
    if out.length() > 0 {
      conn.write(out)
    }
  }
  let id = wire.next_stream()
  wire.headers(
    id,
    [
      @header.Header::of(":method", verb),
      @header.Header::of(":scheme", scheme),
      @header.Header::of(":path", path),
      @header.Header::of(":authority", host),
    ],
    end=body.length() == 0,
  )
  if body.length() > 0 {
    wire.data(id, body[:], end=true)
  }
  let mut status = ""
  let fields : Array[(String, String)] = []
  let acc = @buffer.Buffer()
  let mut done = false
  while !done {
    match wire.next() {
      NeedData => {
        flush()
        wire.receive(conn.read_some().unwrap_or(b"")[:])
      }
      Informational(fields=f, ..)
      | Response(fields=f, ..)
      | Trailers(fields=f, ..) =>
        for h in f {
          let (name, value) = h.ascii()
          if name == ":status" {
            if value != "103" {
              status = value
            }
          } else {
            fields.push((name, value))
          }
        }
      Data(stream~, data~) => {
        acc.write_bytes(data)
        wire.acknowledge(stream, data.length())
      }
      End(..) | Reset(..) | Closed => done = true
      _ => ()
    }
  }
  conn.close()
  (status, fields, acc.to_bytes())
}

///|
fn has_header(
  headers : Array[(String, String)],
  name : String,
  value : String,
) -> Bool {
  headers.iter().any(h => h.0 == name && h.1 == value)
}

///|
/// `h2_request` in the clear, by prior knowledge.
async fn h2c_request(
  host : String,
  port : Int32,
  verb : String,
  path : String,
  body~ : Bytes = b"",
) -> (String, Array[(String, String)], Bytes) {
  let sock = @socket.Tcp::connect(@socket.Addr::parse("\{host}:\{port}"))
  h2_request(@tcp.Conn::plain(sock), "http", host, verb, path, body~)
}

///|
/// The window comes back as the application takes the body, so an upload far larger than the
/// window still flows, and stalls if the application stops reading.
async test "h2c: an upload larger than the receive window flows as the application reads it" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      let mut total = 0
      for ;; {
        guard receive() is HttpRequest(body~, more_body~) else { break }
        total += body.length()
        if !more_body {
          break
        }
      }
      send(HttpResponseStart(status=200, headers=[], trailers=false))
      send(
        HttpResponseBody(body=@utf8.encode(total.to_string()), more_body=false),
      )
    }
    let task = g.spawn(() => {
      serve_h2c_config(
        app,
        @config.Config::new(
          port=18314,
          h2=@config.H2Config::new(window=16384, connection_window=65535),
          logger=@config.Logger::silent(),
        ),
      )
    })
    @async.sleep(250)
    let peer = Peer::connect(18314)
    let id = peer.request("POST", "/upload", end=false)
    let chunk = Bytes::make(4096, b'u')
    let total = 200 * 1024
    let mut sent = 0
    let ok = @async.with_timeout_opt(5000, () => {
      while sent < total {
        let room = peer.wire.window(id)
        if room <= 0 {
          peer.step()
          continue
        }
        let n = @cmp.minimum(@cmp.minimum(room, chunk.length()), total - sent)
        peer.data(id, chunk[:n].to_owned(), end=sent + n == total)
        sent += n
      }
    })
    assert_true(ok is Some(_))
    peer.wait([id])
    assert_eq(peer.replies[id].text(), total.to_string())
    task.cancel()
  })
}
