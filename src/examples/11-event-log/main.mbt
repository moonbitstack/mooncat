///|
/// An application that answers what it was asked, wrapped in a middleware that
/// writes one JSON line per ASGI message: the scope it was called with, every
/// `receive` and every `send`. The playground's right-hand column is this output.
///
///     moon run src/examples/11-event-log --target native
async fn main {
  @quic.serve_config(
    logged(answer),
    @mooncat.Config::new(port=12000),
    @mooncat.TlsCert::pem("src/certs/cert.pem", "src/certs/key.pem"),
  )
}

///|
/// Reads the whole body, then says what arrived; echoes WebSocket text.
async fn answer(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  match scope {
    Http(http) => {
      let mut size = 0
      for ;; {
        guard receive() is HttpRequest(body~, more_body~) else { return }
        size = size + body.length()
        if !more_body {
          break
        }
      }
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[("content-type", "text/plain")],
          trailers=false,
        ),
      )
      send(
        @moonasgi.Event::HttpResponseBody(
          body=@utf8.encode(
            "HTTP/\{http.http_version} \{http.http_method} \{http.path} · \{size} B\n",
          ),
          more_body=false,
        ),
      )
    }
    WebSocket(_) =>
      for ;; {
        match receive() {
          WebSocketConnect =>
            send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
          WebSocketReceive(text=Some(text), ..) =>
            send(@moonasgi.Event::WebSocketSendText("echo: " + text))
          WebSocketDisconnect(..) => break
          _ => ()
        }
      }
    Lifespan(_) =>
      for ;; {
        match receive() {
          LifespanStartup => send(@moonasgi.Event::LifespanStartupComplete)
          LifespanShutdown => {
            send(@moonasgi.Event::LifespanShutdownComplete)
            break
          }
          _ => ()
        }
      }
  }
}

///|
/// Any application, with every message it sees and sends written down. A message
/// is logged before it is handed on, so a line never claims what has not happened.
fn logged(app : @moonasgi.AsgiApp) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    let peer = peer_of(scope)
    emit(peer, "scope", scope_json(scope))
    app(
      scope,
      async fn() {
        let event = receive()
        emit(peer, "receive", event_json(event))
        event
      },
      async fn(event) {
        emit(peer, "send", event_json(event))
        send(event)
      },
    )
  }
}

///|
/// Times are milliseconds since the server started, on the monotonic clock: the
/// wall clock ticks too coarsely on Windows to order a request's own steps.
let started : @bench.Timestamp = @bench.monotonic_clock_start()

///|
/// Two streams of one HTTP/2 connection log at once, and a descriptor takes one
/// writer at a time.
let writing : @async.Mutex = @async.Mutex()

///|
/// Straight to the descriptor: a buffered line would reach a pipe only when the
/// process exits, and the recorder reads while the server runs.
async fn emit(peer : String, call : String, message : Json) -> Unit {
  writing.acquire()
  defer writing.release()
  @stdio.stdout.write(
    @moonjson.dumps(
      Json::object({
        "t": Json::number(@bench.monotonic_clock_end(started) / 1000.0),
        "peer": Json::string(peer),
        "call": Json::string(call),
        "message": message,
      }),
    ) +
    "\n",
  )
}

///|
fn peer_of(scope : @moonasgi.Scope) -> String {
  let client = match scope {
    Http(http) => http.client
    WebSocket(ws) => ws.client
    Lifespan(_) => None
  }
  match client {
    Some((host, port)) => "\{host}:\{port}"
    None => ""
  }
}

///|
fn pairs(headers : Array[(String, String)]) -> Json {
  Json::array(
    headers.map(h => Json::array([Json::string(h.0), Json::string(h.1)])),
  )
}

///|
/// The scope as ASGI writes it, minus the fields this server never fills.
fn scope_json(scope : @moonasgi.Scope) -> Json {
  match scope {
    Http(http) =>
      Json::object({
        "type": Json::string("http"),
        "http_version": Json::string(http.http_version),
        "method": Json::string(http.http_method),
        "scheme": Json::string(http.scheme),
        "path": Json::string(http.path),
        "headers": pairs(http.headers),
      })
    WebSocket(ws) =>
      Json::object({
        "type": Json::string("websocket"),
        "http_version": Json::string(ws.http_version),
        "scheme": Json::string(ws.scheme),
        "path": Json::string(ws.path),
        "headers": pairs(ws.headers),
      })
    Lifespan(_) => Json::object({ "type": Json::string("lifespan") })
  }
}

///|
fn text(body : Bytes) -> Json {
  Json::string(@utf8.decode_lossy(body[:]))
}

///|
/// A message as the ASGI specification spells it: its `type`, then its keys.
fn event_json(event : @moonasgi.Event) -> Json {
  let (kind, keys) : (String, Map[String, Json]) = match event {
    HttpRequest(body~, more_body~) =>
      (
        "http.request",
        { "body": text(body), "more_body": Json::boolean(more_body) },
      )
    HttpDisconnect => ("http.disconnect", {})
    HttpResponseStart(status~, headers~, trailers~) =>
      (
        "http.response.start",
        {
          "status": Json::number(status.to_double()),
          "headers": pairs(headers),
          "trailers": Json::boolean(trailers),
        },
      )
    HttpResponseBody(body~, more_body~) =>
      (
        "http.response.body",
        { "body": text(body), "more_body": Json::boolean(more_body) },
      )
    WebSocketConnect => ("websocket.connect", {})
    WebSocketAccept(subprotocol~, ..) =>
      (
        "websocket.accept",
        {
          "subprotocol": match subprotocol {
            Some(name) => Json::string(name)
            None => Json::null()
          },
        },
      )
    WebSocketReceive(text=Some(message), ..) =>
      ("websocket.receive", { "text": Json::string(message) })
    WebSocketReceive(bytes~, ..) =>
      ("websocket.receive", { "bytes": text(bytes.unwrap_or(b"")) })
    WebSocketSendText(message) =>
      ("websocket.send", { "text": Json::string(message) })
    WebSocketSendBytes(bytes) => ("websocket.send", { "bytes": text(bytes) })
    WebSocketDisconnect(code~, ..) =>
      ("websocket.disconnect", { "code": Json::number(code.to_double()) })
    WebSocketClose(code~, reason~) =>
      (
        "websocket.close",
        {
          "code": Json::number(code.to_double()),
          "reason": Json::string(reason),
        },
      )
    LifespanStartup => ("lifespan.startup", {})
    LifespanStartupComplete => ("lifespan.startup.complete", {})
    LifespanShutdown => ("lifespan.shutdown", {})
    LifespanShutdownComplete => ("lifespan.shutdown.complete", {})
    Other(type_~, ..) => (type_, {})
    _ => ("message", {})
  }
  keys["type"] = Json::string(kind)
  Json::object(keys)
}
