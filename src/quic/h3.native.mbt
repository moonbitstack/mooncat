// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The ASGI-over-HTTP/3 binding (RFC 9114), built the way the HTTP/2 one is: every request stream
// runs the application in a task of its own, the body is taken as the application asks for it, so
// a stream's credit comes back at that pace, and `receive` says `http.disconnect` when the
// response is complete or the client has walked away.
//
// What the protocol allows on a stream is `moonhttp`'s to judge; this file only says what to do
// when it says no. An HTTP/3 fault is always the connection's, never a stream's (§4.1.2, §7.2):
// the two ends no longer agree about what the streams mean, so the connection is closed with the
// code the refusal carries and every exchange on it stops.

///|
/// The largest field section this server will take (SETTINGS_MAX_FIELD_SECTION_SIZE, RFC 9114
/// §7.2.4.1). A frame bigger than this is refused as its header arrives rather than buffered.
let max_field_section_size : UInt64 = 16384UL

///|
/// The QPACK dynamic table this server offers, which is none: it sends headers from the static
/// table and asks peers to do the same, so an encoder stream may set no capacity at all.
let qpack_table_capacity : UInt64 = 0UL

///|
/// How much of one response is held unacknowledged before `send` waits, which is what paces a fast
/// application against a slow client. 64 KiB, HTTP/2's initial stream window.
let high_water : UInt64 = 65536UL

///|
/// How much of a body goes in one DATA frame.
let frame_size : Int32 = 16384

///|
/// A request stream.
priv struct Exchange {
  id : UInt64
  // Whether the stream was already readable before the handshake finished, which only 0-RTT data
  // can be: the request may then be a replay (RFC 8470).
  early : Bool
  incoming : @http3.Incoming
  mut parts : Array[@http3.Part]
  mut gone : Bool
  mut done : Bool
  // Taken with `admit`, so to be given back with `finished`.
  mut admitted : Bool
  changed : @cond_var.Cond
}

///|
fn Exchange::new(id : UInt64, early~ : Bool) -> Exchange {
  {
    id,
    early,
    incoming: @http3.Incoming::new(
      limit=max_field_section_size,
      chunk=frame_size,
    ),
    parts: [],
    gone: false,
    done: false,
    admitted: false,
    changed: @cond_var.Cond(),
  }
}

///|
fn Exchange::cut(self : Exchange) -> Unit {
  self.gone = true
  self.changed.broadcast()
}

///|
/// What comes next on a request stream.
priv enum Piece {
  Head(Array[@header.Header])
  Body(Bytes)
  End
}

///|
/// A peer's unidirectional stream, once its type has arrived (RFC 9114 §6.2, RFC 9204 §4.2).
priv enum Uni {
  /// The type varint has not fully arrived.
  Opening(Bytes)
  Control(@http3.Control)
  Encoder(@http3.Encoder)
  Decoder(@http3.Decoder)
  /// A push or reserved stream: nothing in it is for this server.
  Ignored
}

///|
/// One client connection.
priv struct Client {
  session : @conn.Session[@socket.Addr]
  wire : @http3.Conn
  exchanges : Map[UInt64, Exchange]
  uni : Map[UInt64, Uni]
  mut control : UInt64?
  mut next_request : UInt64
  mut leaving : Bool
  // Whether the handshake has finished. A request stream the transport reports before it can only
  // have arrived in 0-RTT: 1-RTT streams need the keys the handshake makes.
  mut connected : Bool
}

///|
/// The HTTP/3 listener.
priv struct H3 {
  ep : Endpoint
  server : @conn.Endpoint[@socket.Addr]
  site : @serve.Site
  app : @moonasgi.AsgiApp
  clients : Map[Bytes, Client]
  // Broadcast after every datagram: an ACK may have made room for a paced response.
  credit : @cond_var.Cond
}

///|
async fn H3::pump(self : H3) -> Unit {
  quic_pump(self.ep, self.server)
}

///|
/// End the connection with an HTTP/3 error, and everything on it.
async fn H3::abort(self : H3, client : Client, code : @http3.Code) -> Unit {
  client.session.close(code.code(), b"", now(), application=true)
  for _, ex in client.exchanges {
    ex.cut()
  }
  self.clients.remove(client.session.cid())
  self.pump()
}

///|
fn join(a : Bytes, b : BytesView) -> Bytes {
  let out = Buffer()
  out.write_bytes(a)
  out.write_bytesview(b)
  out.to_bytes()
}

///|
/// What arrives next on `ex`: the request's head, the next piece of its body, or the end. A window
/// into the stream is taken as it comes rather than whole, so a large body stays out of memory,
/// and what the protocol does not allow on a request stream — DATA before HEADERS, a frame a
/// control stream owns, a malformed field section — is refused by the reader.
async fn H3::next(self : H3, client : Client, ex : Exchange) -> Piece {
  for ;; {
    if ex.gone {
      return End
    }
    if ex.parts.length() > 0 {
      let part = ex.parts[0]
      ex.parts.remove(0) |> ignore
      match part {
        @http3.Part::Head(fields) => return Head(fields)
        @http3.Part::Data(body) => return Body(body)
        // Trailing fields carry nothing this binding hands the application.
        @http3.Part::Trailers(_) => continue
      }
    }
    let got = client.session.read(ex.id)
    if got.length() > 0 {
      ex.parts = ex.incoming.feed(got)
      self.pump()
      continue
    }
    if client.session.finished(ex.id) {
      ex.incoming.end()
      return End
    }
    ex.changed.wait()
  }
}

///|
/// Queue `data` on the stream and wait until the client has taken enough of what is outstanding.
async fn H3::write(
  self : H3,
  client : Client,
  ex : Exchange,
  data : Bytes,
  fin~ : Bool = false,
) -> Unit {
  client.session.write(ex.id, data, fin~)
  self.pump()
  while client.session.buffered(ex.id) > high_water && !ex.gone {
    self.credit.wait()
  }
}

///|
async fn H3::write_head(
  self : H3,
  client : Client,
  ex : Exchange,
  fields : Array[@header.Header],
  fin~ : Bool = false,
) -> Unit {
  self.write(
    client,
    ex,
    @http3.Frame::encode(Headers(@qpack.encode(fields))),
    fin~,
  )
}

///|
/// Answer one request stream.
async fn H3::answer(self : H3, client : Client, ex : Exchange) -> Unit {
  // A fault the application's `receive` ran into cannot be raised through it: the ASGI signature
  // has no error type, so it is kept here and raised once the application has returned.
  let fault : Ref[@http3.Code?] = Ref(None)
  let section = match self.next(client, ex) {
    Head(section) => section
    _ => return
  }
  let (verb, target) = @serve.request_of(section)
  let config = self.site.config()
  // RFC 8470 §4: an origin that took early data may answer `425 Too Early` instead of running the
  // application, and the client sends the request again once the handshake is done. This is how an
  // application that cannot be replayed is kept from being replayed.
  if ex.early && config.early_data is Refuse {
    self.write_head(client, ex, self.site.head(425, []), fin=true)
    ex.done = true
    ex.changed.broadcast()
    self.pump()
    config.logger.access_line(
      client.session.peer().to_string(),
      verb,
      target,
      "3",
      425,
    )
    return
  }
  guard self.site.admit() else {
    self.write_head(client, ex, self.site.head(503, []), fin=true)
    return
  }
  ex.admitted = true
  let scope = self.site.scope(
    section,
    version="3",
    peer=client.session.peer(),
    suite=client.session.suite_code(),
    early=ex.early,
  )
  let head = verb == "HEAD"
  let delivered = Ref(false)
  let receive : @moonasgi.Receive = () => {
    for ;; {
      if ex.gone {
        return @moonasgi.Event::HttpDisconnect
      }
      if !delivered.val {
        let piece = Ok(self.next(client, ex)) catch {
          @http3.Refused::Fault(code~, ..) => Err(code)
          @http3.Refused::Malformed(_) => Err(@http3.GeneralProtocolError)
          _ => Err(@http3.InternalError)
        }
        match piece {
          Ok(Body(part)) =>
            return @moonasgi.Event::HttpRequest(body=part, more_body=true)
          Ok(Head(_)) => continue
          Ok(End) => {
            guard !ex.gone else { return @moonasgi.Event::HttpDisconnect }
            delivered.val = true
            return @moonasgi.Event::HttpRequest(body=b"", more_body=false)
          }
          Err(code) => {
            fault.val = Some(code)
            return @moonasgi.Event::HttpDisconnect
          }
        }
      }
      if ex.done {
        return @moonasgi.Event::HttpDisconnect
      }
      ex.changed.wait()
    }
  }
  let status = Ref(0)
  let trailing = Ref(false)
  let trailers : Array[(String, String)] = []
  let complete = () => {
    ex.done = true
    ex.changed.broadcast()
  }
  let send : @moonasgi.Send = event => {
    guard !ex.gone && !ex.done else { return }
    match event {
      HttpResponseEarlyHint(links~) =>
        if status.val == 0 && links.length() > 0 {
          let hint = [@header.Header::of(":status", "103")]
          for link in links {
            hint.push(@header.Header::of("link", link))
          }
          self.write_head(client, ex, hint)
        }
      HttpResponseStart(status=code, headers~, trailers=promised) =>
        if status.val == 0 {
          status.val = code
          trailing.val = promised && !head
          self.write_head(client, ex, self.site.head(code, headers), fin=head)
          if head {
            complete()
          }
        }
      HttpResponseBody(body~, more_body~) =>
        if status.val != 0 {
          let last = !more_body && !trailing.val
          let mut at = 0
          while at < body.length() && !ex.gone {
            let end = @cmp.minimum(at + frame_size, body.length())
            self.write(
              client,
              ex,
              @http3.Frame::encode(Data(body[at:end].to_owned())),
              fin=last && end == body.length(),
            )
            at = end
          }
          if last {
            if body.length() == 0 {
              self.write(client, ex, b"", fin=true)
            }
            complete()
          }
        }
      HttpResponseTrailers(headers~, more_trailers~) =>
        if trailing.val {
          trailers.push_iter(headers.iter())
          if !more_trailers {
            self.write_head(
              client,
              ex,
              trailers.map(h => @header.Header::of(h.0.to_lower(), h.1)),
              fin=true,
            )
            complete()
          }
        }
      _ => ()
    }
  }
  let failed = Ref(false)
  (self.app)(scope, receive, send) catch {
    err => {
      config.logger.log(
        @moonlog.error,
        "exception in ASGI application: " + err.to_string(),
      )
      failed.val = true
    }
  }
  match fault.val {
    Some(code) =>
      raise @http3.Fault(code~, detail="the request stream was refused")
    None => ()
  }
  if !ex.gone && !ex.done {
    if status.val == 0 {
      status.val = 500
      self.write_head(client, ex, self.site.head(500, []), fin=true)
    } else if failed.val {
      client.session.reset(ex.id, @http3.InternalError.code())
    } else {
      self.write(client, ex, b"", fin=true)
    }
  }
  complete()
  // RFC 9114 §4.1: a server done before the request ended tells the client it may stop.
  if !client.session.finished(ex.id) && !ex.gone {
    client.session.stop(ex.id, @http3.NoError.code())
  }
  self.pump()
  config.logger.access_line(
    client.session.peer().to_string(),
    verb,
    target,
    "3",
    status.val,
  )
}

///|
/// Classify a unidirectional stream from the bytes read so far, and hand what follows its type to
/// the reader for that kind.
fn classify(client : Client, bytes : Bytes) -> Uni raise @http3.Refused {
  let (kind, at) = match @http3.Stream::decode(bytes[:]) {
    Some(v) => v
    // The type is a varint of up to eight octets and may be split across packets.
    None => return Opening(bytes)
  }
  client.wire.open_stream(kind)
  let rest = bytes[at:].to_owned()
  match kind {
    ControlKind => {
      let reader = @http3.Control::new(limit=max_field_section_size)
      if reader.feed(rest) is Some(settings) {
        client.wire.accept_settings(settings)
      }
      Control(reader)
    }
    EncoderKind => {
      let reader = @http3.Encoder::new(limit=qpack_table_capacity.to_int())
      reader.feed(rest)
      Encoder(reader)
    }
    DecoderKind => {
      let reader = @http3.Decoder::new()
      reader.feed(rest)
      Decoder(reader)
    }
    PushKind(_) | ReservedKind(_) => Ignored
  }
}

///|
/// Take what a peer's unidirectional stream has to say: the control stream sets the connection up,
/// the QPACK streams keep their two ends agreed about the table, and a push or reserved stream is
/// read past (RFC 9114 §6.2). A stream the connection needs ending is H3_CLOSED_CRITICAL_STREAM,
/// which is how a peer says it will not go on.
async fn H3::read_uni(
  self : H3,
  client : Client,
  id : UInt64,
) -> Unit raise @http3.Refused {
  let got = client.session.read(id)
  self.pump() catch {
    _ => ()
  }
  let known = client.uni.get(id)
  let bytes = match known {
    Some(Opening(held)) => join(held, got[:])
    _ => got
  }
  match known {
    None | Some(Opening(_)) => client.uni[id] = classify(client, bytes)
    Some(Control(reader)) =>
      if reader.feed(got) is Some(settings) {
        client.wire.accept_settings(settings)
      }
    Some(Encoder(reader)) => reader.feed(got)
    Some(Decoder(reader)) => reader.feed(got)
    Some(Ignored) => ()
  }
  if client.session.finished(id) {
    match client.uni.get(id) {
      Some(Control(reader)) => reader.end()
      Some(Encoder(reader)) => reader.end()
      Some(Decoder(reader)) => reader.end()
      Some(Opening(_)) =>
        raise @http3.Fault(
          code=@http3.FrameError,
          detail="a unidirectional stream ending inside its type",
        )
      Some(Ignored) | None => ()
    }
    client.uni.remove(id)
  }
}

///|
/// Read a peer's unidirectional stream and act on it, closing the connection when it says
/// something HTTP/3 does not allow.
async fn H3::on_uni(self : H3, client : Client, id : UInt64) -> Unit {
  let outcome = Ok(self.read_uni(client, id)) catch {
    @http3.Refused::Fault(code~, ..) => Err(code)
    @http3.Refused::Malformed(_) => Err(@http3.GeneralProtocolError)
  }
  match outcome {
    Ok(_) => ()
    Err(code) => self.abort(client, code) catch { _ => () }
  }
}

///|
/// Start answering a request stream the client just opened, unless the server is on its way out.
fn H3::open(
  self : H3,
  g : @async.TaskGroup[Unit],
  client : Client,
  id : UInt64,
) -> Unit {
  if client.leaving {
    client.session.stop(id, @http3.RequestRejected.code())
    client.session.reset(id, @http3.RequestRejected.code())
    return
  }
  let ex = Exchange::new(id, early=!client.connected)
  client.exchanges[id] = ex
  if id >= client.next_request {
    client.next_request = id + 4UL
  }
  g.spawn_bg(allow_failure=true, () => {
    // A request stream that says something HTTP/3 does not allow ends the connection, not the
    // stream: §4.1.2 and §7.2 make each of those faults the connection's.
    let refused = Ok(self.answer(client, ex)) catch {
      @http3.Refused::Fault(code~, ..) => Err(code)
      @http3.Refused::Malformed(_) => Err(@http3.GeneralProtocolError)
      _ => Err(@http3.InternalError)
    }
    match refused {
      Ok(_) => ()
      Err(code) => self.abort(client, code) catch { _ => () }
    }
    client.session.release(id)
    client.exchanges.remove(id)
    if ex.admitted {
      self.site.finished() catch {
        _ => ()
      }
    }
    self.pump() catch {
      _ => ()
    }
  })
}

///|
/// Act on what the transport has to say about every connection with news.
async fn H3::dispatch(self : H3, g : @async.TaskGroup[Unit]) -> Unit {
  for session in self.server.take_busy() {
    let client = match self.clients.get(session.cid()) {
      Some(c) => c
      None => {
        let c : Client = {
          session,
          wire: @http3.Conn::new(
            Server,
            @http3.Settings::new(
              qpack_table_capacity, max_field_section_size, 0UL,
            ),
          ),
          exchanges: Map([]),
          uni: Map([]),
          control: None,
          next_request: 0UL,
          leaving: false,
          connected: false,
        }
        self.clients[session.cid()] = c
        c
      }
    }
    for event in session.take_events() {
      match event {
        Connected => {
          client.connected = true
          let id = session.open_uni()
          client.control = Some(id)
          session.write(id, client.wire.open_control_stream())
        }
        Readable(id) if (id & 2UL) != 0UL => self.on_uni(client, id)
        Readable(id) =>
          match client.exchanges.get(id) {
            Some(ex) => ex.changed.broadcast()
            // The transport says nothing of a stream once released, so this one is new, whatever
            // its number: under loss a later stream can arrive first.
            None => self.open(g, client, id)
          }
        Reset(id, _) =>
          if client.exchanges.get(id) is Some(ex) {
            ex.cut()
          } else {
            self.on_uni_reset(client, id)
          }
        Stopped(id, _) =>
          if client.exchanges.get(id) is Some(ex) {
            ex.cut()
            session.reset(id, @http3.RequestCancelled.code())
          }
        Closed(_) => {
          for _, ex in client.exchanges {
            ex.cut()
          }
          self.clients.remove(session.cid())
        }
        // No HTTP datagrams here (RFC 9297), and this server does not offer them.
        Datagram => ()
      }
    }
  }
  self.credit.broadcast()
}

///|
/// A peer abandoned a unidirectional stream. Closing one the connection needs is the same fault
/// as ending it (§6.2.1, RFC 9204 §4.2).
async fn H3::on_uni_reset(self : H3, client : Client, id : UInt64) -> Unit {
  guard client.uni.get(id) is Some(stream) else { return }
  client.uni.remove(id)
  let fault = match stream {
    Control(_) | Decoder(_) => Some(@http3.ClosedCriticalStream)
    Encoder(_) => Some(@http3.ClosedCriticalStream)
    Opening(_) | Ignored => None
  }
  if fault is Some(code) {
    self.abort(client, code) catch {
      _ => ()
    }
  }
}

///|
/// Tell every client no new requests are coming (RFC 9114 §5.2). The streams already taken run out
/// under the server's `graceful_timeout`.
fn H3::leave(self : H3) -> Unit {
  for _, client in self.clients {
    guard !client.leaving else { continue }
    client.leaving = true
    if client.control is Some(id) {
      client.session.write(
        id,
        @http3.Frame::encode(GoAway(client.next_request)),
      )
    }
  }
}

///|
/// Serve HTTP/3 beside the server's TCP listener, on UDP at the same address, until cancelled.
/// `tls` offers `h3`.
pub async fn serve_site(
  app : @moonasgi.AsgiApp,
  site : @serve.Site,
  tls : @tls.Server,
  transport~ : @conn.Config = @conn.Config::default(),
  tick_ms~ : Int32 = 20,
) -> Unit {
  let cid = match @serve.worker() {
    Some(index) => Some(issued_by(index, entropy))
    None => None
  }
  let h3 : H3 = {
    ep: worker_endpoint(site.bound()),
    server: @conn.Endpoint::server(transport, tls, rand=entropy, cid?),
    site,
    app,
    clients: Map([]),
    credit: @cond_var.Cond(),
  }
  @async.with_task_group(g => {
    defer {
      for _, client in h3.clients {
        client.session.close(
          @http3.NoError.code(),
          b"",
          now(),
          application=true,
        )
      }
      @async.protect_from_cancel(() => h3.pump()) catch {
        _ => ()
      }
    }
    let _ : @async.Task[Unit] = g.spawn(() => {
      for ;; {
        let (datagram, from) = h3.ep.recv_datagram()
        h3.server.recv(datagram, from, now(), wall=wall()) catch {
          _ => ()
        }
        h3.dispatch(g)
        h3.pump() catch {
          _ => ()
        }
      }
    })
    for ;; {
      @async.sleep(tick_ms)
      h3.server.tick(now())
      if site.stopping() {
        h3.leave()
      }
      h3.dispatch(g)
      h3.pump() catch {
        _ => ()
      }
    }
  })
}

///|
fn entropy(n : Int32) -> Bytes {
  guard @env.rand(n) is Some(bytes) else { abort("no system entropy") }
  bytes
}

///|
/// Serve HTTP/1.1, HTTP/2 and HTTP/3 together under one certificate, TCP and UDP on the same port:
/// the TCP side tells clients about HTTP/3 with `alt-svc` (RFC 7838).
///
/// With `workers` above 1 the TCP port is shared by the kernel, as for `serve_tls`, and the UDP port
/// by this process: it holds the socket and passes each datagram to the worker whose number is in
/// the connection id (see `route.mbt`).
///
/// Session resumption is on over TCP and UDP alike, each worker with keys of its own, so a ticket
/// resumes only on the worker that sealed it. `tickets` chooses the keys: pass the same ones to share
/// tickets across workers, or `@tls.tickets` to turn it off.
///
/// `Config.early_data` decides what a request sent in 0-RTT gets: taken and marked with
/// `Early-Data: 1`, answered `425 Too Early` without running the application, or not offered at
/// all (RFC 8470). `Config.early_data_size` is the allowance one ticket carries. Over TCP there is
/// no early data whatever it says: a byte stream cannot hold a request back until the handshake
/// says whether to take it, so only the QUIC listener offers any.
pub async fn serve_config(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  cert : @serve.TlsCert,
  suites? : Array[@record.Suite],
  suites12? : Array[@record.Suite12],
  tickets? : @tls.Tickets,
  transport? : @conn.Config,
  listening? : @serve.Listening,
) -> Unit {
  if config.workers > 1 && @serve.worker() is None {
    return supervise_with_relay(config)
  }
  let tcp = cert.load(suites?, suites12?, tickets?)
  let early = if config.early_data is Off { 0 } else { config.early_data_size }
  let udp = cert.load(alpn=["h3"], suites?, tickets?, early~)
  @serve.serve_tls_beside(
    app,
    config,
    tcp,
    site => {
      serve_site(
        app,
        site,
        udp,
        transport=transport.unwrap_or(@conn.Config::default()),
      )
    },
    alt_svc="h3=\":{port}\"; ma=86400",
    listening?,
  )
}
