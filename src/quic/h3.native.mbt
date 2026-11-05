// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The ASGI-over-HTTP/3 binding (RFC 9114), built the way the HTTP/2 one is: every request stream
// runs the application in a task of its own, the body is taken as the application asks for it, so
// a stream's credit comes back at that pace, and `receive` says `http.disconnect` when the
// response is complete or the client has walked away.

///|
/// RFC 9114 §8.1 error codes.
const H3_NO_ERROR : UInt64 = 0x100UL

///|
const H3_INTERNAL_ERROR : UInt64 = 0x102UL

///|
const H3_FRAME_UNEXPECTED : UInt64 = 0x105UL

///|
const H3_REQUEST_REJECTED : UInt64 = 0x10bUL

///|
const H3_REQUEST_CANCELLED : UInt64 = 0x10cUL

///|
const H3_MESSAGE_ERROR : UInt64 = 0x10eUL

///|
/// QPACK_DECOMPRESSION_FAILED, RFC 9204 §6.
const QPACK_DECOMPRESSION_FAILED : UInt64 = 0x200UL

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
  mut held : Bytes
  mut data_left : UInt64
  mut gone : Bool
  mut done : Bool
  // Taken with `admit`, so to be given back with `finished`.
  mut admitted : Bool
  changed : @cond_var.Cond
}

///|
fn Exchange::new(id : UInt64) -> Exchange {
  {
    id,
    held: b"",
    data_left: 0UL,
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
/// One client connection.
priv struct Client {
  session : @conn.Session[@socket.Addr]
  wire : @http3.Conn
  exchanges : Map[UInt64, Exchange]
  uni : Map[UInt64, Bytes]
  mut control : UInt64?
  mut next_request : UInt64
  mut leaving : Bool
}

///|
/// What comes next on a request stream.
priv enum Piece {
  Head(Bytes)
  Body(Bytes)
  End
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
async fn H3::abort(self : H3, client : Client, code : UInt64) -> Unit {
  client.session.close(code, b"", now(), application=true)
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
/// What arrives next on `ex`: a whole HEADERS field section, whatever part of a DATA frame's
/// payload is here, or the end. DATA is handed over as it comes rather than as whole frames, so a
/// large body stays out of memory. Unknown frame types are skipped (RFC 9114 §9); one that does not
/// belong on a request stream ends the connection (§7.2).
async fn H3::next(self : H3, client : Client, ex : Exchange) -> Piece {
  for ;; {
    if ex.gone {
      return End
    }
    if ex.data_left > 0UL && ex.held.length() > 0 {
      let have = ex.held.length().to_uint64()
      let take = if have < ex.data_left { have } else { ex.data_left }
      let part = ex.held[0:take.to_int()].to_owned()
      ex.held = ex.held[take.to_int():].to_owned()
      ex.data_left = ex.data_left - take
      return Body(part)
    }
    if ex.data_left == 0UL && ex.held.length() > 0 {
      if @quic.decode(ex.held[:]) is Some((kind, at)) {
        if kind == 0UL {
          if @quic.decode(ex.held[at:]) is Some((size, more)) {
            ex.data_left = size
            ex.held = ex.held[at + more:].to_owned()
            continue
          }
        } else {
          match @http3.decode(ex.held[:]) {
            Some((frame, used)) => {
              ex.held = ex.held[used:].to_owned()
              if frame is Headers(section) {
                return Head(section)
              }
              @http3.check(frame, Request)
              continue
            }
            None => ()
          }
        }
      }
    }
    let got = client.session.read(ex.id)
    if got.length() > 0 {
      ex.held = join(ex.held, got[:])
      self.pump()
      continue
    }
    if client.session.finished(ex.id) {
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
/// Whether a request head carries what RFC 9114 §4.3.1 requires, and its pseudo-fields come first.
fn well_formed(fields : Array[@header.Header]) -> Bool {
  let mut verb = false
  let mut path = false
  let mut scheme = false
  let mut regular = false
  for field in fields {
    let (name, _) = field.ascii()
    if name.has_prefix(":") {
      if regular {
        return false
      }
      match name {
        ":method" => verb = true
        ":path" => path = true
        ":scheme" => scheme = true
        ":authority" => ()
        _ => return false
      }
    } else {
      regular = true
    }
  }
  verb && path && scheme
}

///|
/// Answer one request stream.
async fn H3::answer(self : H3, client : Client, ex : Exchange) -> Unit {
  let section = match self.next(client, ex) {
    Head(section) => section
    _ => return
  }
  let fields = @qpack.decode(section) catch {
    _ => return self.abort(client, QPACK_DECOMPRESSION_FAILED)
  }
  guard well_formed(fields) else {
    client.session.stop(ex.id, H3_MESSAGE_ERROR)
    client.session.reset(ex.id, H3_MESSAGE_ERROR)
    return self.pump()
  }
  guard self.site.admit() else {
    self.write_head(client, ex, self.site.head(503, []), fin=true)
    return
  }
  ex.admitted = true
  let (verb, target) = @serve.request_of(fields)
  let config = self.site.config()
  let scope = self.site.scope(
    fields,
    version="3",
    peer=client.session.peer(),
    suite=client.session.suite_code(),
  )
  let head = verb == "HEAD"
  let delivered = Ref(false)
  let receive : @moonasgi.Receive = () => {
    for ;; {
      if ex.gone {
        return @moonasgi.Event::HttpDisconnect
      }
      if !delivered.val {
        match self.next(client, ex) {
          Body(part) =>
            return @moonasgi.Event::HttpRequest(body=part, more_body=true)
          Head(_) => continue
          End => {
            guard !ex.gone else { return @moonasgi.Event::HttpDisconnect }
            delivered.val = true
            return @moonasgi.Event::HttpRequest(body=b"", more_body=false)
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
  if !ex.gone && !ex.done {
    if status.val == 0 {
      status.val = 500
      self.write_head(client, ex, self.site.head(500, []), fin=true)
    } else if failed.val {
      client.session.reset(ex.id, H3_INTERNAL_ERROR)
    } else {
      self.write(client, ex, b"", fin=true)
    }
  }
  complete()
  // RFC 9114 §4.1: a server done before the request ended tells the client it may stop.
  if !client.session.finished(ex.id) && !ex.gone {
    client.session.stop(ex.id, H3_NO_ERROR)
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
/// A client's unidirectional stream: the control stream sets the connection up, QPACK's two say
/// nothing this server listens to, since it declares no dynamic table, and the rest are read past
/// (RFC 9114 §6.2).
async fn H3::on_uni(self : H3, client : Client, id : UInt64) -> Unit {
  let got = client.session.read(id)
  self.pump()
  let held = match client.uni.get(id) {
    Some(before) => join(before, got[:])
    None => got
  }
  guard !client.wire.settings_established() ||
    !(@quic.decode(held[:]) is Some((0UL, _))) else {
    return
  }
  match @quic.decode(held[:]) {
    Some((0UL, _)) =>
      // A control stream's SETTINGS may be split across packets: an error here is as likely to
      // mean more is coming.
      try client.wire.accept_uni_stream(held) catch {
        _ => client.uni[id] = held
      } noraise {
        _ => client.uni.remove(id)
      }
    _ => client.uni[id] = b""
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
    client.session.stop(id, H3_REQUEST_REJECTED)
    client.session.reset(id, H3_REQUEST_REJECTED)
    return
  }
  let ex = Exchange::new(id)
  client.exchanges[id] = ex
  if id >= client.next_request {
    client.next_request = id + 4UL
  }
  g.spawn_bg(allow_failure=true, () => {
    self.answer(client, ex) catch {
      @http3.Refused::Malformed(_) =>
        self.abort(client, H3_FRAME_UNEXPECTED) catch {
          _ => ()
        }
      _ => ()
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
          wire: @http3.Conn::new(Server, {
            qpack_max_table_capacity: 0UL,
            max_field_section_size: @http3.max_field_section,
            qpack_blocked_streams: 0UL,
          }),
          exchanges: Map([]),
          uni: Map([]),
          control: None,
          next_request: 0UL,
          leaving: false,
        }
        self.clients[session.cid()] = c
        c
      }
    }
    for event in session.take_events() {
      match event {
        Connected => {
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
        Reset(id, _) => if client.exchanges.get(id) is Some(ex) { ex.cut() }
        Stopped(id, _) =>
          if client.exchanges.get(id) is Some(ex) {
            ex.cut()
            session.reset(id, H3_REQUEST_CANCELLED)
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
        client.session.close(H3_NO_ERROR, b"", now(), application=true)
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
/// `tickets` turns session resumption on, over TCP and UDP alike. All the workers need the same
/// keys. 0-RTT stays off whatever it says, since nothing here can answer 425 (RFC 8470).
pub async fn serve_config(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  cert : @serve.TlsCert,
  suites? : Array[@record.Suite],
  suites12? : Array[@record.Suite12],
  tickets? : @tls.Tickets,
) -> Unit {
  if config.workers > 1 && @serve.worker() is None {
    return supervise_with_relay(config)
  }
  let headers = config.server_headers.copy()
  headers["alt-svc"] = "h3=\":\{config.port}\"; ma=86400"
  let tcp = cert.load(suites?, suites12?, tickets?)
  let udp = cert.load(alpn=["h3"], suites?, tickets?)
  @serve.serve_tls_beside(app, { ..config, server_headers: headers, }, tcp, site => {
    serve_site(app, site, udp)
  })
}
