///|
/// Map async's request-method enum to the ASGI method string.
fn method_str(m : @http.RequestMethod) -> String {
  match m {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

///|
/// Percent-decode a request target's path into the characters ASGI's `path` carries,
/// leaving the bytes as they arrived for `raw_path`. A stray `%` or a truncated
/// escape passes through as written: the target is attacker-controlled, and refusing
/// to build a scope would leave the server unable to answer at all.
fn percent_decode(target : String) -> Bytes {
  @mime.percent_decode(@utf8.encode(target)[:])
}

///|
/// An address as the `(host, port)` pair ASGI's `client` and `server` carry. The
/// host is rendered from the address rather than looked up: a scope is built per
/// request, and a reverse DNS lookup there would be a network round trip.
fn addr_pair(addr : @socket.Addr) -> (String, Int) {
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
fn headers_to_pairs(h : Map[String, String]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for k, v in h {
    out.push((k, v))
  }
  out
}

///|
/// Drop the framing headers the async layer manages itself — it forbids setting
/// Content-Length / Transfer-Encoding by hand.
fn response_headers(pairs : Array[(String, String)]) -> Map[String, String] {
  let m : Map[String, String] = Map([])
  for pair in pairs {
    let k = pair.0
    if k != "content-length" && k != "transfer-encoding" {
      m[k] = pair.1
    }
  }
  m
}

///|
/// Whether the app already supplied `name`, compared case-insensitively: ASGI header names are
/// conventionally lowercase but nothing enforces it, and a second `Date` is worse than none.
fn has_field(pairs : Array[(String, String)], name : String) -> Bool {
  for pair in pairs {
    if pair.0.to_lower() == name {
      return true
    }
  }
  false
}

///|
/// Whether the served-request count has reached the configured ceiling (← uvicorn's
/// `--limit-max-requests`). `None` never trips, which is uvicorn's default: serve until stopped.
fn over_request_limit(served : Int, limit : Int?) -> Bool {
  match limit {
    Some(n) => served >= n
    None => false
  }
}

///|
/// Bridge one HTTP connection to a moonasgi application: build the `Scope`, a
/// `Receive` that streams the request body, and a `Send` that writes the
/// response, then drive the app. A WebSocket upgrade request is diverted to
/// `handle_websocket` (the full frame↔`Event` bridge) before any HTTP scope is
/// built.
async fn dispatch(
  app : @moonasgi.AsgiApp,
  request : @http.Request,
  body_reader : &@io.Reader,
  conn : @http.ServerConnection,
  config~ : Config,
  server_addr? : @socket.Addr,
  client_addr? : @socket.Addr,
) -> Unit {
  let logger = config.logger
  if is_websocket_upgrade(request.headers) {
    handle_websocket(app, request, conn, config~, client_addr?)
    return
  }
  let (raw_path, query) = split_query(request.path)
  // ASGI's `path` is percent-decoded and `raw_path` is not; a server that hands
  // over the encoded form for both leaves a router unable to tell `%2F` from `/`.
  let path = @utf8.decode_lossy(percent_decode(raw_path))
  // Only when the peer address is genuinely known. `@http.ServerConnection`'s
  // `client_addr` reports the *listening* address for an accepted connection —
  // the async layer copies the listener's address onto the accepted socket — so
  // filling the scope from it would tell the app the server called itself. ASGI
  // says a server that cannot supply this sends null, and that is the truth here.
  let peer = match client_addr {
    Some(a) => Some(addr_pair(a))
    None => None
  }
  let (client, scheme) = if config.proxy_headers {
    proxy_rewrite(
      request.headers,
      peer,
      "http",
      trusted=config.forwarded_allow_ips,
    )
  } else {
    (peer, "http")
  }
  let scope = @moonasgi.Scope::Http({
    http_version: "1.1",
    http_method: method_str(request.meth),
    scheme,
    path,
    raw_path: @utf8.encode(raw_path),
    query_string: @utf8.encode(query),
    root_path: config.root_path,
    headers: headers_to_pairs(request.headers),
    client,
    // ASGI lets `server` carry no port (a unix socket has none), so the pair's
    // second half is optional there while `client`'s is not.
    server: match server_addr {
      Some(a) => {
        let (host, port) = addr_pair(a)
        Some((host, Some(port)))
      }
      None => None
    },
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
  let body_done = Ref(false)
  let receive : @moonasgi.Receive = () => {
    if body_done.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      match body_reader.read_some() {
        Some(chunk) => @moonasgi.Event::HttpRequest(body=chunk, more_body=true)
        None => {
          body_done.val = true
          @moonasgi.Event::HttpRequest(body=b"", more_body=false)
        }
      }
    }
  }
  let started = Ref(false)
  let ended = Ref(false)
  let sent_status = Ref(0)
  let send : @moonasgi.Send = event => {
    match event {
      HttpResponseStart(status~, headers~, ..) => {
        started.val = true
        sent_status.val = status
        let extra = response_headers(headers)
        if config.date_header && !has_field(headers, "date") {
          extra["date"] = http_date_now()
        }
        conn.send_response(status, reason(status), extra_headers=extra)
      }
      HttpResponseBody(body~, more_body~) => {
        conn.write(body)
        if !more_body {
          conn.end_response()
          ended.val = true
        }
      }
      _ => ()
    }
  }
  // An app that raises leaves the client with nothing, so say so and answer 500
  // rather than dropping the connection silently.
  app(scope, receive, send) catch {
    err => {
      logger.log(Error, "exception in ASGI application: " + err.to_string())
      if !started.val {
        let extra : Map[String, String] = Map([])
        if config.date_header {
          extra["date"] = http_date_now()
        }
        conn.send_response(500, reason(500), extra_headers=extra)
        sent_status.val = 500
      }
    }
  }
  // Finalise the response here rather than leaning on the transport's own accept
  // loop: `serve_graceful` drives its own accept loop over a raw ServerConnection
  // and has no equivalent hook, so a response that never sent an explicit final
  // body event still gets terminated the same way on both serve paths.
  if started.val && !ended.val {
    conn.end_response()
  }
  logger.access_line(
    match client_addr {
      Some(a) => a.to_string()
      None => "-"
    },
    method_str(request.meth),
    request.path,
    "1.1",
    sent_status.val,
  )
}

///|
/// Serve a moonasgi ASGI application over native HTTP/1.1 + WebSocket
/// (← uvicorn). Convenience wrapper over `serve_config` that builds a `Config`
/// from `host` / `port` / `backlog`. Blocks in a keep-alive accept loop until
/// the running task is cancelled.
pub async fn serve(
  app : @moonasgi.AsgiApp,
  host? : String = "127.0.0.1",
  port? : Int = port,
  backlog? : Int = 2048,
) -> Unit {
  serve_config(app, Config::new(host~, port~, backlog~))
}

///|
/// Serve a moonasgi ASGI application under an explicit `Config`.
///
/// Runs the full lifespan protocol around the accept loop: the app is invoked
/// once under a `Lifespan` scope and `startup()` is driven **before** the
/// listener is bound, and `shutdown()` is driven on the way out — even when the
/// serving task is cancelled, via `protect_from_cancel`. Each accepted request
/// is bridged by `dispatch`, which diverts WebSocket upgrades to the echo path.
pub async fn serve_config(app : @moonasgi.AsgiApp, config : Config) -> Unit {
  @async.with_task_group(g => {
    let lifespan = Lifespan::new(app)
    let task = lifespan.spawn(g)
    lifespan.startup(task)
    let bound = @socket.Addr::parse(config.bind())
    config.logger.log(Info, "Started server process on http://" + config.bind())
    let server = @http.Server(
      bound,
      dual_stack=config.dual_stack,
      reuse_addr=config.reuse_addr,
      headers=config.server_headers,
    )
    defer {
      @async.protect_from_cancel(() => lifespan.shutdown(task) catch { _ => () })
      server.close()
    }
    // uvicorn's `--limit-max-requests` recycles the worker once it has served that many; the count
    // is shared across every connection this acceptor is running. The acceptor has to be a task of
    // its own so the limit can stop it — a handler that merely raised would be swallowed by
    // `allow_failure` and the server would keep serving.
    let served = Ref(0)
    let inflight = Ref(0)
    let stop : @aqueue.Queue[Unit] = @aqueue.Queue::Queue(kind=Unbounded)
    let acceptor = g.spawn(() => {
      server.run_forever(
        (request, body_reader, conn) => {
          inflight.val = inflight.val + 1
          defer {
            inflight.val = inflight.val - 1
          }
          dispatch(app, request, body_reader, conn, config~, server_addr=bound)
          served.val = served.val + 1
          if over_request_limit(served.val, config.limit_max_requests) {
            config.logger.log(
              Info,
              "Maximum request limit reached, stopping the server",
            )
            stop.put(())
          }
        },
        allow_failure=config.allow_failure,
        max_connections?=config.max_connections,
      )
    })
    stop.get() catch {
      _ => ()
    }
    // Let the requests still running finish before the acceptor — and with it every connection
    // it owns — is torn down, the same drain `serve_graceful` does. `run_forever` offers no hook
    // to stop accepting without also dropping what it is already serving.
    drain(inflight, config.graceful_timeout)
    acceptor.cancel()
  })
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
        Config::new(port=18104, limit_max_requests=2, logger=Logger::silent()),
      )
    })
    @async.sleep(300)
    let (first, _b1) = @http.get("http://127.0.0.1:18104/one")
    assert_eq(first.code, 200)
    let (second, _b2) = @http.get("http://127.0.0.1:18104/two")
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
test "helpers: method, query split, reason" {
  assert_eq(method_str(Post), "POST")
  assert_eq(method_str(Get), "GET")
  let (p, q) = split_query("/x/y?a=1&b=2")
  assert_eq(p, "/x/y")
  assert_eq(q, "a=1&b=2")
  let (p2, q2) = split_query("/noquery")
  assert_eq(p2, "/noquery")
  assert_eq(q2, "")
  assert_eq(reason(404), "Not Found")
  assert_eq(reason(200), "OK")
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
    let lifespan = Lifespan::new(app)
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
      serve_config(app, Config::new(port=18099, root_path="/api"))
    })
    @async.sleep(300)
    let (resp, _b) = @http.get("http://127.0.0.1:18099/files/a%2Fb/caf%C3%A9")
    assert_eq(resp.code, 200)
    // `path` is decoded; `raw_path` is not.
    assert_eq(seen[0], "/files/a/b/café")
    assert_eq(seen[1], "/files/a%2Fb/caf%C3%A9")
    assert_eq(seen[2], "/api")
    // run_forever gives no peer address, so ASGI's null is the honest answer.
    assert_eq(seen[3], "no-client")
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
        Config::new(
          port=18101,
          logger=Logger::new(write=line => lines.push(line)),
        ),
      )
    })
    @async.sleep(300)
    let (ok, _b) = @http.get("http://127.0.0.1:18101/hello")
    assert_eq(ok.code, 201)
    let (boom, _b2) = @http.get("http://127.0.0.1:18101/boom")
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
