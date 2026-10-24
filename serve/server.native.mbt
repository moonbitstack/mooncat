///|
/// Percent-decode a request target's path into the characters ASGI's `path` carries,
/// leaving the bytes as they arrived for `raw_path`. A stray `%` or a truncated
/// escape passes through as written: the target is attacker-controlled, and refusing
/// to build a scope would leave the server unable to answer at all.
fn percent_decode(target : String) -> Bytes {
  @moonurl.unescape(@utf8.encode(target)[:])
}

///|
/// An address as the `(host, port)` pair ASGI's `client` and `server` carry. The
/// host is rendered from the address rather than looked up: a scope is built per
/// request, and a reverse DNS lookup there would be a network round trip.
fn addr_pair(addr : @socket.Addr) -> (String, Int32) {
  let text = addr.to_string()
  // `Show` renders `host:port`; the scope wants them apart.
  for i = text.length() - 1; i >= 0; i = i - 1 {
    if text[i] == ':' {
      return (text[0:i].to_owned(), addr.port())
    }
  }
  (text, addr.port())
}

///|
/// The listening address as ASGI's `server`, whose port is optional because a unix
/// socket has none. Unknown is `None`, which ASGI allows.
fn server_pair(addr : @socket.Addr?) -> (String, Int32?)? {
  match addr {
    Some(a) => {
      let (host, port) = addr_pair(a)
      Some((host, Some(port)))
    }
    None => None
  }
}

///|
/// Split a raw request target into (path, query_string) at the first '?'.
fn split_query(raw : String) -> (String, String) {
  let n = raw.length()
  for i = 0; i < n; i = i + 1 {
    if raw[i] == '?' {
      return (raw[0:i].to_owned(), raw[i + 1:n].to_owned())
    }
  }
  (raw, "")
}

///|
/// Whether the served-request count has reached the configured ceiling (← uvicorn's
/// `--limit-max-requests`). `None` never trips, which is uvicorn's default: serve until stopped.
fn over_request_limit(served : Int32, limit : Int32?) -> Bool {
  match limit {
    Some(n) => served >= n
    None => false
  }
}

///|
/// Serve a moonasgi ASGI application over native HTTP/1.1 + WebSocket
/// (← uvicorn). Convenience wrapper over `serve_config` that builds a `Config`
/// from `host` / `port` / `backlog`. Blocks in a keep-alive accept loop until
/// the running task is cancelled.
pub async fn serve(
  app : @moonasgi.AsgiApp,
  host~ : String = "127.0.0.1",
  port~ : Int32 = @config.port,
  backlog~ : Int32 = 2048,
) -> Unit {
  serve_config(app, @config.Config::new(host~, port~, backlog~))
}

///|
/// Serve a moonasgi ASGI application under an explicit `Config`.
///
/// Runs the full lifespan protocol around the accept loop: the app is invoked
/// once under a `Lifespan` scope and `startup()` is driven **before** the
/// listener is bound, and `shutdown()` is driven on the way out — even when the
/// serving task is cancelled, via `protect_from_cancel`. Each accepted request
/// is bridged by `dispatch`, which diverts WebSocket upgrades to the echo path.
pub async fn serve_config(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
) -> Unit {
  run(app, config, ShutdownHandle::new(), None, Both)
}

///|
/// `--limit-max-requests` has to hold on the acceptor most servers actually run, not only on the
/// graceful one: `serve` / `serve_config` is the plain entry point, and a limit honoured on the
/// other path only is a limit nobody gets.
async test "serve_config stops itself after limit_max_requests" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let srv = g.spawn(() => {
      serve_config(
        app,
        @config.Config::new(
          port=18112,
          limit_max_requests=2,
          logger=@config.Logger::silent(),
        ),
      )
    })
    @async.sleep(300)
    let (first, _b1) = @http.get("http://127.0.0.1:18112/one")
    assert_eq(first.code, 200)
    let (second, _b2) = @http.get("http://127.0.0.1:18112/two")
    assert_eq(second.code, 200)
    // Bounded, so a limit that never trips fails this test rather than parking it forever.
    let stopped = @async.with_timeout_opt(5000, () => srv.wait())
    if stopped is None {
      srv.cancel()
    }
    assert_eq(stopped is Some(_), true)
  })
}

///|
test "helpers: query split, reason" {
  let (p, q) = split_query("/x/y?a=1&b=2")
  assert_eq(p, "/x/y")
  assert_eq(q, "a=1&b=2")
  let (p2, q2) = split_query("/noquery")
  assert_eq(p2, "/noquery")
  assert_eq(q2, "")
  assert_eq(@config.reason(404), "Not Found")
  assert_eq(@config.reason(200), "OK")
}

///|
async test "serve responds 200 with body over a real socket" {
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
          body=b"hi from mooncat",
          more_body=false,
        ),
      )
    }
    let task = g.spawn(() => serve(app, port=18080))
    @async.sleep(200)
    let (resp, _body) = @http.get("http://127.0.0.1:18080/")
    assert_eq(resp.code, 200)
    task.cancel()
  })
}

///|
async test "lifespan drives startup then shutdown in order" {
  @async.with_task_group(g => {
    let log : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Lifespan(_) else { return }
      for ;; {
        match receive() {
          LifespanStartup => {
            log.push("startup")
            send(@moonasgi.Event::LifespanStartupComplete)
          }
          LifespanShutdown => {
            log.push("shutdown")
            send(@moonasgi.Event::LifespanShutdownComplete)
            break
          }
          _ => ()
        }
      }
    }
    let lifespan = @lifespan.Lifespan::new(app)
    let task = lifespan.spawn(g)
    lifespan.startup(task)
    lifespan.shutdown(task)
    assert_eq(log, ["startup", "shutdown"])
  })
}

///|
/// A minimal ASGI WebSocket echo app driven entirely through the moonasgi SEAM:
/// accept the connection, then reflect every text/binary message back and stop
/// on disconnect. Used by the round-trip integration test below.
async fn ws_echo_app(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is WebSocket(_) else { return }
  guard receive() is WebSocketConnect else { return }
  send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
  for ;; {
    match receive() {
      WebSocketReceive(text~, bytes~) =>
        match (text, bytes) {
          (Some(t), _) => send(@moonasgi.Event::WebSocketSendText(t))
          (_, Some(b)) => send(@moonasgi.Event::WebSocketSendBytes(b))
          _ => ()
        }
      WebSocketDisconnect(..) => break
      _ => break
    }
  }
}

///|
async test "websocket bridge: full text + binary round-trip through the SEAM" {
  @async.with_task_group(g => {
    let task = g.spawn(() => serve(ws_echo_app, port=18081))
    @async.sleep(200)
    let ws = @websocket.connect("ws://127.0.0.1:18081/chat")
    // text round-trip
    ws.send_text("hello mooncat")
    assert_eq(ws.recv().read_all().text(), "hello mooncat")
    // a second text message: proves the bridge loops, not a one-shot echo
    ws.send_text("second")
    assert_eq(ws.recv().read_all().text(), "second")
    // binary round-trip
    ws.send_binary(b"\x00\x01\x02\xfe\xff"[:])
    assert_eq(ws.recv().read_all().binary(), b"\x00\x01\x02\xfe\xff")
    // clean close from the client; the server observes it as a disconnect
    ws.send_close(code=Normal)
    ws.close()
    task.cancel()
  })
}

///|
/// A subprotocol offer on the handshake surfaces in the `WebSocketScope`.
async test "websocket bridge: offered subprotocols reach the scope" {
  @async.with_task_group(g => {
    let seen : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is WebSocket(ws_scope) else { return }
      for sp in ws_scope.subprotocols {
        seen.push(sp)
      }
      guard receive() is WebSocketConnect else { return }
      send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
      match receive() {
        WebSocketReceive(text~, bytes=_) =>
          match text {
            Some(t) => send(@moonasgi.Event::WebSocketSendText(t))
            None => ()
          }
        _ => ()
      }
    }
    let task = g.spawn(() => serve(app, port=18082))
    @async.sleep(200)
    let ws = @websocket.connect("ws://127.0.0.1:18082/chat", headers={
      "sec-websocket-protocol": "chat, superchat",
    })
    ws.send_text("go")
    assert_eq(ws.recv().read_all().text(), "go")
    assert_eq(seen, ["chat", "superchat"])
    ws.close()
    task.cancel()
  })
}

///|
/// uvicorn fills `client`, `server` and `root_path` on every request scope and
/// percent-decodes `path` while leaving `raw_path` as it arrived. Leaving those
/// empty means an app cannot log who called, build an absolute URL for itself, or
/// tell an escaped slash from a real one.
async test "the request scope carries the peer, the bind address, and a decoded path" {
  @async.with_task_group(g => {
    let seen : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      match scope {
        Http(hs) => {
          seen.push(hs.path)
          seen.push(@utf8.decode_lossy(hs.raw_path))
          seen.push(hs.root_path)
          seen.push(
            match hs.client {
              Some((host, _port)) => host
              None => "no-client"
            },
          )
          seen.push(
            match hs.server {
              Some((host, Some(port))) => host + ":" + port.to_string()
              Some((host, None)) => host
              None => "no-server"
            },
          )
          send(
            @moonasgi.Event::HttpResponseStart(
              status=200,
              headers=[],
              trailers=false,
            ),
          )
          send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
        }
        _ => ()
      }
    }
    let task = g.spawn(() => {
      serve_config(app, @config.Config::new(port=18099, root_path="/api"))
    })
    @async.sleep(300)
    let (resp, _b) = @http.get("http://127.0.0.1:18099/files/a%2Fb/caf%C3%A9")
    assert_eq(resp.code, 200)
    // `path` is decoded; `raw_path` is not.
    assert_eq(seen[0], "/files/a/b/café")
    assert_eq(seen[1], "/files/a%2Fb/caf%C3%A9")
    assert_eq(seen[2], "/api")
    assert_eq(seen[3], "127.0.0.1")
    assert_eq(seen[4], "127.0.0.1:18099")
    task.cancel()
  })
}

///|
/// uvicorn logs one line per request and answers 500 when an app raises. Without
/// either, a failing endpoint and a working one look the same from outside.
async test "the server logs each request and turns an app failure into a 500" {
  @async.with_task_group(g => {
    let lines : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      match scope {
        Http(hs) => {
          if hs.path == "/boom" {
            fail("handler blew up")
          }
          send(
            @moonasgi.Event::HttpResponseStart(
              status=201,
              headers=[],
              trailers=false,
            ),
          )
          send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
        }
        _ => ()
      }
    }
    let task = g.spawn(() => {
      serve_config(
        app,
        @config.Config::new(
          port=18113,
          logger=@config.Logger::new(write=line => lines.push(line)),
        ),
      )
    })
    @async.sleep(300)
    let (ok, _b) = @http.get("http://127.0.0.1:18113/hello")
    assert_eq(ok.code, 201)
    let (boom, _b2) = @http.get("http://127.0.0.1:18113/boom")
    assert_eq(boom.code, 500)
    @async.sleep(100)
    let joined = lines.join(" | ")
    assert_eq(joined.contains("Started server process"), true)
    assert_eq(joined.contains("\"GET /hello HTTP/1.1\" 201"), true)
    assert_eq(joined.contains("exception in ASGI application"), true)
    assert_eq(joined.contains("\"GET /boom HTTP/1.1\" 500"), true)
    task.cancel()
  })
}
