// The raw-stream WebSocket bridge (`serve_websocket_raw`) driven end to end by a real moonasgi app.

///|
/// A minimal ASGI WebSocket echo app: accept with the `chat` subprotocol, then echo every text /
/// binary message back until the peer disconnects.
async fn ws_raw_echo_app(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is WebSocket(_) else { return }
  for ;; {
    match receive() {
      WebSocketConnect =>
        send(
          @moonasgi.Event::WebSocketAccept(subprotocol=Some("chat"), headers=[]),
        )
      WebSocketReceive(text~, bytes~) =>
        match text {
          Some(t) => send(@moonasgi.Event::WebSocketSendText(t))
          None =>
            match bytes {
              Some(b) => send(@moonasgi.Event::WebSocketSendBytes(b))
              None => ()
            }
        }
      WebSocketDisconnect(..) => break
      _ => ()
    }
  }
}

///|
/// The RFC 6455 §1.3 handshake request headers (key `dGhlIHNhbXBsZSBub25jZQ==`), offering the
/// `chat` and `superchat` subprotocols.
fn ws_upgrade_request() -> Http1Request {
  {
    http_method: "GET",
    target: "/chat",
    version: "HTTP/1.1",
    headers: Map([
      ("upgrade", "websocket"),
      ("connection", "Upgrade"),
      ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="),
      ("sec-websocket-version", "13"),
      ("sec-websocket-protocol", "chat, superchat"),
    ]),
    content_length: 0,
    chunked: false,
    expect_continue: false,
  }
}

///|
async test "serve_websocket_raw completes the handshake with a subprotocol echo and echoes a message" {
  @async.with_task_group(g => {
    // Inbound: a masked client text "hi", then a masked close.
    let mask = b"\x01\x02\x03\x04"
    let text = ({ fin: true, opcode: Text, payload: b"hi", } : @ws.Frame).encode(
      mask~,
    )
    let close = (
      { fin: true, opcode: Close, payload: @ws.close(1000), } : @ws.Frame).encode(
      mask~,
    )
    let reader : &@io.Reader = @io.MemoryReader(async fn(w) {
      w.write(text)
      w.write(close)
    })
    let (pr, pw) = @pipe.pipe()
    let writer : &@io.Writer = pw
    let _ = g.spawn(() => {
      serve_websocket_raw(
        ws_raw_echo_app,
        ws_upgrade_request(),
        reader,
        writer,
        config=Config::new(),
      )
    })
    // The 101 response carries the RFC 6455 §1.3 accept key and the negotiated subprotocol.
    let resp = pr.read_until("\r\n\r\n").unwrap_or("")
    assert_eq(resp.contains("101 Switching Protocols"), true)
    assert_eq(
      resp.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
      true,
    )
    assert_eq(resp.contains("Sec-WebSocket-Protocol: chat"), true)
    // The server echoed "hi" back as an unmasked text frame.
    let echoed = expect_frame(pr)
    assert_eq(echoed.opcode, Text)
    assert_eq(echoed.payload, b"hi")
  })
}

///|
/// A peer that breaks RFC 6455 must be told which rule it broke, not merely dropped: the bridge
/// writes a close frame carrying the violation's status code (§7.1.7) and hands the app a
/// disconnect with that same code, so `1002` (a protocol error) is distinguishable from `1006`
/// (the peer simply vanished).
async test "serve_websocket_raw fails a protocol violation with its close code" {
  @async.with_task_group(g => {
    let seen : Array[Int] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is WebSocket(_) else { return }
      for ;; {
        match receive() {
          WebSocketConnect =>
            send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
          WebSocketDisconnect(code~, ..) => {
            seen.push(code)
            break
          }
          _ => ()
        }
      }
    }
    // An unmasked client text frame — §5.1 says the connection must be failed with 1002.
    let reader = bytes_reader(
      ({ fin: true, opcode: Text, payload: b"unmasked", } : @ws.Frame).encode(),
    )
    let (pr, pw) = @pipe.pipe()
    let writer : &@io.Writer = pw
    let task = g.spawn(() => {
      serve_websocket_raw(
        app,
        ws_upgrade_request(),
        reader,
        writer,
        config=Config::new(),
      )
    })
    ignore(pr.read_until("\r\n\r\n"))
    // The close frame the server sent carries 1002 (0x03ea).
    let closed = expect_frame(pr)
    assert_eq(closed.opcode, Close)
    assert_eq(closed.payload, b"\x03\xea")
    task.wait()
    assert_eq(seen, [1002])
  })
}

///|
/// The same path with the ceiling in play: a frame announcing more than `ws.max_size` is refused
/// with 1009 before its payload is read.
async test "serve_websocket_raw fails an oversized frame with 1009" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is WebSocket(_) else { return }
      for ;; {
        match receive() {
          WebSocketConnect =>
            send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
          WebSocketDisconnect(..) => break
          _ => ()
        }
      }
    }
    let reader = bytes_reader(
      (
        { fin: true, opcode: Binary, payload: Bytes::make(64, b'x'), } :
        @ws.Frame).encode(mask=b"\x01\x02\x03\x04"),
    )
    let (pr, pw) = @pipe.pipe()
    let writer : &@io.Writer = pw
    let task = g.spawn(() => {
      serve_websocket_raw(
        app,
        ws_upgrade_request(),
        reader,
        writer,
        config=Config::new(ws=WsConfig::new(max_size=16)),
      )
    })
    ignore(pr.read_until("\r\n\r\n"))
    let closed = expect_frame(pr)
    assert_eq(closed.opcode, Close)
    // 1009 = 0x03f1.
    assert_eq(closed.payload, b"\x03\xf1")
    task.wait()
  })
}
