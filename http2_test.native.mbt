// The greet chain over HTTP/2, as a blackbox test: it drives only mooncat's public
// `serve_h2c`, with a self-contained h2c client built on moonhttp's frames and HPACK.

///|
/// Latin-1 `String` → `Bytes`, for HPACK-encoding request pseudo-headers.
fn h2t_str_to_bytes(s : String) -> Bytes {
  let buf = @buffer.Buffer()
  for i = 0; i < s.length(); i = i + 1 {
    buf.write_byte((s[i].to_int() & 0xFF).to_byte())
  }
  buf.to_bytes()
}

///|
/// Latin-1 `Bytes` → `String`, for reading response header/status octets.
fn h2t_bytes_to_str(b : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    sb.write_char(b[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Read exactly one HTTP/2 frame off the socket with moonrpc's public codec.
async fn h2t_read_frame(reader : &@io.Reader) -> @http2.Frame {
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
/// A minimal real h2c GET on `@socket.Tcp` — preface, SETTINGS, HEADERS with
/// END_STREAM — reading back `(:status, content-type, body)`.
async fn h2t_get(port : Int, path : String) -> (String, String, Bytes) {
  let conn = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
  conn.write(@http2.preface)
  conn.write(@http2.Frame::Settings(params=[], ack=false).encode())
  let enc = @hpack.Encoder::new()
  let block = enc.encode([
    { name: b":method", value: b"GET", },
    { name: b":scheme", value: b"http", },
    { name: b":path", value: h2t_str_to_bytes(path), },
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
  let mut status = ""
  let mut content_type = ""
  let acc = @buffer.Buffer()
  let mut done = false
  while !done {
    let frame = h2t_read_frame(conn)
    match frame {
      Settings(ack~, ..) =>
        if !ack {
          conn.write(@http2.Frame::Settings(params=[], ack=true).encode())
        }
      Headers(fragment~, end_stream~, ..) => {
        for h in dec.decode(fragment) {
          let n = h2t_bytes_to_str(h.name)
          let v = h2t_bytes_to_str(h.value)
          if n == ":status" {
            status = v
          } else if n == "content-type" {
            content_type = v
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
  (status, content_type, acc.to_bytes())
}

///|
/// The greet chain over HTTP/2: a real h2c client GETs `/greet/<name>` from the same
/// routed app the HTTP/1.1 test serves, reading back the JSON body, the content type
/// and `200` — the path decoded out of the HPACK HEADERS block and handed to the app
/// through the seam. Proves the HTTP/2 transport serves an application, not just
/// that it moves frames.
async test "h2c: mooncat serves a routed app answering a real HTTP/2 GET" {
  @async.with_task_group(g => {
    let app = greet_app()
    let task = g.spawn(() => @mooncat.serve_h2c(app, port=18105))
    @async.sleep(250)
    let (status, content_type, body) = h2t_get(18105, "/greet/moon")
    assert_eq(status, "200")
    assert_eq(content_type, "application/json")
    assert_eq(h2t_bytes_to_str(body).contains("hello moon"), true)
    let (miss, _ct, _b) = h2t_get(18105, "/nope")
    assert_eq(miss, "404")
    task.cancel()
  })
}
