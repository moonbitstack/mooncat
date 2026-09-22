///|
/// What a connection has read but not yet consumed.
///
/// A head is read with `read_some`, which hands back whatever has arrived — and a
/// client that pipelines puts the body, or the next request, in the same segment.
/// Those octets belong to what comes next, so they are held here rather than
/// dropped, and every later read on the connection draws from them first. Losing
/// them is how a keep-alive connection drops a request.
priv struct Inbox {
  reader : &@io.Reader
  mut held : Bytes
}

///|
fn Inbox::new(reader : &@io.Reader) -> Inbox {
  { reader, held: b"", }
}

///|
/// Read more onto what is held. `false` when the peer has closed.
async fn Inbox::fill(self : Inbox) -> Bool {
  match self.reader.read_some() {
    Some(more) => {
      let buf = Buffer()
      buf.write_bytes(self.held)
      buf.write_bytes(more)
      self.held = buf.to_bytes()
      true
    }
    None => false
  }
}

///|
/// Drop the first `n` held octets, which a parse has consumed.
fn Inbox::consume(self : Inbox, n : Int) -> Unit {
  self.held = self.held[n:].to_owned()
}

///|
/// The next request head, or `None` when the peer went away or sent something
/// that is not one.
///
/// The parse is moonhttp's: this only feeds it until it stops saying `Partial`. A
/// head that fails any check — including the request-smuggling ones — ends the
/// connection, which is what uvicorn does with a malformed request too.
async fn Inbox::head(self : Inbox, limits : @http1.Limits) -> @http1.Request? {
  for ;; {
    let outcome : Result[(@http1.Request, Int), @http1.Refused] = Ok(
      @http1.request(self.held[:], limits~),
    ) catch {
      e => Err(e)
    }
    match outcome {
      Ok((req, used)) => {
        self.consume(used)
        return Some(req)
      }
      Err(Partial) => if !self.fill() { return None }
      Err(_) => return None
    }
  }
}

///|
/// Exactly `n` octets of body, from what is held and then from the connection.
async fn Inbox::exactly(self : Inbox, n : Int) -> Bytes {
  while self.held.length() < n {
    if !self.fill() {
      break
    }
  }
  let take = if self.held.length() < n { self.held.length() } else { n }
  let out = self.held[0:take].to_owned()
  self.consume(take)
  out
}

///|
/// A chunked body, decoded, with any trailer fields read and dropped.
async fn Inbox::chunks(self : Inbox) -> Bytes {
  let body = Buffer()
  for ;; {
    let outcome : Result[@http1.Chunk, @http1.Refused] = Ok(
      @http1.chunked(self.held[:]),
    ) catch {
      e => Err(e)
    }
    match outcome {
      Ok(Piece(part, used)) => {
        body.write_bytes(part)
        self.consume(used)
      }
      Ok(Done(_, used)) => {
        self.consume(used)
        break
      }
      Err(Partial) => if !self.fill() { break }
      Err(_) => break
    }
  }
  body.to_bytes()
}

///|
/// Read the next request head off a connection that is between requests, giving up after
/// `Config::timeout_keep_alive` (← uvicorn's `--timeout-keep-alive`). `None` means the peer went
/// quiet or went away — either way the connection is finished, and holding it open costs a socket
/// and a task for as long as the peer cares to say nothing.
async fn next_head(inbox : Inbox, config : Config) -> @http1.Request? {
  match
    @async.with_timeout_opt(config.timeout_keep_alive, () => {
      inbox.head(@http1.Limits::new(head=config.max_head_size))
    }) {
    Some(req) => req
    None => None
  }
}

///|
/// The fields as a map, for the helpers that look one up by name.
///
/// A repeated field keeps its last value, which is what those lookups always did.
/// The ASGI scope is built from [`fields_pairs`] instead, which keeps every one.
fn fields_map(fields : Array[@header.Header]) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  for f in fields {
    let (k, v) = f.ascii()
    out[k] = v
  }
  out
}

///|
/// The fields as ASGI's header pairs, in order and with repeats kept.
///
/// ASGI's `headers` is a list precisely so that two `Cookie` or two `Forwarded`
/// lines survive; building it from a map would collapse them.
fn fields_pairs(fields : Array[@header.Header]) -> Array[(String, String)] {
  fields.map(f => f.ascii())
}

///|
/// One chunk of a streamed response. A zero-length body is skipped so it is never
/// mistaken for the terminating chunk.
async fn write_chunk(writer : &@io.Writer, body : Bytes) -> Unit {
  if body.length() == 0 {
    return
  }
  writer.write(@http1.chunk(body[:]))
}

///|
/// Drive a moonasgi application over a single already-established HTTP/1.1
/// transport (`reader`/`writer` are the same `@tls.Tls` stream on the TLS path).
/// Builds the `Http` `Scope`, a `Receive` that streams the `Content-Length`
/// request body, and a `Send` that serialises the response:
///
/// * a single-shot response (`http.response.body` with `more_body=false` first)
///   is framed with `Content-Length`;
/// * a streamed response (`more_body=true`) switches to `Transfer-Encoding:
///   chunked`, one chunk per body event, terminated by the final `0\r\n\r\n`.
///
/// Framing headers the app supplies (`content-length` / `transfer-encoding`) are
/// dropped in favour of the ones this codec computes. Returns whether the
/// connection should be kept alive for a further request.
async fn dispatch_http1(
  app : @moonasgi.AsgiApp,
  req : @http1.Request,
  inbox : Inbox,
  writer : &@io.Writer,
  scheme~ : String,
  config? : Config = Config::new(),
  client_addr? : @socket.Addr,
) -> Bool {
  let server_headers = config.server_headers
  // A WebSocket upgrade is bridged over the raw stream (with subprotocol echo) and ends the
  // connection — it never returns to the keep-alive HTTP loop.
  // A conforming client sends nothing after an upgrade request until it has the 101
  // (RFC 6455 §4.1), so nothing is held here to hand over with the stream.
  if is_websocket_upgrade(fields_map(req.fields)) {
    serve_websocket_raw(app, req, inbox.reader, writer, config~, client_addr?)
    return false
  }
  let (path, query) = split_query(req.target)
  let peer = match client_addr {
    Some(a) => Some(addr_pair(a))
    None => None
  }
  let (client, req_scheme) = if config.proxy_headers {
    proxy_rewrite(
      fields_map(req.fields),
      peer,
      scheme,
      trusted=config.forwarded_allow_ips,
    )
  } else {
    (peer, scheme)
  }
  let scope = @moonasgi.Scope::Http({
    http_version: if req.version == "HTTP/1.0" {
      "1.0"
    } else {
      "1.1"
    },
    http_method: req.verb,
    scheme: req_scheme,
    path,
    raw_path: @utf8.encode(path),
    query_string: @utf8.encode(query),
    root_path: config.root_path,
    headers: fields_pairs(req.fields),
    client,
    server: None,
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
  let body_sent = Ref(false)
  let receive : @moonasgi.Receive = () => {
    if body_sent.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      body_sent.val = true
      // Expect: 100-continue — let the client know it may send the body now.
      if req.expects {
        writer.write(@http1.continue_)
      }
      let body = match req.body {
        Chunked => inbox.chunks()
        Sized(n) => inbox.exactly(n)
        _ => b""
      }
      @moonasgi.Event::HttpRequest(body~, more_body=false)
    }
  }
  let resp_status = Ref(200)
  let resp_headers : Ref[Array[(String, String)]] = Ref([])
  let started = Ref(false)
  let chunked = Ref(false)
  let ended = Ref(false)
  // Answer with the request's HTTP version; HTTP/1.0 has no chunked transfer-encoding,
  // so a streamed 1.0 response is framed by connection close instead.
  let is_http10 = req.version == "HTTP/1.0"
  let resp_version = if is_http10 { "HTTP/1.0" } else { "HTTP/1.1" }
  // A HEAD response carries the same headers as GET but no body (RFC 7231 §4.3.2).
  let is_head = req.verb == "HEAD"
  let close_delimited = Ref(false)
  let head = fn(extra : String) -> String {
    let sb = StringBuilder()
    sb.write_string(
      "\{resp_version} \{resp_status.val} \{@http1.phrase(resp_status.val)}\r\n",
    )
    let sent : Map[String, Bool] = Map([])
    for pair in resp_headers.val {
      let kl = pair.0.to_lower()
      sent[kl] = true
      if kl != "content-length" && kl != "transfer-encoding" {
        sb.write_string("\{pair.0}: \{pair.1}\r\n")
      }
    }
    // Configured server headers (e.g. `Server`) as defaults, unless the app already
    // set the same key — matching what the async HTTP server injects on the plaintext
    // path, so HTTPS responses carry them too.
    for name, value in server_headers {
      let kl = name.to_lower()
      if !sent.contains(kl) &&
        kl != "content-length" &&
        kl != "transfer-encoding" {
        sent[kl] = true
        sb.write_string("\{name}: \{value}\r\n")
      }
    }
    // RFC 7231 §7.1.1.2 asks an origin server with a clock to date every response.
    if config.date_header && !sent.contains("date") {
      sb.write_string("date: \{http_date_now()}\r\n")
    }
    // Signal the connection's fate unless the app already set `Connection`: a server
    // that will close SHOULD say so (RFC 7230 §6.1), and HTTP/1.0 needs an explicit
    // `keep-alive` since it defaults to close.
    if !sent.contains("connection") {
      let will_keep_alive = req.keep_alive && !close_delimited.val
      if !will_keep_alive {
        sb.write_string("connection: close\r\n")
      } else if is_http10 {
        sb.write_string("connection: keep-alive\r\n")
      }
    }
    sb.write_string(extra)
    sb.to_string()
  }
  let send : @moonasgi.Send = event => {
    match event {
      HttpResponseStart(status~, headers~, ..) => {
        resp_status.val = status
        resp_headers.val = headers
      }
      HttpResponseBody(body~, more_body~) =>
        if !started.val {
          started.val = true
          if !more_body {
            writer.write(head("content-length: \{body.length()}\r\n\r\n"))
            if !is_head {
              writer.write(body)
            }
            ended.val = true
          } else if is_head {
            // A HEAD response carries the framing headers a GET would but no body,
            // and no chunk terminator; the head alone completes it.
            writer.write(head("transfer-encoding: chunked\r\n\r\n"))
            ended.val = true
          } else if is_http10 {
            // No chunked on HTTP/1.0: frame the stream by closing the connection.
            close_delimited.val = true
            writer.write(head("\r\n"))
            writer.write(body)
          } else {
            chunked.val = true
            writer.write(head("transfer-encoding: chunked\r\n\r\n"))
            write_chunk(writer, body)
          }
        } else if chunked.val {
          write_chunk(writer, body)
          if !more_body {
            writer.write(@http1.last_chunk())
            ended.val = true
          }
        } else if close_delimited.val {
          writer.write(body)
          if !more_body {
            ended.val = true
          }
        }
      _ => ()
    }
  }
  app(scope, receive, send)
  if !started.val {
    writer.write(head("content-length: 0\r\n\r\n"))
  } else if chunked.val && !ended.val {
    writer.write(@http1.last_chunk())
  }
  // A close-delimited response has no length signal, so the connection must close.
  req.keep_alive && !close_delimited.val
}

///|
/// Read a (closed) pipe to its bytes — a test helper for inspecting the response a
/// `dispatch_http1` run wrote.
async fn drain_pipe(r : @pipe.PipeRead) -> Bytes {
  let buf = Buffer()
  for ;; {
    match r.read_some() {
      Some(chunk) => buf.write_bytes(chunk)
      None => break
    }
  }
  buf.to_bytes()
}

///|
/// Whether `needle` occurs anywhere in `hay` (test helper for response inspection).
fn bytes_has(hay : Bytes, needle : Bytes) -> Bool {
  let n = needle.length()
  if n == 0 {
    return true
  }
  let mut i = 0
  while i + n <= hay.length() {
    let mut j = 0
    while j < n && hay[i + j] == needle[j] {
      j = j + 1
    }
    if j == n {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Drive `dispatch_http1` for `req` with a trivial 200 app over in-memory pipes and
/// return the raw response bytes (test helper).
async fn run_h1(
  req : @http1.Request,
  config? : Config = Config::new(),
  headers? : Array[(String, String)] = [],
) -> Bytes {
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (resp_r, resp_w) = @pipe.pipe()
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers~, trailers=false),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"hi", more_body=false))
  }
  let _ = dispatch_http1(
    app,
    req,
    Inbox::new(req_r),
    resp_w,
    scheme="http",
    config~,
  )
  resp_w.close()
  drain_pipe(resp_r)
}

///|
async test "http1: a HEAD request keeps content-length but suppresses the body" {
  let head_resp = run_h1(h1("HEAD", "HTTP/1.1", ""))
  // The framing header a GET would send is present...
  assert_eq(bytes_has(head_resp, b"content-length: 2"), true)
  // ...but the body ("hi") is not.
  assert_eq(bytes_has(head_resp, b"hi"), false)
  // A GET on the same app does include the body.
  assert_eq(bytes_has(run_h1(h1_req("HTTP/1.1")), b"hi"), true)
}

///|
async test "http1: the response signals connection close and HTTP/1.0 keep-alive" {
  // HTTP/1.1 with Connection: close -> the response echoes connection: close.
  let close_11 = run_h1(h1("GET", "HTTP/1.1", "connection: close\r\n"))
  assert_eq(bytes_has(close_11, b"connection: close"), true)
  // HTTP/1.0 defaults to close -> connection: close.
  assert_eq(bytes_has(run_h1(h1_req("HTTP/1.0")), b"connection: close"), true)
  // HTTP/1.0 with keep-alive requested -> connection: keep-alive.
  let ka_10 = run_h1(h1("GET", "HTTP/1.0", "connection: keep-alive\r\n"))
  assert_eq(bytes_has(ka_10, b"connection: keep-alive"), true)
  // HTTP/1.1 defaults to keep-alive -> no connection: close header.
  assert_eq(bytes_has(run_h1(h1_req("HTTP/1.1")), b"connection: close"), false)
}

///|
/// A request head for driving `dispatch_http1` in tests, read through the real parser.
///
/// Built from octets rather than as a record, so keep-alive, framing and the rest
/// are derived from the version and the fields exactly as they are for a request off
/// a socket — a record could set them to values no real request would produce.
fn h1(verb : String, version : String, fields : String) -> @http1.Request {
  let wire = @utf8.encode(verb + " / " + version + "\r\n" + fields + "\r\n")
  @http1.request(wire[:]).0 catch {
    e => abort("a test request should parse: \{e}")
  }
}

///|
/// A plain `GET /` in the given version.
fn h1_req(version : String) -> @http1.Request {
  h1("GET", version, "")
}

///|
async test "http1: an HTTP/1.0 request is answered with an HTTP/1.0 status line" {
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (resp_r, resp_w) = @pipe.pipe()
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"hi", more_body=false))
  }
  let keep = dispatch_http1(
    app,
    h1_req("HTTP/1.0"),
    Inbox::new(req_r),
    resp_w,
    scheme="http",
  )
  resp_w.close()
  let resp = drain_pipe(resp_r)
  assert_eq(resp[0:8].to_owned() == b"HTTP/1.0", true)
  // HTTP/1.0 defaults to closing the connection.
  assert_eq(keep, false)
}

///|
async test "http1: a streamed HTTP/1.0 response is close-delimited, not chunked" {
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (resp_r, resp_w) = @pipe.pipe()
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"part1", more_body=true))
    send(@moonasgi.Event::HttpResponseBody(body=b"part2", more_body=false))
  }
  let keep = dispatch_http1(
    app,
    h1_req("HTTP/1.0"),
    Inbox::new(req_r),
    resp_w,
    scheme="http",
  )
  resp_w.close()
  let resp = drain_pipe(resp_r)
  let n = resp.length()
  // HTTP/1.0 has no chunked, so the body is written raw and the response ends with the
  // last body part, not a "0\r\n\r\n" chunk terminator.
  assert_eq(resp[n - 5:n].to_owned() == b"part2", true)
  // Close-delimited framing forces the connection closed.
  assert_eq(keep, false)
}

///|
async test "http1: configured server headers ride the response, unless the app sets them" {
  // Default: the configured `server` header is written.
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (resp_r, resp_w) = @pipe.pipe()
  let plain : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"hi", more_body=false))
  }
  let _ = dispatch_http1(
    plain,
    h1_req("HTTP/1.1"),
    Inbox::new(req_r),
    resp_w,
    scheme="http",
    config=Config::new(server_headers=Map([("server", "mooncat")])),
  )
  resp_w.close()
  assert_eq(bytes_has(drain_pipe(resp_r), b"server: mooncat"), true)

  // Override: an app that sets `server` itself wins over the configured default.
  let (req_r2, req_w2) = @pipe.pipe()
  req_w2.close()
  let (resp_r2, resp_w2) = @pipe.pipe()
  let overrides : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("server", "myapp")],
        trailers=false,
      ),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"hi", more_body=false))
  }
  let _ = dispatch_http1(
    overrides,
    h1_req("HTTP/1.1"),
    Inbox::new(req_r2),
    resp_w2,
    scheme="http",
    config=Config::new(server_headers=Map([("server", "mooncat")])),
  )
  resp_w2.close()
  let resp2 = drain_pipe(resp_r2)
  assert_eq(bytes_has(resp2, b"server: myapp"), true)
  assert_eq(bytes_has(resp2, b"server: mooncat"), false)
}

///|
async test "http1: a chunked request body decodes to the joined chunk data" {
  let (r, w) = @pipe.pipe()
  // Two data chunks ("hello" + " world") then the terminating zero chunk.
  w.write(b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
  w.close()
  assert_eq(Inbox::new(r).chunks() == b"hello world", true)
}

///|
async test "http1: a chunked body with a chunk extension and a trailer decodes cleanly" {
  let (r, w) = @pipe.pipe()
  // A chunk-size line carries a `;ext`, and a trailer field follows the zero chunk.
  w.write(b"4;n=v\r\ndata\r\n0\r\nx-checksum: 1\r\n\r\n")
  w.close()
  assert_eq(Inbox::new(r).chunks() == b"data", true)
}

///|
/// The keep-alive read that both HTTPS and plaintext connections sit in between requests. A peer
/// that connects and says nothing must not be able to hold the connection open indefinitely, which
/// is what an unbounded read gave it.
async test "http1: an idle keep-alive read gives up after timeout_keep_alive" {
  @async.with_task_group(g => {
    // A pipe nobody ever writes to: the peer is connected and silent.
    let (r, w) = @pipe.pipe()
    let opened = @async.now()
    // Bounded from outside as well, so a read that ignores the configured deadline fails this
    // test instead of wedging the suite in the very wait it was supposed to end.
    let head = @async.with_timeout_opt(3000, () => {
      next_head(Inbox::new(r), Config::new(timeout_keep_alive=250))
    })
    let waited = @async.now() - opened
    assert_eq(head is Some(None), true)
    // It waited out its own timeout rather than returning at once.
    assert_eq(waited >= 200L, true)
    // A request that does arrive is read normally.
    let feeder = g.spawn(() => {
      w.write(b"GET /ok HTTP/1.1\r\nhost: x\r\n\r\n") catch {
        _ => ()
      }
      w.close()
    })
    guard next_head(Inbox::new(r), Config::new(timeout_keep_alive=3000))
      is Some(req) else {
      fail("a request that arrives inside the timeout should be read")
    }
    assert_eq(req.target, "/ok")
    feeder.cancel()
  })
}

///|
/// The head cap the connection loop applies is the configured one, not the module default: a
/// service behind a proxy that adds a large header block has to be able to raise it.
async test "http1: the keep-alive read applies the configured head cap" {
  @async.with_task_group(g => {
    let head = b"GET /ok HTTP/1.1\r\nx-pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n"
    let (r, w) = @pipe.pipe()
    let feeder = g.spawn(() => {
      w.write(head) catch {
        _ => ()
      }
      w.close()
    })
    assert_eq(
      next_head(
        Inbox::new(r),
        Config::new(max_head_size=64, timeout_keep_alive=3000),
      )
      is None,
      true,
    )
    feeder.cancel()
    // The same head under the default cap parses.
    let (r2, w2) = @pipe.pipe()
    let feeder2 = g.spawn(() => {
      w2.write(head) catch {
        _ => ()
      }
      w2.close()
    })
    guard next_head(Inbox::new(r2), Config::new(timeout_keep_alive=3000))
      is Some(req) else {
      fail("the default 16 KiB cap should accept a 130-byte head")
    }
    assert_eq(req.target, "/ok")
    feeder2.cancel()
  })
}

///|
/// RFC 7231 §7.1.1.2: an origin server with a clock sends `Date` on every response, and uvicorn
/// does. A cache in front of a server that omits it has to invent one.
async test "http1: every response carries a well-formed Date header" {
  let resp = run_h1(h1_req("HTTP/1.1"))
  assert_eq(bytes_has(resp, b"date: "), true)
  // IMF-fixdate is fixed-width and always GMT, so the rendered value is exactly re-derivable.
  assert_eq(bytes_has(resp, @utf8.encode(http_date_now())), true)
  assert_eq(bytes_has(resp, b" GMT\r\n"), true)
}

///|
/// The self-built codec builds its own scope, so it needs its own forwarded-header handling: a
/// request that reached an HTTPS listener through a terminating proxy still has to reach the app
/// with the scheme the client actually used.
async test "http1: a trusted proxy's forwarded headers reach the self-built scope" {
  let seen : Array[String] = []
  let watcher : @moonasgi.AsgiApp = (scope, _receive, send) => {
    guard scope is Http(hs) else { return }
    seen.push(hs.scheme)
    seen.push(
      match hs.client {
        Some((host, port)) => "\{host}:\{port}"
        None => "no-client"
      },
    )
    send(
      @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
  }
  let req = h1(
    "GET", "HTTP/1.1", "x-forwarded-for: 203.0.113.7\r\nx-forwarded-proto: https\r\n",
  )
  let (req_r, req_w) = @pipe.pipe()
  req_w.close()
  let (_resp_r, resp_w) = @pipe.pipe()
  // No peer address is known on this transport, so only the wildcard can trust the headers.
  let _ = dispatch_http1(
    watcher,
    req,
    Inbox::new(req_r),
    resp_w,
    scheme="http",
    config=Config::new(forwarded_allow_ips=["*"]),
  )
  assert_eq(seen[0], "https")
  assert_eq(seen[1], "203.0.113.7:0")

  // The default trust set does not include an unknown peer, so nothing is rewritten.
  let strict : Array[String] = []
  let (req_r2, req_w2) = @pipe.pipe()
  req_w2.close()
  let (_resp_r2, resp_w2) = @pipe.pipe()
  let _ = dispatch_http1(
    watcher,
    req,
    Inbox::new(req_r2),
    resp_w2,
    scheme="http",
    config=Config::new(forwarded_allow_ips=strict),
  )
  assert_eq(seen[2], "http")
  assert_eq(seen[3], "no-client")
}

///|
/// `date_header=false` is uvicorn's `--no-date-header`: something in front is already dating the
/// response, and two `Date` headers is worse than one.
async test "http1: date_header=false leaves the Date header off" {
  let resp = run_h1(h1_req("HTTP/1.1"), config=Config::new(date_header=false))
  assert_eq(bytes_has(resp, b"date: "), false)
  // The rest of the response is unchanged.
  assert_eq(bytes_has(resp, b"content-length: 2"), true)
}

///|
/// An app that dates its own response keeps its value, and does not get a second header.
async test "http1: an app-supplied Date is not duplicated" {
  let fixed = "Sun, 06 Nov 1994 08:49:37 GMT"
  let resp = run_h1(h1_req("HTTP/1.1"), headers=[("date", fixed)])
  assert_eq(bytes_has(resp, @utf8.encode("date: " + fixed)), true)
  // Exactly one `date:` in the head — the app's.
  assert_eq(count_bytes(resp, b"date: "), 1)
}

///|
/// How many times `needle` occurs in `hay` (test helper: a duplicate header is invisible to a
/// "contains" check).
fn count_bytes(hay : Bytes, needle : Bytes) -> Int {
  let n = needle.length()
  let mut found = 0
  let mut i = 0
  while i + n <= hay.length() {
    let mut j = 0
    while j < n && hay[i + j] == needle[j] {
      j = j + 1
    }
    if j == n {
      found = found + 1
      i = i + n
    } else {
      i = i + 1
    }
  }
  found
}

///|
/// uvicorn's `--h11-max-incomplete-event-size` is a knob, not a constant: a service behind a proxy
/// that adds a large header block has to be able to raise it, and one facing the open internet may
/// want it lower than the 16 KiB default.
async test "http1: the request-head cap is configurable, not fixed" {
  // A head of roughly 130 bytes: under the 16 KiB default, over a 64-byte cap.
  let head = b"GET /ok HTTP/1.1\r\nx-pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n"
  let (r1, w1) = @pipe.pipe()
  w1.write(head)
  w1.close()
  guard Inbox::new(r1).head(@http1.limits) is Some(req) else {
    fail("the default cap should accept a 130-byte head")
  }
  assert_eq(req.target, "/ok")
  let (r2, w2) = @pipe.pipe()
  w2.write(head)
  w2.close()
  assert_eq(Inbox::new(r2).head(@http1.Limits::new(head=64)) is None, true)
}
