// An HTTP/3 server that answers what an interoperability runner asks of one: `GET /<n>` is `n`
// bytes, `POST /<n>` takes `n` bytes and says how many arrived, and `GET /` is a short line. The
// knobs are the ones a testcase needs to change — `MOONCAT_RETRY` for the Retry exchange, and
// `MOONCAT_EARLY` for 0-RTT — so one binary covers every case.
//
//     MOONCAT_PORT=443 MOONCAT_RETRY=1 moon run src/examples/16-interop-server --target native
//
// `scripts/interop/` runs it in the image the runner expects, and `scripts/interop/check_matrix.py`
// drives it directly.

///|
fn setting(name : String) -> String? {
  @env.get_env_var(name)
}

///|
fn number(name : String, fallback : Int32) -> Int32 {
  match setting(name) {
    Some(text) => @string.parse_int(text) catch { _ => fallback }
    None => fallback
  }
}

///|
fn switched_on(name : String) -> Bool {
  match setting(name) {
    Some("1") | Some("true") | Some("yes") => true
    _ => false
  }
}

///|
/// The bytes of a `/<n>` request: one repeating pattern, so a client can check the length and the
/// content without being handed the file.
fn pattern(size : Int32) -> Bytes {
  Bytes::makei(size, i => (i % 251).to_byte())
}

///|
async fn app(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is Http(http) else { return }
  let count = @string.parse_int(http.path.trim_start(chars="/")) catch {
    _ => -1
  }
  if http.http_method == "GET" || http.http_method == "HEAD" {
    let body = if count >= 0 { pattern(count) } else { b"mooncat\n" }
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[
          ("content-type", "application/octet-stream"),
          ("content-length", body.length().to_string()),
        ],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(
        body=if http.http_method == "HEAD" { b"" } else { body },
        more_body=false,
      ),
    )
    return
  }
  // An upload: count what arrives, and put it where the runner looks for it when it says where
  // that is.
  let held = Buffer()
  for ;; {
    guard receive() is HttpRequest(body~, more_body~) else { return }
    held.write_bytes(body)
    if !more_body {
      break
    }
  }
  let got = held.to_bytes()
  if count >= 0 && got.length() != count {
    send(
      @moonasgi.Event::HttpResponseStart(
        status=400,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(
        body=@utf8.encode("wanted \{count} bytes, got \{got.length()}"),
        more_body=false,
      ),
    )
    return
  }
  if setting("DOWNLOADS") is Some(dir) && count >= 0 {
    let file = dir + "/" + count.to_string()
    @fs.write_file(file, got) catch {
      _ => ()
    }
  }
  let line = "received \{got.length()} bytes\n"
  send(
    @moonasgi.Event::HttpResponseStart(
      status=200,
      headers=[("content-type", "text/plain")],
      trailers=false,
    ),
  )
  send(
    @moonasgi.Event::HttpResponseBody(
      body=@utf8.encode(line),
      more_body=false,
    ),
  )
}

///|
async fn main {
  let port = number("MOONCAT_PORT", 12000)
  let early = match setting("MOONCAT_EARLY") {
    Some("refuse") => @mooncat.EarlyData::Refuse
    Some("off") => @mooncat.EarlyData::Off
    _ => @mooncat.EarlyData::Accept
  }
  let config = @mooncat.Config::new(
    host="0.0.0.0",
    port~,
    early_data=early,
    logger=@mooncat.Logger::new(),
  )
  let transport = {
    ..@conn.Config::default(),
    retry: switched_on("MOONCAT_RETRY"),
  }
  let cert = match (setting("MOONCAT_CERT"), setting("MOONCAT_KEY")) {
    (Some(cert), Some(key)) =>
      @mooncat.TlsCert::pem(cert, key)
    _ => @mooncat.TlsCert::pem("src/certs/cert.pem", "src/certs/key.pem")
  }
  @quic.serve_config(app, config, cert, transport~)
}
