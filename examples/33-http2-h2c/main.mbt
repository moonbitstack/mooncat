///|
fn roundtrip(label : String, frame : @http2.Frame) -> Unit {
  let wire = frame.encode()
  let ok = try {
    let (back, consumed) = @http2.decode(wire)
    back == frame && consumed == wire.length()
  } catch {
    _ => false
  }
  println(
    "  \{label}: \{wire.length()} octets \{@base16.encode(wire)} (round-trip \{ok})",
  )
}

///|
#coverage.skip
fn main {
  // 1. The client connection preface: the 24 octets an h2c server reads and checks
  //    before anything else. `drive_h2c` rejects a connection that doesn't open with it.
  let preface = @http2.preface
  println("preface: \{preface.length()} octets \{@base16.encode(preface)}")
  println("  has_connection_preface(preface) = \{@http2.has_preface(preface)}")
  println(
    "  has_connection_preface(b\"GET / HTTP/1.1\") = \{@http2.has_preface(b"GET / HTTP/1.1")}",
  )

  // 2. The frames the server sends right after the preface (mirrors drive_h2c): a
  //    SETTINGS advertising a wide receive window, then a connection-level WINDOW_UPDATE.
  println("server settings:")
  roundtrip(
    "SETTINGS",
    @http2.Frame::Settings(
      params=[(@http2.settings_initial_window_size, 0x100000)],
      ack=false,
    ),
  )
  roundtrip(
    "WINDOW_UPDATE",
    @http2.Frame::WindowUpdate(stream_id=0, increment=0xF0000),
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
    @http2.Frame::Data(stream_id=1, data=resp_body, end_stream=true, padding=0),
  )

  // `serve_h2c_config(app, Config::new(host=..., port=...))` carries exactly this
  // exchange over a bound TCP socket; here it stays in-process and self-terminating.
  let cfg = @mooncat.Config::new(host="127.0.0.1", port=12000)
  println("serve_h2c_config would bind this on http://\{cfg.bind()}")
}
