///|
/// HTTP/2 cleartext (h2c), on the wire. A client reaches mooncat's h2c server with
/// prior knowledge (RFC 7540 §3.4) — no TLS, no ALPN, the way
/// `curl --http2-prior-knowledge` or a gRPC client does. This walks the exact
/// exchange `serve_h2c_config` performs, but in-process over bytes: the connection
/// preface a server sniffs first, the SETTINGS + WINDOW_UPDATE frames it answers
/// with, and the response body — produced by running the same moonasgi app through
/// the synchronous `run_http` seam — carried back as an HTTP/2 DATA frame. The h2
/// transport is moonrpc's self-built HTTP/2 + HPACK engine, the same one
/// `serve_h2c_config` binds over a real socket.
///
///     moon run examples/33-http2-h2c --target native
fn hex(bs : Bytes) -> String {
  let digits = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let buf = StringBuilder()
  for b in bs {
    let v = b.to_int() & 0xFF
    buf.write_char(digits[v >> 4])
    buf.write_char(digits[v & 0xF])
  }
  buf.to_string()
}

///|
fn roundtrip(label : String, frame : @moonrpc.Frame) -> Unit {
  let wire = frame.encode()
  let ok = try {
    let (back, consumed) = @moonrpc.decode_frame(wire)
    back == frame && consumed == wire.length()
  } catch {
    _ => false
  }
  println("  \{label}: \{wire.length()} octets \{hex(wire)} (round-trip \{ok})")
}

///|
#coverage.skip
fn main {
  // 1. The client connection preface: the 24 octets an h2c server reads and checks
  //    before anything else. `drive_h2c` rejects a connection that doesn't open with it.
  let preface = @moonrpc.connection_preface
  println("preface: \{preface.length()} octets \{hex(preface)}")
  println(
    "  has_connection_preface(preface) = \{@moonrpc.has_connection_preface(preface)}",
  )
  println(
    "  has_connection_preface(b\"GET / HTTP/1.1\") = \{@moonrpc.has_connection_preface(b"GET / HTTP/1.1")}",
  )

  // 2. The frames the server sends right after the preface (mirrors drive_h2c): a
  //    SETTINGS advertising a wide receive window, then a connection-level WINDOW_UPDATE.
  println("server settings:")
  roundtrip(
    "SETTINGS",
    @moonrpc.Frame::Settings(
      params=[(@moonrpc.settings_initial_window_size, 0x100000)],
      ack=false,
    ),
  )
  roundtrip(
    "WINDOW_UPDATE",
    @moonrpc.Frame::WindowUpdate(stream_id=0, increment=0xF0000),
  )

  // 3. The response body comes from the very same moonasgi app, run in-process over
  //    the synchronous seam — no socket. h2c carries it back as a DATA frame on the
  //    request's stream (HEADERS with the :status pseudo-header are HPACK-encoded,
  //    which the moonrpc hpack example covers).
  let app : @moonasgi.Handler = _req => {
    @moonasgi.Response::text("hello over h2c from mooncat, heke1228\n")
  }
  let scope = @moonasgi.Scope::Http(
    @moonasgi.HttpScope::new(http_method="GET", path="/"),
  )
  let inbound = [@moonasgi.Event::HttpRequest(body=b"", more_body=false)]
  let mut resp_body = b""
  let mut status = 0
  for ev in @moonasgi.run_http(app, scope, inbound) {
    match ev {
      @moonasgi.Event::HttpResponseStart(status=s, ..) => status = s
      @moonasgi.Event::HttpResponseBody(body~, ..) => resp_body = body
      _ => ()
    }
  }
  println("app response: status=\{status}, \{resp_body.length()} body octets")
  println("response DATA frame (stream 1, end_stream):")
  roundtrip(
    "DATA",
    @moonrpc.Frame::Data(
      stream_id=1,
      data=resp_body,
      end_stream=true,
      padding=0,
    ),
  )

  // `serve_h2c_config(app, Config::new(host=..., port=...))` carries exactly this
  // exchange over a bound TCP socket; here it stays in-process and self-terminating.
  let cfg = @mooncat.Config::new(host="127.0.0.1", port=23333)
  println("serve_h2c_config would bind this on http://\{cfg.bind()}")
}
