// A self-built HTTP/2 cleartext (h2c) server path that drives a moonasgi
// application, reusing the HTTP/2 frame layer (RFC 7540) and HPACK (RFC 7541)
// engine published by `moonbitstack/moonrpc` — the same transport primitives that
// carry real gRPC there. This file is the ASGI-over-h2 binding: it reads the
// client connection preface + SETTINGS, decodes request HEADERS into an ASGI
// `Scope`, streams request DATA as the `Receive` body, and encodes the ASGI
// response (HEADERS + DATA) back, honouring connection- and stream-level flow
// control. Native-only, like the rest of mooncat.

///|
/// The HTTP/2 default initial flow-control window (RFC 7540 §6.9.2) and default
/// maximum frame size (§6.5.2), used until the peer's SETTINGS say otherwise.
const H2_DEFAULT_WINDOW : Int = 65535

///|
const H2_DEFAULT_MAX_FRAME : Int = 16384

///|
/// The largest flow-control window RFC 7540 §6.9.1 permits (2^31 - 1). mooncat
/// advertises this as its own receive window (a big `SETTINGS_INITIAL_WINDOW_SIZE`
/// plus a connection-level WINDOW_UPDATE up to this ceiling) so inbound request
/// bodies never stall on flow control — the server side keeps no inbound window
/// bookkeeping, exactly what a server that trusts its upstream wants.
const H2_MAX_WINDOW : Int = 2147483647

///|
/// Per-stream inbound + outbound state for one HTTP/2 stream (RFC 7540 §5). The
/// request side accumulates the (possibly CONTINUATION-fragmented) header block
/// and the DATA body until END_STREAM; the response side tracks the remaining
/// outbound send window the peer has granted this stream.
priv struct H2Stream {
  id : Int
  mut header_block : Bytes
  mut headers : Array[@header.Header]
  mut headers_done : Bool
  body : @buffer.Buffer
  mut request_ended : Bool
  mut dispatched : Bool
  mut send_window : Int
}

///|
/// Per-connection HTTP/2 state: the socket, the stateful HPACK encoder/decoder
/// pair (their dynamic tables persist across the connection's header blocks), the
/// outbound connection-level send window, the negotiated peer frame size and
/// initial stream window, and the live streams keyed by id. `goaway` latches once
/// the peer asks the connection to wind down.
priv struct H2Conn {
  conn : @socket.Tcp
  dec : @hpack.Decoder
  enc : @hpack.Encoder
  mut conn_send_window : Int
  mut peer_max_frame : Int
  mut peer_initial_window : Int
  streams : Map[Int, H2Stream]
  mut goaway : Bool
}

///|
fn H2Conn::new(conn : @socket.Tcp) -> H2Conn {
  {
    conn,
    dec: @hpack.Decoder::new(),
    enc: @hpack.Encoder::new(),
    conn_send_window: H2_DEFAULT_WINDOW,
    peer_max_frame: H2_DEFAULT_MAX_FRAME,
    peer_initial_window: H2_DEFAULT_WINDOW,
    streams: Map([]),
    goaway: false,
  }
}

///|
fn imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Latin-1 `Bytes` → `String`, one code unit per octet (HTTP/2 header names and
/// values are byte strings; the pseudo-headers mooncat reads are ASCII).
fn h2_bytes_to_str(b : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    sb.write_char(b[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Latin-1 `String` → `Bytes`, the inverse of `h2_bytes_to_str`, for HPACK-encoding
/// response header names and values.
fn h2_str_to_bytes(s : String) -> Bytes {
  let buf = @buffer.Buffer()
  for i = 0; i < s.length(); i = i + 1 {
    buf.write_byte((s[i].to_int() & 0xFF).to_byte())
  }
  buf.to_bytes()
}

///|
/// Concatenate two byte strings.
fn h2_cat(a : Bytes, b : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
/// Read exactly one HTTP/2 frame off the socket — the 9-octet header, then its
/// declared payload — and decode it with moonrpc's pure frame codec. Raises when
/// the peer closes mid-frame (a short read) or the bytes are malformed; the accept
/// loop treats that as the end of the connection.
async fn h2_read_frame(reader : &@io.Reader) -> @http2.Frame {
  let head = reader.read_exactly(9)
  let hdr = @http2.FrameHeader::decode(head)
  let payload = if hdr.length > 0 {
    reader.read_exactly(hdr.length)
  } else {
    b""
  }
  let buf = @buffer.Buffer()
  buf.write_bytes(head)
  buf.write_bytes(payload)
  let (frame, _consumed) = @http2.decode(buf.to_bytes())
  frame
}

///|
/// Look up an existing stream or create it, seeding a new stream's outbound send
/// window with the peer's current `SETTINGS_INITIAL_WINDOW_SIZE`.
fn H2Conn::stream(self : H2Conn, id : Int) -> H2Stream {
  match self.streams.get(id) {
    Some(s) => s
    None => {
      let s : H2Stream = {
        id,
        header_block: b"",
        headers: [],
        headers_done: false,
        body: @buffer.Buffer(),
        request_ended: false,
        dispatched: false,
        send_window: self.peer_initial_window,
      }
      self.streams[id] = s
      s
    }
  }
}

///|
/// Apply one decoded inbound frame to the connection/stream state **without**
/// invoking the application: SETTINGS are acknowledged (and the peer's frame size
/// / initial window recorded, with the RFC 7540 §6.9.2 delta applied to live
/// streams), PING is answered with a PONG, WINDOW_UPDATE grows the matching send
/// window, HEADERS/CONTINUATION accumulate and (at END_HEADERS) HPACK-decode the
/// block **in arrival order** — HPACK is stateful, so decoding must happen as the
/// block completes — and DATA appends to the request body. Dispatching a ready
/// stream is deferred to `dispatch_ready`, which keeps this reentrancy-free so the
/// outbound flow-control pump can call it while a response is in flight.
async fn H2Conn::apply(self : H2Conn, frame : @http2.Frame) -> Unit {
  match frame {
    Settings(params~, ack~) =>
      if !ack {
        for pair in params {
          if pair.0 == @http2.settings_max_frame_size {
            self.peer_max_frame = pair.1
          } else if pair.0 == @http2.settings_initial_window_size {
            let delta = pair.1 - self.peer_initial_window
            self.peer_initial_window = pair.1
            for _id, s in self.streams {
              s.send_window = s.send_window + delta
            }
          }
        }
        self.conn.write(@http2.Frame::Settings(params=[], ack=true).encode())
      }
    Ping(payload~, ack~) =>
      if !ack {
        self.conn.write(@http2.Frame::Ping(payload~, ack=true).encode())
      }
    WindowUpdate(stream_id~, increment~) =>
      if stream_id == 0 {
        self.conn_send_window = self.conn_send_window + increment
      } else {
        self.stream(stream_id).send_window += increment
      }
    Headers(stream_id~, fragment~, end_stream~, end_headers~, ..) => {
      let s = self.stream(stream_id)
      s.header_block = h2_cat(s.header_block, fragment)
      if end_stream {
        s.request_ended = true
      }
      if end_headers {
        s.headers = self.dec.decode(s.header_block)
        s.headers_done = true
      }
    }
    Continuation(stream_id~, fragment~, end_headers~) => {
      let s = self.stream(stream_id)
      s.header_block = h2_cat(s.header_block, fragment)
      if end_headers {
        s.headers = self.dec.decode(s.header_block)
        s.headers_done = true
      }
    }
    Data(stream_id~, data~, end_stream~, ..) => {
      let s = self.stream(stream_id)
      s.body.write_bytes(data)
      if end_stream {
        s.request_ended = true
      }
    }
    RstStream(stream_id~, ..) => self.streams.remove(stream_id)
    GoAway(..) => self.goaway = true
    _ => ()
  }
}

///|
/// Read and apply exactly one further frame — the outbound flow-control pump. When
/// a response is larger than the peer's send window, the send path calls this to
/// take in the peer's WINDOW_UPDATE (and answer any interleaved PING/SETTINGS)
/// until the window reopens. It never dispatches, so it cannot re-enter the app.
async fn H2Conn::pump_one(self : H2Conn) -> Unit {
  let frame = h2_read_frame(self.conn)
  self.apply(frame)
}

///|
/// Write one response body as DATA frames, honouring both the stream and the
/// connection send windows and the peer's maximum frame size (RFC 7540 §6.9): the
/// payload is split into window-bounded, frame-size-bounded chunks; when a window
/// is exhausted the pump reads the peer's WINDOW_UPDATE before continuing. The
/// final chunk carries END_STREAM when `end_stream` is set; an empty body with
/// `end_stream` still emits a lone END_STREAM DATA frame to close the stream.
async fn H2Conn::write_body(
  self : H2Conn,
  stream_id : Int,
  s : H2Stream,
  data : Bytes,
  end_stream~ : Bool,
) -> Unit {
  let n = data.length()
  if n == 0 {
    if end_stream {
      self.conn.write(
        @http2.Frame::Data(stream_id~, data=b"", end_stream=true, padding=0).encode(),
      )
    }
    return
  }
  let mut off = 0
  while off < n {
    while s.send_window <= 0 || self.conn_send_window <= 0 {
      self.pump_one()
    }
    let avail = imin(
      imin(self.peer_max_frame, s.send_window),
      self.conn_send_window,
    )
    let take = imin(avail, n - off)
    let chunk = data[off:off + take].to_owned()
    let last = off + take == n && end_stream
    self.conn.write(
      @http2.Frame::Data(stream_id~, data=chunk, end_stream=last, padding=0).encode(),
    )
    s.send_window = s.send_window - take
    self.conn_send_window = self.conn_send_window - take
    off = off + take
  }
}

///|
/// Header names an ASGI app may set that are connection-specific under HTTP/1 and
/// forbidden (or framing-owned) under HTTP/2, so they are dropped from the response
/// header block (RFC 7540 §8.1.2.2). `content-length` is dropped too: the DATA +
/// END_STREAM framing delimits the body, and a streamed response has none to give.
fn h2_is_dropped_response_header(name : String) -> Bool {
  match name.to_lower() {
    "connection"
    | "keep-alive"
    | "transfer-encoding"
    | "upgrade"
    | "proxy-connection"
    | "content-length" => true
    _ => false
  }
}

///|
/// Build the response header list for HPACK encoding: the `:status` pseudo-header
/// first (RFC 7540 §8.1.2.4), then every app header that is legal to carry over
/// HTTP/2, lower-cased as the protocol requires (§8.1.2).
fn h2_response_headers(
  status : Int,
  headers : Array[(String, String)],
) -> Array[@header.Header] {
  let out : Array[@header.Header] = [
    { name: b":status", value: h2_str_to_bytes(status.to_string()), },
  ]
  for pair in headers {
    if !h2_is_dropped_response_header(pair.0) {
      out.push({
        name: h2_str_to_bytes(pair.0.to_lower()),
        value: h2_str_to_bytes(pair.1),
      })
    }
  }
  out
}

///|
/// Turn a completed request stream's decoded HEADERS into an ASGI HTTP `Scope`.
/// The pseudo-headers `:method` / `:path` / `:scheme` / `:authority` (RFC 7540
/// §8.1.2.3) become the scope's method / path+query / scheme, and every ordinary
/// header is carried through; a synthetic `host` is derived from `:authority` when
/// the request has no explicit `host`, matching how HTTP/2 servers present the
/// authority to an application. `http_version` is `"2"`.
fn h2_build_scope(headers : Array[@header.Header]) -> @moonasgi.Scope {
  let mut verb = "GET"
  let mut target = "/"
  let mut scheme = "http"
  let mut authority = ""
  let mut has_host = false
  let pairs : Array[(String, String)] = []
  for h in headers {
    let name = h2_bytes_to_str(h.name)
    let value = h2_bytes_to_str(h.value)
    if name == ":method" {
      verb = value
    } else if name == ":path" {
      target = value
    } else if name == ":scheme" {
      scheme = value
    } else if name == ":authority" {
      authority = value
    } else if name.length() > 0 && name[0] != ':' {
      if name == "host" {
        has_host = true
      }
      pairs.push((name, value))
    }
  }
  if not_empty(authority) && !has_host {
    pairs.push(("host", authority))
  }
  let (path, query) = split_query(target)
  @moonasgi.Scope::Http({
    http_version: "2",
    http_method: verb,
    scheme,
    path,
    raw_path: @utf8.encode(path),
    query_string: @utf8.encode(query),
    root_path: "",
    headers: pairs,
    client: None,
    server: None,
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: @moonasgi.Extensions::none(),
    state: Map([]),
  })
}

///|
fn not_empty(s : String) -> Bool {
  s.length() > 0
}

///|
/// Drive one fully-received request stream through the moonasgi SEAM: build the
/// `Scope`, a `Receive` that yields the buffered request body then a disconnect,
/// and a `Send` that maps `HttpResponseStart` to a HEADERS frame and each
/// `HttpResponseBody` to flow-controlled DATA. If the app finishes without an
/// explicit final body the stream is still closed with an END_STREAM DATA frame;
/// if it never started a response the stream is closed with a bare 500.
async fn H2Conn::dispatch_stream(
  self : H2Conn,
  app : @moonasgi.AsgiApp,
  s : H2Stream,
) -> Unit {
  let scope = h2_build_scope(s.headers)
  let body_done = Ref(false)
  let receive : @moonasgi.Receive = () => {
    if body_done.val {
      @moonasgi.Event::HttpDisconnect
    } else {
      body_done.val = true
      @moonasgi.Event::HttpRequest(body=s.body.to_bytes(), more_body=false)
    }
  }
  let started = Ref(false)
  let ended = Ref(false)
  let send : @moonasgi.Send = event => {
    match event {
      HttpResponseStart(status~, headers~, ..) => {
        started.val = true
        let block = self.enc.encode(h2_response_headers(status, headers))
        self.conn.write(
          @http2.Frame::Headers(
            stream_id=s.id,
            fragment=block,
            end_stream=false,
            end_headers=true,
            priority=None,
            padding=0,
          ).encode(),
        )
      }
      HttpResponseBody(body~, more_body~) => {
        self.write_body(s.id, s, body, end_stream=!more_body)
        if !more_body {
          ended.val = true
        }
      }
      _ => ()
    }
  }
  app(scope, receive, send)
  if started.val && !ended.val {
    self.write_body(s.id, s, b"", end_stream=true)
  } else if !started.val {
    let block = self.enc.encode([{ name: b":status", value: b"500", }])
    self.conn.write(
      @http2.Frame::Headers(
        stream_id=s.id,
        fragment=block,
        end_stream=true,
        end_headers=true,
        priority=None,
        padding=0,
      ).encode(),
    )
  }
}

///|
/// Dispatch every stream whose request is complete (END_HEADERS + END_STREAM) and
/// not yet served. Runs after each applied frame; a response is produced for one
/// stream at a time on the connection (the outbound flow-control pump keeps the
/// read side live while a response drains), which is the concurrency a single
/// HTTP/2 endpoint gives without cross-stream response interleaving.
async fn H2Conn::dispatch_ready(self : H2Conn, app : @moonasgi.AsgiApp) -> Unit {
  for _id, s in self.streams {
    if s.headers_done && s.request_ended && !s.dispatched {
      s.dispatched = true
      self.dispatch_stream(app, s)
    }
  }
}

///|
/// Drive one accepted h2c connection to completion: validate the client connection
/// preface, advertise a wide receive window (a big `SETTINGS_INITIAL_WINDOW_SIZE`
/// plus a connection-level WINDOW_UPDATE to the §6.9.1 ceiling) so inbound bodies
/// never stall, then loop — read a frame, apply it, dispatch any now-complete
/// request — until the peer closes the socket or sends GOAWAY. A read error (a
/// closed connection) ends the loop cleanly.
async fn drive_h2c(app : @moonasgi.AsgiApp, conn : @socket.Tcp) -> Unit {
  let preface = conn.read_exactly(@http2.preface.length())
  if !@http2.has_preface(preface) {
    return
  }
  let h2 = H2Conn::new(conn)
  conn.write(
    @http2.Frame::Settings(
      params=[(@http2.settings_initial_window_size, H2_MAX_WINDOW)],
      ack=false,
    ).encode(),
  )
  conn.write(
    @http2.Frame::WindowUpdate(
      stream_id=0,
      increment=H2_MAX_WINDOW - H2_DEFAULT_WINDOW,
    ).encode(),
  )
  for ;; {
    if h2.goaway {
      break
    }
    let frame = h2_read_frame(conn) catch { _ => break }
    h2.apply(frame)
    h2.dispatch_ready(app)
  }
}

///|
/// Serve a moonasgi ASGI application over **HTTP/2 cleartext (h2c)** — the
/// prior-knowledge, no-TLS HTTP/2 profile (RFC 7540 §3.4) — reusing moonrpc's
/// self-built HTTP/2 + HPACK engine as the transport. Convenience wrapper over
/// `serve_h2c_config` that builds a `Config` from `host` / `port`. Blocks in the
/// accept loop until the running task is cancelled.
///
/// h2c rather than `h2`-over-TLS because the `moonbitlang/async` TLS layer exposes
/// no ALPN, so the protocol can't be negotiated on a TLS connection yet; h2c is
/// the direct, ALPN-free path a client reaches with prior knowledge (as
/// `curl --http2-prior-knowledge` or a gRPC client does).
pub async fn serve_h2c(
  app : @moonasgi.AsgiApp,
  host? : String = "127.0.0.1",
  port? : Int = port,
) -> Unit {
  serve_h2c_config(app, Config::new(host~, port~))
}

///|
/// Serve a moonasgi ASGI application over h2c under an explicit `Config`. Mirrors
/// `serve_config` / `serve_tls_config`: the ASGI lifespan protocol runs around the
/// accept loop (startup before the listener binds, shutdown on the way out — even
/// under cancellation, guarded by `protect_from_cancel`), and each accepted
/// connection is driven by `drive_h2c` over the self-built HTTP/2 transport.
pub async fn serve_h2c_config(app : @moonasgi.AsgiApp, config : Config) -> Unit {
  @async.with_task_group(g => {
    let lifespan = Lifespan::new(app)
    let task = lifespan.spawn(g)
    lifespan.startup(task)
    let server = @socket.TcpServer(
      @socket.Addr::parse(config.bind()),
      dual_stack=config.dual_stack,
      reuse_addr=config.reuse_addr,
    )
    defer {
      @async.protect_from_cancel(() => lifespan.shutdown(task) catch { _ => () })
      server.close()
    }
    server.run_forever(
      (conn, _addr) => drive_h2c(app, conn),
      allow_failure=config.allow_failure,
      max_connections?=config.max_connections,
    )
  })
}
