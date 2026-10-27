// The ASGI-over-HTTP/2 binding on moonhttp's connection state machine (RFC 9113): one task reads
// the connection and feeds `@http2.Conn`, and every request stream runs the application in a
// task of its own, so a slow handler holds up only its own stream. The connection is moonnet's,
// so the same code serves h2 under TLS and h2c in the clear.

///|
/// One request stream: its body as it arrives, and what both ends have done with it.
priv struct Exchange {
  id : Int32
  body : @deque.Deque[Bytes]
  // END_STREAM from the client: the body is all here.
  mut ended : Bool
  // The stream is over from outside: reset by either end, or the connection is gone.
  mut gone : Bool
  // The response is complete.
  mut done : Bool
  changed : @cond_var.Cond
}

///|
fn Exchange::new(id : Int32) -> Exchange {
  {
    id,
    body: @deque.Deque([]),
    ended: false,
    gone: false,
    done: false,
    changed: @cond_var.Cond(),
  }
}

///|
fn Exchange::cut(self : Exchange) -> Unit {
  self.gone = true
  self.changed.broadcast()
}

///|
/// One HTTP/2 connection: the socket, the state machine, and the streams being answered.
///
/// The state machine is touched only between awaits, which is what makes it safe to share
/// between the reading task and the stream tasks; the lock keeps what each one takes from it
/// in order on the wire.
priv struct H2 {
  conn : @tcp.Conn
  wire : @http2.Conn
  lock : @async.Mutex
  config : @config.Config
  link : Link
  load : Load
  exchanges : Map[Int32, Exchange]
  // Broadcast when the peer may have opened a send window: WINDOW_UPDATE, new SETTINGS, a
  // stream reset or the end of the connection.
  credit : @cond_var.Cond
  // A GOAWAY has gone one way or the other: no new streams, and the connection ends once the
  // open ones are answered.
  mut draining : Bool
  mut idle_since : Int64
}

///|
/// Write whatever the state machine has queued. A peer that has gone takes the connection with
/// it, which the reading task sees as the end of the stream.
async fn H2::flush(self : H2) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  let out = self.wire.take()
  if out.length() > 0 {
    self.conn.write(out)
  }
}

///|
/// Answer one stream: the application runs on a scope built from the request head, takes the
/// body as it arrives, and its response goes out under both flow-control windows.
///
/// `receive` follows uvicorn: once the body is delivered it waits, and says `http.disconnect`
/// when the response is complete or the client has reset the stream. An application failure
/// before the response starts is a 500; after it, the stream is reset with INTERNAL_ERROR.
async fn H2::serve(
  self : H2,
  app : @moonasgi.AsgiApp,
  ex : Exchange,
  fields : Array[@header.Header],
) -> Unit {
  let (verb, target) = request_line(fields)
  let scope = h2_build_scope(fields, self.link, self.config)
  let head = verb == "HEAD"
  let delivered = Ref(false)
  let receive : @moonasgi.Receive = () => {
    for ;; {
      if ex.gone {
        return @moonasgi.Event::HttpDisconnect
      }
      if ex.body.pop_front() is Some(part) {
        // The window comes back as the application takes the body, not as it arrives.
        self.wire.acknowledge(ex.id, part.length()) catch {
          _ => ()
        }
        self.flush() catch {
          _ => ()
        }
        let last = ex.ended && ex.body.is_empty()
        delivered.val = last
        return @moonasgi.Event::HttpRequest(body=part, more_body=!last)
      }
      if ex.ended && !delivered.val {
        delivered.val = true
        return @moonasgi.Event::HttpRequest(body=b"", more_body=false)
      }
      if delivered.val && ex.done {
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
      // A 103 (RFC 8297) is a head of its own before the answer (RFC 9113 §8.1).
      HttpResponseEarlyHint(links~) =>
        if status.val == 0 && links.length() > 0 {
          let fields = [@header.Header::of(":status", "103")]
          for link in links {
            fields.push(@header.Header::of("link", link))
          }
          self.wire.headers(ex.id, fields)
          self.flush()
        }
      HttpResponseStart(status=code, headers~, trailers=promised) =>
        if status.val == 0 {
          status.val = code
          trailing.val = promised && !head
          // A HEAD answer is the head alone (RFC 9110 §9.3.2).
          self.wire.headers(
            ex.id,
            h2_response_headers(code, headers, self.config),
            end=head,
          )
          self.flush()
          if head {
            complete()
          }
        }
      HttpResponseBody(body~, more_body~) =>
        if status.val != 0 {
          let last = !more_body && !trailing.val
          self.write(ex, body, end=last)
          if last {
            complete()
          }
        }
      // Trailers are a head after the body that ends the stream (RFC 9113 §8.1).
      HttpResponseTrailers(headers~, more_trailers~) =>
        if trailing.val {
          trailers.push_iter(headers.iter())
          if !more_trailers {
            self.wire.headers(
              ex.id,
              trailers.map(h => @header.Header::of(h.0.to_lower(), h.1)),
              end=true,
            )
            self.flush()
            complete()
          }
        }
      _ => ()
    }
  }
  let failed = Ref(false)
  app(scope, receive, send) catch {
    err => {
      self.config.logger.log(
        Error,
        "exception in ASGI application: " + err.to_string(),
      )
      failed.val = true
    }
  }
  if !ex.gone && !ex.done {
    if status.val == 0 {
      status.val = 500
      self.wire.headers(
        ex.id,
        h2_response_headers(500, [], self.config),
        end=true,
      )
    } else if failed.val {
      self.wire.reset(ex.id, code=@http2.error_internal_error)
    } else {
      self.wire.end(ex.id)
    }
    self.flush()
  }
  complete()
  self.config.logger.access_line(
    match self.link.peer {
      Some(a) => a.to_string()
      None => "-"
    },
    verb,
    target,
    "2",
    status.val,
  )
}

///|
/// Send `data` on the exchange's stream as both windows allow, waiting for the peer to open
/// them when they are shut. A stream reset meanwhile drops the rest.
async fn H2::write(self : H2, ex : Exchange, data : Bytes, end~ : Bool) -> Unit {
  if data.length() == 0 {
    if end {
      self.wire.end(ex.id)
      self.flush()
    }
    return
  }
  let mut at = 0
  while at < data.length() && !ex.gone {
    let room = self.wire.window(ex.id)
    if room > 0 {
      let n = @cmp.minimum(room, data.length() - at)
      self.wire.data(ex.id, data[at:at + n], end=end && at + n == data.length())
      at += n
      self.flush()
    } else {
      self.credit.wait()
    }
  }
}

///|
/// A new request stream: refused with 503 past the concurrency ceiling, otherwise answered in a
/// task of its own.
async fn H2::open(
  self : H2,
  g : @async.TaskGroup[Unit],
  app : @moonasgi.AsgiApp,
  id : Int32,
  fields : Array[@header.Header],
) -> Unit {
  if self.load.busy(self.config.limit_concurrency) {
    self.config.logger.log(
      Warning,
      "Exceeded concurrency limit, refusing with 503",
    )
    self.wire.headers(id, h2_response_headers(503, [], self.config), end=true)
    self.flush()
    return
  }
  let ex = Exchange::new(id)
  self.exchanges[id] = ex
  self.load.requests += 1
  g.spawn_bg(allow_failure=true, () => {
    self.serve(app, ex, fields) catch {
      _ => ()
    }
    self.load.requests -= 1
    self.exchanges.remove(id)
    self.idle_since = @async.now()
    if self.load.count(self.config) {
      self.leave()
    }
  })
}

///|
/// Stop taking new streams: GOAWAY naming the last one taken, then the open ones run out.
async fn H2::leave(self : H2) -> Unit {
  if !self.draining {
    self.draining = true
    self.wire.goaway() catch {
      _ => ()
    }
    self.flush() catch {
      _ => ()
    }
  }
}

///|
/// The reading side: take the peer's octets into the state machine and act on what comes out,
/// until the peer closes, a connection error, a GOAWAY with nothing left open, or an idle spell
/// past `timeout_keep_alive`.
///
/// Reads are bounded by the keep-alive time so the loop gets to look at the clock: a connection
/// with no stream open for that long is sent a GOAWAY and closed, as hypercorn does.
async fn H2::read(
  self : H2,
  g : @async.TaskGroup[Unit],
  app : @moonasgi.AsgiApp,
) -> Unit {
  let tick = self.config.timeout_keep_alive
  for ;; {
    if self.draining && self.exchanges.is_empty() {
      return
    }
    let event = self.wire.next() catch {
      _ => {
        // A connection error: the GOAWAY is queued.
        self.flush() catch {
          _ => ()
        }
        return
      }
    }
    match event {
      NeedData => {
        self.flush()
        match @async.with_timeout_opt(tick, () => self.conn.read_some()) {
          Some(got) => self.wire.receive(got.unwrap_or(b"")[:])
          None =>
            if self.exchanges.is_empty() &&
              @async.now() - self.idle_since >= tick.to_int64() {
              self.leave()
              return
            }
        }
      }
      Request(stream~, fields~) =>
        if !self.draining {
          self.open(g, app, stream, fields)
        }
      Data(stream~, data~) =>
        match self.exchanges.get(stream) {
          Some(ex) => {
            ex.body.push_back(data)
            ex.changed.broadcast()
          }
          // A stream answered already, the 503: give its window back.
          None => self.wire.acknowledge(stream, data.length()) catch { _ => () }
        }
      End(stream~) =>
        if self.exchanges.get(stream) is Some(ex) {
          ex.ended = true
          ex.changed.broadcast()
        }
      Reset(stream~, ..) => {
        if self.exchanges.get(stream) is Some(ex) {
          ex.cut()
        }
        self.credit.broadcast()
      }
      WindowUpdated(..) | Settings(_) => self.credit.broadcast()
      GoAway(..) => self.draining = true
      Closed => return
      _ => ()
    }
  }
}

///|
/// Drive one HTTP/2 connection to its end. The settings are `Config.h2`'s; the connection's own
/// receive window is widened to match, since the protocol starts it at 64 KiB whatever the
/// streams get.
async fn drive_h2(
  app : @moonasgi.AsgiApp,
  conn : @tcp.Conn,
  config : @config.Config,
  link : Link,
  load : Load,
) -> Unit {
  let limits = config.h2
  let wire = @http2.Conn::new(
    Server,
    settings=@http2.Settings::new(
      max_concurrent_streams=Some(limits.max_streams),
      initial_window_size=limits.window,
      max_frame_size=limits.max_frame,
      max_header_list_size=Some(limits.max_header_list),
    ),
  )
  let widen = limits.connection_window - @http2.initial.initial_window_size
  if widen > 0 {
    wire.widen(0, widen)
  }
  let h2 : H2 = {
    conn,
    wire,
    lock: @async.Mutex(),
    config,
    link,
    load,
    exchanges: Map([]),
    credit: @cond_var.Cond(),
    draining: false,
    idle_since: @async.now(),
  }
  @async.with_task_group(g => {
    defer {
      for _, ex in h2.exchanges {
        ex.cut()
      }
      h2.credit.broadcast()
    }
    h2.flush()
    h2.read(g, app)
  })
}

///|
/// The method and target of a request head, for the access log.
fn request_line(fields : Array[@header.Header]) -> (String, String) {
  let mut verb = "GET"
  let mut target = "/"
  for f in fields {
    let (name, value) = f.ascii()
    if name == ":method" {
      verb = value
    } else if name == ":path" {
      target = value
    }
  }
  (verb, target)
}

///|
/// Header names an ASGI app may set that are connection-specific under HTTP/1 and
/// forbidden (or framing-owned) under HTTP/2, so they are dropped from the response
/// header block (RFC 9113 §8.2.2). `content-length` is dropped too: the DATA +
/// END_STREAM framing delimits the body, and a streamed response has none to give.
fn h2_is_dropped_response_header(name : String) -> Bool {
  name
  is ("connection"
  | "keep-alive"
  | "transfer-encoding"
  | "upgrade"
  | "proxy-connection"
  | "content-length")
}

///|
/// Build the response header list for HPACK encoding: the `:status` pseudo-header
/// first (RFC 9113 §8.3.2), then every app header that is legal to carry over
/// HTTP/2, lower-cased as the protocol requires (§8.2.1), then the configured server
/// headers and the `date` the app did not set itself, as the HTTP/1.1 path adds them.
fn h2_response_headers(
  status : Int32,
  headers : Array[(String, String)],
  config : @config.Config,
) -> Array[@header.Header] {
  let out = [@header.Header::of(":status", status.to_string())]
  let sent : Set[String] = Set([])
  let add = (name : String, value : String) => {
    let lower = name.to_lower()
    if !h2_is_dropped_response_header(lower) {
      sent.add(lower)
      out.push(@header.Header::of(lower, value))
    }
  }
  for pair in headers {
    add(pair.0, pair.1)
  }
  for name, value in config.server_headers {
    if !sent.contains(name.to_lower()) {
      add(name, value)
    }
  }
  if config.date_header && !sent.contains("date") {
    add("date", @config.http_date_now())
  }
  out
}

///|
/// Turn a request stream's decoded head into an ASGI HTTP `Scope`. `:method` and `:path`
/// (RFC 9113 §8.3.1) give the method and target, every ordinary header is carried through, and
/// a `host` is derived from `:authority` when the request has no explicit one. The scheme is the
/// connection's, as on HTTP/1.1, rather than what the client wrote in `:scheme`; the rest is
/// `http_scope`'s, shared with HTTP/1.1. `http_version` is `"2"`.
fn h2_build_scope(
  headers : Array[@header.Header],
  link : Link,
  config : @config.Config,
) -> @moonasgi.Scope {
  let (verb, target) = request_line(headers)
  let mut authority = ""
  let mut has_host = false
  let pairs : Array[(String, String)] = []
  for h in headers {
    let (name, value) = h.ascii()
    if name == ":authority" {
      authority = value
    } else if name.length() > 0 && name[0] != ':' {
      if name == "host" {
        has_host = true
      }
      pairs.push((name, value))
    }
  }
  if authority.length() > 0 && !has_host {
    pairs.push(("host", authority))
  }
  http_scope(link, config, "2", verb, target, pairs)
}

///|
/// Whether a connection speaks HTTP/2: what ALPN settled under TLS, else whether it opens
/// with the connection preface (RFC 9113 §3.4). The sniff waits no longer than a request
/// head would; `None` is a peer that said nothing in that time.
async fn speaks_h2(conn : @tcp.Conn, config : @config.Config) -> Bool? {
  match conn.alpn() {
    Some(protocol) => Some(protocol == "h2")
    None =>
      @async.with_timeout_opt(config.timeout_keep_alive, () => {
        conn.starts_with(@http2.preface[:])
      })
  }
}

///|
/// Serve a moonasgi ASGI application over **HTTP/2 cleartext (h2c)** only — the
/// prior-knowledge, no-TLS HTTP/2 profile (RFC 9113 §3.3). Convenience wrapper over
/// `serve_h2c_config` that builds a `Config` from `host` / `port`. Blocks in the
/// accept loop until the running task is cancelled.
///
/// `serve` and `serve_tls` speak HTTP/2 as well, beside HTTP/1.1 on the same port;
/// this entry point is for a listener that is to speak nothing else.
pub async fn serve_h2c(
  app : @moonasgi.AsgiApp,
  host~ : String = "127.0.0.1",
  port~ : Int32 = @config.port,
) -> Unit {
  serve_h2c_config(app, @config.Config::new(host~, port~))
}

///|
/// Serve a moonasgi ASGI application over h2c under an explicit `Config`: the same serving
/// loop as `serve_config`, with its lifespan, limits, logging and graceful shutdown, on a
/// listener that speaks HTTP/2 alone.
pub async fn serve_h2c_config(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
) -> Unit {
  run(app, config, ShutdownHandle::new(), None, H2)
}
