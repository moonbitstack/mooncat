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
          let token = raw[start:i].trim(chars=" \t").to_owned()
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
