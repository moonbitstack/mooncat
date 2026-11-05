// The WebSocket bridge over any byte stream (`&@io.Reader`/`&@io.Writer`), so `ws://` and
// `wss://` share it. mooncat writes the 101 itself, which is what lets the negotiated
// subprotocol go back in `Sec-WebSocket-Protocol`.

///|
/// Bridge a WebSocket connection to a moonasgi application over the raw HTTP/1.1 stream `reader` /
/// `writer` (← uvicorn's `WSProtocol`):
///
/// * `receive()` yields `websocket.connect` first, then reads messages with `ws_read_message`
///   (which reassembles fragments, answers pings, and echoes a close) — a text message becomes
///   `WebSocketReceive(text=..)`, a binary one `WebSocketReceive(bytes=..)`, and a peer close
///   `WebSocketDisconnect(code=..)`.
/// * `send(WebSocketAccept)` writes the self-built 101 (with the negotiated `Sec-WebSocket-Protocol`
///   echoed); `send(WebSocketSendText / WebSocketSendBytes)` writes a message frame;
///   `send(WebSocketClose)` writes a close frame; a close sent *before* accept declines the upgrade
///   with `403 Forbidden`, as uvicorn does.
///
/// A peer that breaks RFC 6455 fails the connection rather than being tolerated: the violation's
/// close code goes out as a close frame (§7.1.7) and the app sees a disconnect carrying that same
/// code, so an app can tell a protocol failure from a peer that simply went away (`1006`).
async fn serve_websocket_raw(
  app : @moonasgi.AsgiApp,
  req : @http1.Request,
  reader : &@io.Reader,
  writer : &@io.Writer,
  link~ : Link = Link::plain(),
  config~ : @config.Config,
) -> Unit {
  let link = { ..link, scheme: if link.tls is Some(_) { "wss" } else { "ws" }, }
  let (raw_path, query) = split_query(req.target)
  let headers = fields_pairs(req.fields)
  let (client, scheme) = seen_from(
    link,
    config,
    headers,
    link.scheme,
    websocket=true,
  )
  let scope = @moonasgi.Scope::WebSocket({
    http_version: "1.1",
    scheme,
    path: @utf8.decode_lossy(percent_decode(raw_path)),
    raw_path: Some(@utf8.encode(raw_path)),
    query_string: @utf8.encode(query),
    root_path: config.root_path,
    headers,
    client,
    server: server_pair(link.bound),
    subprotocols: parse_subprotocols(fields_map(req.fields)),
    asgi: @moonasgi.AsgiVersion::websocket(),
    extensions: ws_extensions(link),
    state: link.state.copy(),
  })
  let fields = fields_map(req.fields)
  let connected = Ref(false)
  let accepted = Ref(false)
  let closed = Ref(false)
  let wire = Wire::new(writer)
  let inbox : @aqueue.Queue[Inbound] = @aqueue.Queue(
    kind=Blocking(config.ws.max_queue),
  )
  let terms = if config.ws.deflate {
    fields
    .get("sec-websocket-extensions")
    .bind(offer => @pmd.Extension::agree(@pmd.offers(offer[:])[:]))
  } else {
    None
  }
  @async.with_task_group(group => {
    let receive : @moonasgi.Receive = () => {
      if not_yet(connected) {
        return @moonasgi.Event::WebSocketConnect
      }
      if closed.val {
        return @moonasgi.Event::WebSocketDisconnect(code=1006, reason=None)
      }
      match inbox.get() {
        Failed(code) => {
          closed.val = true
          @moonasgi.Event::WebSocketDisconnect(code~, reason=None)
        }
        Arrived(Text(text)) =>
          @moonasgi.Event::WebSocketReceive(text=Some(text), bytes=None)
        Arrived(Binary(bytes)) =>
          @moonasgi.Event::WebSocketReceive(text=None, bytes=Some(bytes))
        Arrived(Close(status~, ..)) => {
          closed.val = true
          @moonasgi.Event::WebSocketDisconnect(code=status, reason=None)
        }
      }
    }
    let send : @moonasgi.Send = event => {
      match event {
        WebSocketAccept(subprotocol~, headers~) =>
          if !accepted.val {
            accepted.val = true
            let key = fields.get("sec-websocket-key").unwrap_or("")
            let protocol = subprotocol
            let extra = headers.copy()
            if terms is Some(agreed) {
              extra.push(
                ("sec-websocket-extensions", agreed.encode(role=Server)),
              )
              wire.compress(agreed)
            }
            wire.write(@upgrade.response(key, protocol?, extra=extra[:]))
            group.spawn_bg(no_wait=true, () => {
              pump(reader, wire, inbox, config.ws, terms)
            })
            if config.ws.ping_interval is Some(every) {
              group.spawn_bg(no_wait=true, () => {
                keep_alive(wire, inbox, every, config.ws.ping_timeout)
              })
            }
          }
        WebSocketSendText(text) =>
          if accepted.val {
            wire.message(Text, @utf8.encode(text))
          }
        WebSocketSendBytes(data) =>
          if accepted.val {
            wire.message(Binary, data)
          }
        WebSocketClose(code~, reason~) => {
          if accepted.val {
            wire.frame(Close, @ws.close(code, reason~))
          } else {
            wire.write(@utf8.encode("HTTP/1.1 403 Forbidden\r\n\r\n"))
          }
          closed.val = true
        }
        _ => ()
      }
    }
    app(scope, receive, send)
  })
}

///|
/// What the reading task hands the application: a message, or the code the connection ended with.
priv enum Inbound {
  Arrived(@ws.Message)
  Failed(Int32)
}

///|
/// The write half of a connection. The application and the reading task, which owes the peer pongs
/// and close echoes, both write, so the lock keeps one frame from landing inside another.
priv struct Wire {
  writer : &@io.Writer
  lock : @async.Mutex
  mut deflater : @pmd.Writer?
  // When the last pong arrived, by `@async.now`.
  mut pong : Int64
}

///|
fn Wire::new(writer : &@io.Writer) -> Wire {
  { writer, lock: @async.Mutex(), deflater: None, pong: 0L, }
}

///|
fn Wire::compress(self : Wire, terms : @pmd.Extension) -> Unit {
  self.deflater = Some(@pmd.Writer::new(extension=terms, role=Server))
}

///|
async fn Wire::write(self : Wire, data : Bytes) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  self.writer.write(data)
}

///|
/// A control frame, or any frame that is not to be compressed.
async fn Wire::frame(self : Wire, opcode : @ws.Opcode, payload : Bytes) -> Unit {
  self.write(({ fin: true, opcode, payload, } : @ws.Frame).encode())
}

///|
/// A whole message, compressed when the connection agreed to that.
async fn Wire::message(
  self : Wire,
  opcode : @ws.Opcode,
  payload : Bytes,
) -> Unit {
  match self.deflater {
    Some(deflater) => {
      let (frame, compressed) = deflater.frame(opcode, payload[:])
      self.write(frame.encode_extension(rsv1=compressed))
    }
    None => self.frame(opcode, payload)
  }
}

///|
/// Read the connection until it ends, handing messages to the application. A full `inbox` stops the
/// reading, which is what holds a fast client back. A peer that breaks RFC 6455 fails the connection
/// with the code the violation names (§7.1.7), and a peer that went away reaches the application as
/// `1006`.
async fn pump(
  reader : &@io.Reader,
  wire : Wire,
  inbox : @aqueue.Queue[Inbound],
  config : @config.WsConfig,
  terms : @pmd.Extension?,
) -> Unit {
  let limit = config.max_size
  let feed : (@ws.Frame, Bool) -> @ws.Step raise @ws.Refused = match terms {
    Some(agreed) => {
      let reader = @pmd.Reader::new(extension=agreed, role=Server, limit~)
      (frame, compressed) => reader.feed(frame, compressed~)
    }
    None => {
      let reader = @ws.Reader::new(limit~)
      (frame, _) => reader.feed(frame)
    }
  }
  let code = try {
    for ;; {
      let (frame, compressed) = next_frame(
        reader,
        client=true,
        limit~,
        extended=terms is Some(_),
      )
      if frame.opcode is Pong {
        wire.pong = @async.now()
      }
      let step = feed(frame, compressed)
      if step.reply is Some(reply) {
        wire.write(reply.encode())
      }
      if step.message is Some(message) {
        inbox.put(Arrived(message))
        if message is Close(..) {
          return
        }
      }
    }
  } catch {
    @ws.Protocol(_) => 1002
    @ws.Payload(_) => 1007
    @ws.Exceeded(..) => 1009
    e if @async.is_being_cancelled() => raise e
    _ => 1006
  }
  if code != 1006 {
    wire.frame(Close, @ws.close(code)) catch {
      _ => ()
    }
  }
  inbox.put(Failed(code))
}

///|
/// Ping every `every` milliseconds. A pong that does not come within `timeout` means the peer is
/// gone without saying so, and the connection fails with `1011`, as uvicorn's does.
async fn keep_alive(
  wire : Wire,
  inbox : @aqueue.Queue[Inbound],
  every : Int32,
  timeout : Int32?,
) -> Unit {
  for ;; {
    @async.sleep(every)
    let asked = @async.now()
    wire.frame(Ping, b"")
    guard timeout is Some(wait) else { continue }
    @async.sleep(wait)
    if wire.pong < asked {
      wire.frame(Close, @ws.close(1011)) catch {
        _ => ()
      }
      return inbox.put(Failed(1011))
    }
  }
}
