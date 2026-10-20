///|
/// True when a request is a WebSocket upgrade handshake: `Upgrade: websocket`
/// plus an `upgrade` token in `Connection`, compared case-insensitively per
/// RFC 6455 / ASGI header rules.
fn is_websocket_upgrade(headers : Map[String, String]) -> Bool {
  let upgraded = match headers.get("upgrade") {
    Some(u) => u.to_lower() == "websocket"
    None => false
  }
  let connection = match headers.get("connection") {
    Some(c) => c.to_lower().contains("upgrade")
    None => false
  }
  upgraded && connection
}

///|
/// True for ASCII space / tab, the optional whitespace RFC 7230 allows around
/// comma-separated list elements. Takes the `UInt16` code unit `String`
/// indexing yields.
fn is_ows(c : UInt16) -> Bool {
  c == ' ' || c == '\t'
}

///|
/// Trim leading/trailing ASCII space and tab from `s` (core has no `trim`).
fn ascii_trim(s : String) -> String {
  let n = s.length()
  let mut a = 0
  let mut b = n
  while a < b && is_ows(s[a]) {
    a = a + 1
  }
  while b > a && is_ows(s[b - 1]) {
    b = b - 1
  }
  s[a:b].to_owned()
}

///|
/// Parse the `sec-websocket-protocol` request header into the ordered list of
/// client-offered subprotocols, splitting on commas and trimming optional
/// whitespace, per RFC 6455 §4.1 / §11.3.4. These populate `WebSocketScope`'s
/// `subprotocols`, from which the app picks one to echo back in
/// `WebSocketAccept`.
fn parse_subprotocols(headers : Map[String, String]) -> Array[String] {
  match headers.get("sec-websocket-protocol") {
    None => []
    Some(raw) => {
      let out : Array[String] = []
      let n = raw.length()
      let mut start = 0
      for i = 0; i <= n; i = i + 1 {
        if i == n || raw[i] == ',' {
          let token = ascii_trim(raw[start:i].to_owned())
          if token.length() > 0 {
            out.push(token)
          }
          start = i + 1
        }
      }
      out
    }
  }
}

///|
/// Map a `moonbitlang/async` websocket `CloseCode` to its numeric RFC 6455
/// status, for the `code` carried on an ASGI `websocket.disconnect`.
fn close_code_int(code : @websocket.CloseCode) -> Int32 {
  match code {
    Normal => 1000
    GoingAway => 1001
    ProtocolError => 1002
    UnsupportedData => 1003
    Abnormal => 1006
    InvalidFramePayload => 1007
    PolicyViolation => 1008
    MessageTooBig => 1009
    MissingExtension => 1010
    InternalError => 1011
    Other(i) => i.to_int()
  }
}

///|
/// Map an ASGI `websocket.close` numeric `code` to the transport's `CloseCode`,
/// so a close initiated by the app is sent with the right status on the wire.
fn close_code_of_int(n : Int32) -> @websocket.CloseCode {
  match n {
    1000 => Normal
    1001 => GoingAway
    1002 => ProtocolError
    1003 => UnsupportedData
    1006 => Abnormal
    1007 => InvalidFramePayload
    1008 => PolicyViolation
    1009 => MessageTooBig
    1010 => MissingExtension
    1011 => InternalError
    _ => Other(n.to_uint16())
  }
}

///|
/// Bridge a WebSocket connection through the moonasgi SEAM (← uvicorn's
/// `WSProtocol`). Builds a `websocket` `Scope` and drives the app with a
/// `Receive`/`Send` pair that translate between ASGI events and real frames:
///
/// * `receive()` yields `websocket.connect` first, then reads inbound frames —
///   a **text** frame becomes `WebSocketReceive(text=..)`, a **binary** frame
///   `WebSocketReceive(bytes=..)` (each message is drained through the
///   `Message`-as-`Reader`, so fragmented/streamed frames reassemble), and a
///   peer close becomes `WebSocketDisconnect(code=..)`.
/// * `send(WebSocketAccept)` completes the 101 handshake (deferred until accept,
///   so the app may reject *before* upgrade — see below); `send(WebSocketSendText
///   / WebSocketSendBytes)` writes a message frame; `send(WebSocketClose)` sends a
///   close frame with the given code and reason.
///
/// Rejection: per ASGI, `websocket.close` sent *before* `websocket.accept`
/// declines the upgrade — mooncat answers the still-plain HTTP connection with
/// `403 Forbidden`, exactly as uvicorn does.
///
/// ping/pong are handled at the protocol layer by `moonbitlang/async` inside
/// `recv()` (an inbound PING is auto-answered with a PONG), and — as in uvicorn
/// — are deliberately not surfaced to the ASGI app.
///
/// Subprotocol negotiation: the client's offered subprotocols are parsed into
/// `WebSocketScope::subprotocols` and the app selects one via
/// `WebSocketAccept(subprotocol=..)`. Echoing the selection into the 101
/// response's `Sec-WebSocket-Protocol` header is not yet possible — the async
/// transport's `from_http_server` fixes the handshake response headers — so the
/// negotiation is observed and honoured at the ASGI layer but the response-header
/// echo awaits a transport hook. This is a transport-capability gap, not a
/// behavioural choice.
async fn handle_websocket(
  app : @moonasgi.AsgiApp,
  request : @http.Request,
  conn : @http.ServerConnection,
  config~ : Config,
  client_addr? : @socket.Addr,
) -> Unit {
  let (path, query) = split_query(request.path)
  let peer = match client_addr {
    Some(a) => Some(addr_pair(a))
    None => None
  }
  let (client, scheme) = if config.proxy_headers {
    proxy_rewrite(
      request.headers,
      peer,
      "ws",
      trusted=config.forwarded_allow_ips,
      websocket=true,
    )
  } else {
    (peer, "ws")
  }
  let scope = @moonasgi.Scope::WebSocket({
    http_version: "1.1",
    scheme,
    path,
    raw_path: @utf8.encode(path),
    query_string: @utf8.encode(query),
    root_path: config.root_path,
    headers: headers_to_pairs(request.headers),
    client,
    server: None,
    subprotocols: parse_subprotocols(request.headers),
    asgi: @moonasgi.AsgiVersion::websocket(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
  let ws_ref : Ref[@websocket.Conn?] = Ref(None)
  let connected = Ref(false)
  let disconnected = Ref(false)
  let handled = Ref(false)
  let receive : @moonasgi.Receive = () => {
    if not_yet(connected) {
      return @moonasgi.Event::WebSocketConnect
    }
    if disconnected.val {
      return @moonasgi.Event::WebSocketDisconnect(code=1006, reason=None)
    }
    match ws_ref.val {
      None => @moonasgi.Event::WebSocketDisconnect(code=1006, reason=None)
      Some(ws) =>
        try {
          let msg = ws.recv()
          match msg.kind {
            Text =>
              @moonasgi.Event::WebSocketReceive(
                text=Some(msg.read_all().text()),
                bytes=None,
              )
            Binary =>
              @moonasgi.Event::WebSocketReceive(
                text=None,
                bytes=Some(msg.read_all().binary()),
              )
          }
        } catch {
          @websocket.ConnectionClosed(code, _) => {
            disconnected.val = true
            @moonasgi.Event::WebSocketDisconnect(
              code=close_code_int(code),
              reason=None,
            )
          }
          _ => {
            disconnected.val = true
            @moonasgi.Event::WebSocketDisconnect(code=1006, reason=None)
          }
        }
    }
  }
  let send : @moonasgi.Send = event => {
    match event {
      WebSocketAccept(subprotocol=_, headers=_) =>
        if ws_ref.val is None {
          let ws = @websocket.Conn::from_http_server(request, conn)
          ws_ref.val = Some(ws)
        }
      WebSocketSendText(text) =>
        match ws_ref.val {
          Some(ws) => ws.send_text(text)
          None => ()
        }
      WebSocketSendBytes(data) =>
        match ws_ref.val {
          Some(ws) => ws.send_binary(data[:])
          None => ()
        }
      WebSocketClose(code~, reason~) =>
        match ws_ref.val {
          Some(ws) => {
            handled.val = true
            ws.send_close(code=close_code_of_int(code), reason~) catch {
              _ => ()
            }
            ws.close()
          }
          None => {
            handled.val = true
            conn..send_response(403, "Forbidden").end_response() catch {
              _ => ()
            }
          }
        }
      _ => ()
    }
  }
  app(scope, receive, send)
  match ws_ref.val {
    Some(ws) => ws.close()
    None =>
      if !handled.val {
        conn..send_response(403, "Forbidden").end_response() catch {
          _ => ()
        }
      }
  }
}

///|
/// One-shot latch: return `true` the first time it is polled, `false` after,
/// used to emit `websocket.connect` exactly once at the head of the stream.
fn not_yet(flag : Ref[Bool]) -> Bool {
  if flag.val {
    false
  } else {
    flag.val = true
    true
  }
}
