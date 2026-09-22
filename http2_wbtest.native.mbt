// Integration tests for the h2c server path. Whitebox so they can reach the
// package-internal frame/HPACK helpers (`h2_read_frame`, the latin-1 codecs) and
// drive a minimal, independent real HTTP/2 client built on the same moonrpc
// primitives the server uses.

///|
/// A minimal real HTTP/2 (h2c) client on `@socket.Tcp` and the moonrpc frame +
/// HPACK codecs — the independent end of the round-trip. It opens one stream, sends
/// the request HEADERS (and a single DATA frame for a body), then reads the
/// response, acknowledging SETTINGS and replenishing both flow-control windows as
/// DATA arrives so a flow-controlled server keeps sending. Returns `(:status,
/// response headers, body)`.
async fn h2c_request(
  host : String,
  port : Int,
  verb : String,
  path : String,
  body? : Bytes = b"",
  extra_headers? : Array[(Bytes, Bytes)] = [],
) -> (String, Array[(String, String)], Bytes) {
  let conn = @socket.Tcp::connect(@socket.Addr::parse("\{host}:\{port}"))
  conn.write(@http2.preface)
  conn.write(@http2.Frame::Settings(params=[], ack=false).encode())
  let enc = @hpack.Encoder::new()
  let hdrs : Array[@header.Header] = [
    { name: b":method", value: h2_str_to_bytes(verb), },
    { name: b":scheme", value: b"http", },
    { name: b":path", value: h2_str_to_bytes(path), },
    { name: b":authority", value: h2_str_to_bytes(host), },
  ]
  for e in extra_headers {
    hdrs.push({ name: e.0, value: e.1, })
  }
  let block = enc.encode(hdrs)
  let has_body = body.length() > 0
  conn.write(
    @http2.Frame::Headers(
      stream_id=1,
      fragment=block,
      end_stream=!has_body,
      end_headers=true,
      priority=None,
      padding=0,
    ).encode(),
  )
  if has_body {
    conn.write(
      @http2.Frame::Data(stream_id=1, data=body, end_stream=true, padding=0).encode(),
    )
  }
  let dec = @hpack.Decoder::new()
  let mut status = ""
  let rheaders : Array[(String, String)] = []
  let acc = @buffer.Buffer()
  let mut done = false
  while !done {
    let frame = h2_read_frame(conn)
    match frame {
      Settings(ack~, ..) =>
        if !ack {
          conn.write(@http2.Frame::Settings(params=[], ack=true).encode())
        }
      Headers(fragment~, end_stream~, ..) => {
        for h in dec.decode(fragment) {
          let n = h2_bytes_to_str(h.name)
          let v = h2_bytes_to_str(h.value)
          if n == ":status" {
            status = v
          } else {
            rheaders.push((n, v))
          }
        }
        if end_stream {
          done = true
        }
      }
      Data(data~, stream_id~, end_stream~, ..) => {
        acc.write_bytes(data)
        if data.length() > 0 {
          conn.write(
            @http2.Frame::WindowUpdate(stream_id=0, increment=data.length()).encode(),
          )
          conn.write(
            @http2.Frame::WindowUpdate(stream_id~, increment=data.length()).encode(),
          )
        }
        if end_stream {
          done = true
        }
      }
      _ => ()
    }
  }
  conn.close()
  (status, rheaders, acc.to_bytes())
}

///|
/// Whether a `(name, value)` header pair is present in a response header list.
fn has_header(
  headers : Array[(String, String)],
  name : String,
  value : String,
) -> Bool {
  for pair in headers {
    if pair.0 == name && pair.1 == value {
      return true
    }
  }
  false
}

///|
/// The core "can actually run" milestone: a real HTTP/2 (h2c) client performs a GET
/// against a `serve_h2c`-served route and reads back `200`, the exact body, and a
/// response header — over the self-built HTTP/2 transport, preface to trailer.
async test "h2c: a real HTTP/2 client GETs a route and reads 200 + body + header" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(_) else { return }
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[("content-type", "text/plain")],
          trailers=false,
        ),
      )
      send(
        @moonasgi.Event::HttpResponseBody(
          body=b"hello over h2c",
          more_body=false,
        ),
      )
    }
    let task = g.spawn(() => serve_h2c(app, port=18100))
    @async.sleep(250)
    let (status, headers, body) = h2c_request("127.0.0.1", 18100, "GET", "/")
    assert_eq(status, "200")
    assert_eq(body == b"hello over h2c", true)
    assert_eq(has_header(headers, "content-type", "text/plain"), true)
    task.cancel()
  })
}

///|
/// A request DATA body streams to the app as the ASGI `Receive` body: the app reads
/// the request body off `receive()` and echoes it, and a real h2c POST round-trips
/// it. Proves the HEADERS→scope and DATA→receive-body legs together.
async test "h2c: a POST body reaches the app as the receive body and echoes back" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Http(_) else { return }
      let body = match receive() {
        HttpRequest(body~, ..) => body
        _ => b""
      }
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body~, more_body=false))
    }
    let task = g.spawn(() => serve_h2c(app, port=18101))
    @async.sleep(250)
    let (status, _headers, body) = h2c_request(
      "127.0.0.1",
      18101,
      "POST",
      "/echo",
      body=b"ping-pong-over-h2",
    )
    assert_eq(status, "200")
    assert_eq(body == b"ping-pong-over-h2", true)
    task.cancel()
  })
}

///|
/// Outbound flow control (RFC 7540 §6.9): a client that advertises a small stream
/// window must receive the response one window-sized frame at a time. The client
/// grants exactly `100` octets, reads the first DATA frame, and asserts it is
/// exactly `100` octets — the server clamped its send to the granted window rather
/// than dumping the whole body — then drains the rest and checks the full body
/// reassembles. This is the mutation-verified flow-control assertion: a server that
/// ignored the window would send a larger first frame.
async test "h2c: a large response is clamped to the peer's small stream window" {
  @async.with_task_group(g => {
    let payload = Bytes::make(1000, b'z')
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(_) else { return }
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=payload, more_body=false))
    }
    let task = g.spawn(() => serve_h2c(app, port=18103))
    @async.sleep(250)
    let conn = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:18103"))
    conn.write(@http2.preface)
    conn.write(
      @http2.Frame::Settings(
        params=[(@http2.settings_initial_window_size, 100)],
        ack=false,
      ).encode(),
    )
    let enc = @hpack.Encoder::new()
    let block = enc.encode([
      { name: b":method", value: b"GET", },
      { name: b":scheme", value: b"http", },
      { name: b":path", value: b"/big", },
      { name: b":authority", value: b"127.0.0.1", },
    ])
    conn.write(
      @http2.Frame::Headers(
        stream_id=1,
        fragment=block,
        end_stream=true,
        end_headers=true,
        priority=None,
        padding=0,
      ).encode(),
    )
    let dec = @hpack.Decoder::new()
    let acc = @buffer.Buffer()
    let mut first_data_len = -1
    let mut done = false
    while !done {
      let frame = h2_read_frame(conn)
      match frame {
        Settings(ack~, ..) =>
          if !ack {
            conn.write(@http2.Frame::Settings(params=[], ack=true).encode())
          }
        Headers(fragment~, ..) => dec.decode(fragment) |> ignore
        Data(data~, stream_id~, end_stream~, ..) => {
          if first_data_len < 0 {
            first_data_len = data.length()
          }
          acc.write_bytes(data)
          if data.length() > 0 {
            conn.write(
              @http2.Frame::WindowUpdate(stream_id=0, increment=data.length()).encode(),
            )
            conn.write(
              @http2.Frame::WindowUpdate(stream_id~, increment=data.length()).encode(),
            )
          }
          if end_stream {
            done = true
          }
        }
        _ => ()
      }
    }
    conn.close()
    assert_eq(first_data_len, 100)
    assert_eq(acc.to_bytes().length(), 1000)
    task.cancel()
  })
}

///|
/// Multiplexing (RFC 7540 §5): two requests on distinct stream ids share one
/// connection and both get their own response, tagged by stream id. The client
/// opens stream 1 and stream 3 before reading, then buckets response frames by
/// stream id and checks each stream got its expected body — the frame layer
/// demultiplexes and the server dispatches each stream independently.
async test "h2c: two streams multiplex on one connection and each gets its reply" {
  @async.with_task_group(g => {
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(http_scope) else { return }
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(
        @moonasgi.Event::HttpResponseBody(
          body=h2_str_to_bytes("path=\{http_scope.path}"),
          more_body=false,
        ),
      )
    }
    let task = g.spawn(() => serve_h2c(app, port=18104))
    @async.sleep(250)
    let conn = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:18104"))
    conn.write(@http2.preface)
    conn.write(@http2.Frame::Settings(params=[], ack=false).encode())
    let enc = @hpack.Encoder::new()
    let mk = (sid : Int, path : Bytes) => {
      let block = enc.encode([
        { name: b":method", value: b"GET", },
        { name: b":scheme", value: b"http", },
        { name: b":path", value: path, },
        { name: b":authority", value: b"127.0.0.1", },
      ])
      conn.write(
        @http2.Frame::Headers(
          stream_id=sid,
          fragment=block,
          end_stream=true,
          end_headers=true,
          priority=None,
          padding=0,
        ).encode(),
      )
    }
    mk(1, b"/one")
    mk(3, b"/three")
    let dec = @hpack.Decoder::new()
    let bodies : Map[Int, @buffer.Buffer] = Map([])
    let ended : Map[Int, Bool] = Map([])
    let mut open_streams = 2
    while open_streams > 0 {
      let frame = h2_read_frame(conn)
      match frame {
        Settings(ack~, ..) =>
          if !ack {
            conn.write(@http2.Frame::Settings(params=[], ack=true).encode())
          }
        Headers(fragment~, stream_id~, end_stream~, ..) => {
          dec.decode(fragment) |> ignore
          if end_stream && not_ended(ended, stream_id) {
            ended[stream_id] = true
            open_streams = open_streams - 1
          }
        }
        Data(data~, stream_id~, end_stream~, ..) => {
          let buf = match bodies.get(stream_id) {
            Some(b) => b
            None => {
              let b = @buffer.Buffer()
              bodies[stream_id] = b
              b
            }
          }
          buf.write_bytes(data)
          if end_stream && not_ended(ended, stream_id) {
            ended[stream_id] = true
            open_streams = open_streams - 1
          }
        }
        _ => ()
      }
    }
    conn.close()
    let b1 = match bodies.get(1) {
      Some(b) => h2_bytes_to_str(b.to_bytes())
      None => ""
    }
    let b3 = match bodies.get(3) {
      Some(b) => h2_bytes_to_str(b.to_bytes())
      None => ""
    }
    assert_eq(b1, "path=/one")
    assert_eq(b3, "path=/three")
    task.cancel()
  })
}

///|
/// Whether `stream_id` has not yet been marked ended, for the multiplex test's
/// stream bookkeeping.
fn not_ended(ended : Map[Int, Bool], stream_id : Int) -> Bool {
  match ended.get(stream_id) {
    Some(true) => false
    _ => true
  }
}
