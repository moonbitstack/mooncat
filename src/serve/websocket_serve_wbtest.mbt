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
fn ws_upgrade_request() -> @http1.Request {
  // Read through the real parser, so the test drives exactly what a socket would.
  let wire = @utf8.encode(
    "GET /chat HTTP/1.1\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
    "Sec-WebSocket-Version: 13\r\n" +
    "Sec-WebSocket-Protocol: chat, superchat\r\n\r\n",
  )
  @http1.request(wire[:]).0 catch {
    e => abort("the RFC 6455 §1.3 request should parse: \{e}")
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
        config=@config.Config::new(),
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
    let seen : Array[Int32] = []
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
        config=@config.Config::new(),
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
        config=@config.Config::new(ws=@config.WsConfig::new(max_size=16)),
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

///|
/// `wss://` end to end: a TLS client sends the RFC 6455 upgrade, gets the 101 back over the
/// encrypted stream, and a masked text frame comes back echoed by the app. The upgrade rides the
/// self-built HTTP/1.1 path that `serve_tls` uses, so nothing of the async WebSocket is involved.
async test "wss: an upgrade over TLS completes and a text frame is echoed" {
  let port = 18444
  @async.with_task_group(g => {
    let task = g.spawn(() => {
      serve_tls_config(
        ws_raw_echo_app,
        @config.Config::new(port~, logger=@config.Logger::silent()),
        test_cert(),
      )
    })
    @async.sleep(400)
    let tls = @tcp.dial("127.0.0.1", port~, tls=pinned(["http/1.1"]))
    defer tls.close()
    tls.write(
      "GET /chat HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" +
      "Sec-WebSocket-Protocol: chat\r\n\r\n",
    )
    let head = tls.read_until("\r\n\r\n").unwrap_or("")
    assert_true(head.contains("101 Switching Protocols"))
    assert_true(head.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
    let hi : @ws.Frame = { fin: true, opcode: Text, payload: b"hi", }
    tls.write(hi.encode(mask=b"\x01\x02\x03\x04"))
    assert_eq(tls.read_exactly(4), b"\x81\x02hi")
    task.cancel()
  })
}

///|
/// A handshake request from a client that offers compression.
fn ws_deflate_request() -> @http1.Request {
  let wire = @utf8.encode(
    "GET /chat HTTP/1.1\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
    "Sec-WebSocket-Version: 13\r\n" +
    "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n",
  )
  @http1.request(wire[:]).0 catch {
    e => abort("the request should parse: \{e}")
  }
}

///|
/// Run the echo application over a client's bytes and read everything it wrote, the 101 included.
async fn ws_exchange(
  req : @http1.Request,
  config : @config.Config,
  input : async (&@io.Writer) -> Unit,
) -> Bytes {
  let (in_reader, in_writer) = @pipe.pipe()
  let (out_reader, out_writer) = @pipe.pipe()
  let reader : &@io.Reader = in_reader
  let writer : &@io.Writer = out_writer
  let collected = Buffer()
  @async.with_task_group(g => {
    g.spawn_bg(no_wait=true, () => {
      input(in_writer)
      in_writer.close()
    })
    g.spawn_bg(() => {
      serve_websocket_raw(ws_raw_echo_app, req, reader, writer, config~)
      out_writer.close()
    })
    collected.write_bytes(out_reader.read_all().binary())
  })
  collected.to_bytes()
}

///|
/// The bytes after a 101's blank line.
fn after_head(data : Bytes) -> Bytes {
  for i = 0; i + 4 <= data.length(); i = i + 1 {
    if data[i:i + 4] == b"\r\n\r\n"[:] {
      return data[i + 4:].to_owned()
    }
  }
  b""
}

///|
async test "a client that offers compression gets it, both ways" {
  let terms = @pmd.Extension::agree(@pmd.offers("permessage-deflate"[:])[:]).unwrap()
  let client = @pmd.Writer::new(extension=terms, role=Client)
  let text = "the same words the same words the same words the same words"
  let (frame, compressed) = client.frame(Text, @utf8.encode(text)[:])
  assert_true(compressed)
  let mask = b"\x01\x02\x03\x04"
  let got = ws_exchange(ws_deflate_request(), @config.Config::new(), async fn(
    w,
  ) {
    w.write(frame.encode_extension(mask~, rsv1=true))
    w.write(
      ({ fin: true, opcode: Close, payload: @ws.close(1000), } : @ws.Frame).encode(
        mask~,
      ),
    )
  })
  let head = @utf8.decode_lossy(got)
  assert_true(head.contains("sec-websocket-extensions: permessage-deflate"))
  let (reply, _, rsv1) = @ws.decode_extension(after_head(got)[:], client=false).unwrap()
  assert_true(rsv1)
  let back = @pmd.Reader::new(extension=terms, role=Client).feed(
    reply,
    compressed=true,
  )
  assert_eq(back.message, Some(Text(text)))
}

///|
async test "compression turned off answers plainly, offered or not" {
  let config = @config.Config::new(
    ws=@config.WsConfig::new(deflate=false, ping_interval=None),
  )
  let mask = b"\x01\x02\x03\x04"
  let got = ws_exchange(ws_deflate_request(), config, async fn(w) {
    w.write(
      ({ fin: true, opcode: Text, payload: b"plain", } : @ws.Frame).encode(
        mask~,
      ),
    )
    w.write(
      ({ fin: true, opcode: Close, payload: @ws.close(1000), } : @ws.Frame).encode(
        mask~,
      ),
    )
  })
  assert_false(@utf8.decode_lossy(got).contains("sec-websocket-extensions"))
  let (reply, _) = @ws.decode(after_head(got)[:], client=false).unwrap()
  assert_eq(reply.payload, b"plain")
}

///|
async test "a set RSV bit without compression agreed fails the connection" {
  let mask = b"\x01\x02\x03\x04"
  let got = ws_exchange(ws_upgrade_request(), @config.Config::new(), async fn(
    w,
  ) {
    w.write(
      ({ fin: true, opcode: Text, payload: b"x", } : @ws.Frame).encode_extension(
        mask~,
        rsv1=true,
      ),
    )
  })
  let (reply, _) = @ws.decode(after_head(got)[:], client=false).unwrap()
  assert_eq(reply.opcode, Close)
  assert_eq(@ws.status(reply.payload[:]), 1002)
}

///|
async test "a peer that does not answer a ping is closed with 1011, one that does stays" {
  let config = @config.Config::new(
    ws=@config.WsConfig::new(ping_interval=Some(30), ping_timeout=Some(30)),
  )
  let mask = b"\x01\x02\x03\x04"
  let got = ws_exchange(ws_upgrade_request(), config, async fn(_w) {
    @async.sleep(200)
  })
  let tail = after_head(got)
  let (ping, used) = @ws.decode(tail[:], client=false).unwrap()
  assert_eq(ping.opcode, Ping)
  let (close, _) = @ws.decode(tail[used:], client=false).unwrap()
  assert_eq(close.opcode, Close)
  assert_eq(@ws.status(close.payload[:]), 1011)
  let lively = ws_exchange(ws_upgrade_request(), config, async fn(w) {
    for _ in 0..<8 {
      @async.sleep(20)
      w.write(
        ({ fin: true, opcode: Pong, payload: b"", } : @ws.Frame).encode(mask~),
      )
    }
    w.write(
      ({ fin: true, opcode: Close, payload: @ws.close(1000), } : @ws.Frame).encode(
        mask~,
      ),
    )
  })
  assert_false(closes_with(after_head(lively), 1011))
}

///|
/// Whether the frames in `data` include a close with `code`.
fn closes_with(data : Bytes, code : Int32) -> Bool {
  let mut at = 0
  while at < data.length() {
    guard (@ws.decode(data[at:], client=false) catch { _ => None })
      is Some((frame, used)) else {
      break
    }
    if frame.opcode == Close && @ws.status(frame.payload[:]) == code {
      return true
    }
    at = at + used
  }
  false
}
