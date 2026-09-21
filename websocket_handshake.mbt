// The WebSocket opening handshake (RFC 6455 §4.2): a client's Upgrade request carries a
// Sec-WebSocket-Key and an optional list of subprotocols; the server proves it understood the
// protocol by returning Sec-WebSocket-Accept = base64(SHA-1(key + GUID)) in a 101 response, and
// echoes the one subprotocol it selected in Sec-WebSocket-Protocol. Building the 101 here lets
// mooncat honour the negotiated subprotocol in the response — the piece the async transport's
// fixed handshake could not express.

///|
/// The WebSocket handshake GUID appended to the client key before hashing (RFC 6455 §4.2.2).
pub let websocket_guid : String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

///|
/// The Sec-WebSocket-Accept value for a client's Sec-WebSocket-Key: base64 of the SHA-1 of the
/// key concatenated with the GUID (RFC 6455 §4.2.2).
pub fn websocket_accept_key(sec_websocket_key : String) -> String {
  @utf8.decode_lossy(
    @base64.encode_bytes(sha1(@utf8.encode(sec_websocket_key + websocket_guid)))[:],
  )
}

///|
/// Select the first client-offered subprotocol the server supports, or `None` if none match
/// (RFC 6455 §4.2.2): the client's order is its preference.
pub fn websocket_select_subprotocol(
  offered : Array[String],
  supported : Array[String],
) -> String? {
  for o in offered {
    for s in supported {
      if o == s {
        return Some(o)
      }
    }
  }
  None
}

///|
/// The 101 Switching Protocols response for a WebSocket upgrade (RFC 6455 §4.2.2): the Upgrade
/// and Connection headers, the computed Sec-WebSocket-Accept, the selected subprotocol when one
/// was negotiated, and any `extra_headers`.
pub fn websocket_handshake_response(
  sec_websocket_key : String,
  subprotocol : String?,
  extra_headers : Array[(String, String)],
) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(@utf8.encode("HTTP/1.1 101 Switching Protocols\r\n"))
  buf.write_bytes(@utf8.encode("Upgrade: websocket\r\n"))
  buf.write_bytes(@utf8.encode("Connection: Upgrade\r\n"))
  buf.write_bytes(
    @utf8.encode(
      "Sec-WebSocket-Accept: " +
      websocket_accept_key(sec_websocket_key) +
      "\r\n",
    ),
  )
  match subprotocol {
    Some(p) =>
      buf.write_bytes(@utf8.encode("Sec-WebSocket-Protocol: " + p + "\r\n"))
    None => ()
  }
  for h in extra_headers {
    buf.write_bytes(@utf8.encode(h.0 + ": " + h.1 + "\r\n"))
  }
  buf.write_bytes(@utf8.encode("\r\n"))
  buf.to_bytes()
}
