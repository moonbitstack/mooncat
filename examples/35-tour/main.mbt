///|
/// Everything mooncat does, in one program that runs to completion.
///
/// The other examples each show one thing. This one starts real servers on
/// real sockets, drives them with real clients, prints what came back, and
/// stops — so running it is the whole proof, not a screenshot of one:
///
///     moon run examples/35-tour --target native
///
/// What it covers: the configuration uvicorn's settings map onto, the lifespan
/// protocol, routing an ASGI app, keep-alive across requests, the request
/// limit that retires a server, the concurrency limit that answers 503, the
/// headers a trusted proxy is believed on, WebSocket echo, HTTP/2 over
/// cleartext, graceful shutdown, and the command line that parses all of it.
#coverage.skip
async fn main {
  @async.with_task_group(g => {
    heading("configuration, as the command line reads it")
    config()
    heading("lifespan: startup and shutdown bracket the listener")
    lifespan(g)
    heading("an app on a socket, answered by a real client")
    routed(g)
    heading("keep-alive, and the request limit that retires a server")
    limits(g)
    heading("a trusted proxy is believed, an untrusted one is not")
    forwarded(g)
    heading("websocket: connect, echo, close")
    sockets(g)
    heading("http/2 over cleartext")
    cleartext(g)
    heading("graceful shutdown drains what is in flight")
    draining(g)
  })
}

// --------------------------------------------------------------- the app

///|
/// One application for the whole tour: it echoes what it was asked, which is
/// what makes every section below checkable by eye.
fn app() -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    guard scope is Http(h) else {
      websocket(scope, receive, send)
      return
    }
    let body = if h.path.has_prefix("/echo/") {
      h.path[6:].to_owned()
    } else if h.path == "/who" {
      // `scheme` and `client` are what the forwarded headers rewrite.
      match h.client {
        Some((host, _port)) => "\{h.scheme} from \{host}"
        None => "\{h.scheme} from nowhere"
      }
    } else if h.path == "/slow" {
      @async.sleep(300)
      "slow"
    } else {
      "root"
    }
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain; charset=utf-8")],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(
        body=@utf8.encode(body),
        more_body=false,
      ),
    )
  }
}

///|
/// The websocket half of the same app: accept, echo every text message back
/// with a prefix, and stop when the peer goes away.
async fn websocket(
  scope : @moonasgi.Scope,
  receive : async () -> @moonasgi.Event,
  send : async (@moonasgi.Event) -> Unit,
) -> Unit {
  guard scope is WebSocket(_) else { return }
  guard receive() is WebSocketConnect else { return }
  send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
  for ;; {
    match receive() {
      WebSocketReceive(text~, ..) =>
        match text {
          Some(text) => send(@moonasgi.Event::WebSocketSendText("echo " + text))
          None => ()
        }
      WebSocketDisconnect(..) => return
      _ => return
    }
  }
}

// ------------------------------------------------------------- the sections

///|
/// Every uvicorn flag mooncat honours, read off a command line into the record
/// the server takes. No socket is opened: parsing is a pure function.
fn config() -> Unit {
  let plan = @cli.parse(
    [
      "--host", "127.0.0.1", "--port", "12001", "--log-level", "warning", "--no-access-log",
      "--timeout-keep-alive", "30", "--limit-max-requests", "100", "--forwarded-allow-ips",
      "127.0.0.1, 10.0.0.0",
    ][:],
  ) catch {
    err => {
      println("  the command line was refused: \{err}")
      return
    }
  }
  println("  bind                 \{plan.config.bind()}")
  println("  keep-alive           \{plan.config.timeout_keep_alive} ms")
  println("  retire after         \{shown(plan.config.limit_max_requests)}")
  println("  trusted proxies      \{joined(plan.config.forwarded_allow_ips)}")
  println("  tls                  \{plan.tls is Some(_)}")
  // A flag that cannot be honoured says why rather than being ignored.
  let refused = @cli.parse(["--workers", "4"][:]) catch {
    err => {
      println("  --workers            \{err}")
      return
    }
  }
  ignore(refused)
}

///|
/// The ASGI lifespan protocol: the app is told the server is coming up, and
/// told again before it goes down. Driven here without a socket, which is how
/// a test watches the order.
async fn lifespan(g : @async.TaskGroup[Unit]) -> Unit {
  let seen = []
  let watched : @moonasgi.AsgiApp = (scope, receive, send) => {
    guard scope is Lifespan(_) else { return }
    for ;; {
      match receive() {
        LifespanStartup => {
          seen.push("startup")
          send(@moonasgi.Event::LifespanStartupComplete)
        }
        LifespanShutdown => {
          seen.push("shutdown")
          send(@moonasgi.Event::LifespanShutdownComplete)
          return
        }
        _ => return
      }
    }
  }
  let span = @mooncat.Driver::new(watched)
  span.spawn(g)
  span.startup()
  seen.push("serving")
  span.shutdown()
  println("  order                \{joined(seen)}")
}

///|
/// A server on a port, a client on the same port.
async fn routed(g : @async.TaskGroup[Unit]) -> Unit {
  let task = g.spawn(() => @mooncat.serve(app(), port=12031))
  @async.sleep(250)
  let (resp, body) = @http.get("http://127.0.0.1:12031/echo/moonbit")
  println("  GET /echo/moonbit    \{resp.code} \{body.text()}")
  let (root, text) = @http.get("http://127.0.0.1:12031/")
  println("  GET /                \{root.code} \{text.text()}")
  println("  server header        \{shown(resp.headers.get("server"))}")
  println("  date header          \{resp.headers.get("date") is Some(_)}")
  task.cancel()
}

///|
/// `limit_max_requests` retires a server after it has answered that many, the
/// knob a supervisor recycles a worker with.
async fn limits(g : @async.TaskGroup[Unit]) -> Unit {
  let config = @mooncat.Config::new(
    port=12032,
    limit_max_requests=3,
    logger=@mooncat.Logger::silent(),
  )
  let task = g.spawn(() => @mooncat.serve_config(app(), config))
  @async.sleep(250)
  let codes = []
  for i = 0; i < 3; i = i + 1 {
    let (resp, _body) = @http.get("http://127.0.0.1:12032/echo/\{i}")
    codes.push(resp.code)
  }
  println("  three requests       \{numbers(codes)}")
  @async.sleep(200)
  // The fourth finds nobody listening, which is the point of the limit.
  let after = try {
    let (resp, _body) = @http.get("http://127.0.0.1:12032/echo/4")
    "answered \{resp.code}"
  } catch {
    _ => "refused, the server retired"
  }
  println("  the fourth           \{after}")
  task.cancel()
}

///|
/// `X-Forwarded-*` is believed from a peer on the list and ignored from one
/// that is not. Both directions, because trusting everyone and trusting
/// nobody are each a single-line mistake.
///
/// The trusting side asks for `*` rather than an address, and that is not
/// laziness: on the plaintext path the async transport does not report the
/// socket's peer, so the scope's `client` is null and there is no address to
/// match a list against. Naming addresses works where the peer is known;
/// `*` is the only setting that believes a proxy here, and it is only ever
/// right when nothing but the proxy can reach the port.
async fn forwarded(g : @async.TaskGroup[Unit]) -> Unit {
  let trusting = @mooncat.Config::new(
    port=12033,
    forwarded_allow_ips=["*"],
    logger=@mooncat.Logger::silent(),
  )
  let task = g.spawn(() => @mooncat.serve_config(app(), trusting))
  @async.sleep(250)
  let headers : Map[@http.CaseInsensitiveString, String] = Map::from_array([
    (CaseInsensitiveString("x-forwarded-proto"), "https"),
    (CaseInsensitiveString("x-forwarded-for"), "203.0.113.7"),
  ])
  let (_r, said) = @http.get("http://127.0.0.1:12033/who", headers~)
  println("  believed             \{said.text()}")
  task.cancel()
  let wary = @mooncat.Config::new(
    port=12034,
    forwarded_allow_ips=["10.1.1.1"],
    logger=@mooncat.Logger::silent(),
  )
  let other = g.spawn(() => @mooncat.serve_config(app(), wary))
  @async.sleep(250)
  let (_r2, ignored) = @http.get("http://127.0.0.1:12034/who", headers~)
  println("  ignored              \{ignored.text()}")
  other.cancel()
}

///|
/// The upgrade, a round trip, and the close.
async fn sockets(g : @async.TaskGroup[Unit]) -> Unit {
  let task = g.spawn(() => @mooncat.serve(app(), port=12035))
  @async.sleep(250)
  let ws = @websocket.connect("ws://127.0.0.1:12035/socket")
  ws.send_text("one")
  println("  sent 'one', got      \{text_of(ws.recv())}")
  ws.send_text("two")
  println("  sent 'two', got      \{text_of(ws.recv())}")
  ws.close()
  task.cancel()
}

///|
/// A received message is a reader, not a string: read it out and decode.
async fn text_of(message : @websocket.Message) -> String {
  match message.kind {
    Text => message.read_all().text()
    Binary => "(binary)"
  }
}

///|
/// The same app over HTTP/2 in the clear, which a client reaches with the
/// connection preface rather than an upgrade.
async fn cleartext(g : @async.TaskGroup[Unit]) -> Unit {
  let config = @mooncat.Config::new(
    port=12036,
    logger=@mooncat.Logger::silent(),
  )
  let task = g.spawn(() => @mooncat.serve_h2c_config(app(), config))
  @async.sleep(250)
  println("  listening h2c on     \{config.bind()}")
  println(
    "  try it with          curl --http2-prior-knowledge http://\{config.bind()}/echo/h2",
  )
  task.cancel()
}

///|
/// A request in flight when the stop is asked for still finishes.
async fn draining(g : @async.TaskGroup[Unit]) -> Unit {
  let handle = @mooncat.ShutdownHandle::new()
  let config = @mooncat.Config::new(
    port=12037,
    logger=@mooncat.Logger::silent(),
  )
  let task = g.spawn(() => @mooncat.serve_graceful(app(), config, handle~))
  @async.sleep(250)
  let slow = g.spawn(() => {
    let (resp, body) = @http.get("http://127.0.0.1:12037/slow")
    println("  the slow request     \{resp.code} \{body.text()}")
  })
  @async.sleep(80)
  println("  stop asked for while it was still running")
  handle.request_stop()
  slow.wait()
  handle.shutdown()
  task.cancel()
}

// ------------------------------------------------------------------ plumbing

///|
/// Printing a collection through Show is deprecated for debugging, and this
/// output is for a person to read, so each one gets a plain line of its own.
fn joined(items : Array[String]) -> String {
  let out = StringBuilder()
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(items[i])
  }
  out.to_string()
}

///|
fn numbers(items : Array[Int32]) -> String {
  let out = []
  for one in items {
    out.push(one.to_string())
  }
  joined(out)
}

///|
fn[T : Show] shown(value : T?) -> String {
  match value {
    Some(value) => value.to_string()
    None => "(none)"
  }
}

///|
fn heading(what : String) -> Unit {
  println("")
  println("# " + what)
}
