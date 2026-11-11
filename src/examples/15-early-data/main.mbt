// HTTP over 0-RTT: a request that reaches the server before its client's handshake has finished
// (RFC 8446 §4.2.10, RFC 8470). `GET /` says whether this request was one of those, and counts how
// many the process has answered; `MOONCAT_EARLY=refuse` makes the server answer `425 Too Early`
// instead, and `MOONCAT_EARLY=off` stops it offering early data at all.
//
//     MOONCAT_EARLY=accept moon run src/examples/15-early-data --target native
//
// Once a client has a ticket, its next request can travel with the handshake rather than after it.

///|
/// How many requests this process has answered, so a replay is visible as the same count twice.
let answered : Ref[Int32] = Ref(0)

///|
fn policy() -> @mooncat.EarlyData {
  match @env.get_env_var("MOONCAT_EARLY") {
    Some("accept") => Accept
    Some("refuse") => Refuse
    _ => Off
  }
}

///|
fn port() -> Int32 {
  match @env.get_env_var("MOONCAT_PORT") {
    Some(text) => @string.parse_int(text) catch { _ => 12000 }
    None => 12000
  }
}

///|
async fn app(
  scope : @moonasgi.Scope,
  _receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is Http(http) else { return }
  // An application that cannot be replayed asks this and answers 425 itself; one that can, says so
  // in its access log and carries on. The helper reads either the header this server added or the
  // one a proxy in front added, which is the same sentence one hop apart.
  let early = @mooncat.early_data(scope)
  answered.val = answered.val + 1
  let body = if http.path == "/count" {
    "\{answered.val}\n"
  } else {
    "early \{if early { 1 } else { 0 }} after \{answered.val}\n"
  }
  send(
    @moonasgi.Event::HttpResponseStart(
      status=200,
      headers=[("content-type", "text/plain"), ("cache-control", "no-store")],
      trailers=false,
    ),
  )
  send(
    @moonasgi.Event::HttpResponseBody(body=@utf8.encode(body), more_body=false),
  )
}

///|
async fn main {
  let config = @mooncat.Config::new(port=port(), early_data=policy())
  @quic.serve_config(
    app,
    config,
    @mooncat.TlsCert::pem("src/certs/cert.pem", "src/certs/key.pem"),
  )
}
