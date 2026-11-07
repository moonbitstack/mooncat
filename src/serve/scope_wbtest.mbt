// A request that arrived in 0-RTT reaches the application with three ways to say so: the header
// RFC 8470 names, an ASGI extension, and the `early_data` helper that reads the header. A request
// that did not is not marked at all.

///|
fn link_with(early~ : Bool) -> Link {
  { scheme: "https", bound: None, peer: None, tls: None, early, state: {}, }
}

///|
test "a request taken in 0-RTT reaches the application marked" {
  let config : @config.Config = @config.Config::new(
    logger=@config.Logger::silent(),
  )
  let scope = http_scope(link_with(early=true), config, "3", "GET", "/", [
    ("accept", "*/*"),
  ])
  assert_true(early_data(scope))
  guard scope is Http(http) else { fail("not an HTTP scope") }
  assert_eq(http.headers.any(h => h.0 == "early-data" && h.1 == "1"), true)
  assert_eq(
    http.extensions.custom.get("http.request.early_data") is Some(True),
    true,
  )
  // The headers the application sees are the ones it was given, plus that one.
  assert_eq(http.headers.length(), 2)
}

///|
test "a request the handshake carried is not marked" {
  let config : @config.Config = @config.Config::new(
    logger=@config.Logger::silent(),
  )
  let scope = http_scope(link_with(early=false), config, "3", "GET", "/", [
    ("accept", "*/*"),
  ])
  assert_false(early_data(scope))
  guard scope is Http(http) else { fail("not an HTTP scope") }
  assert_eq(http.headers.length(), 1)
  assert_eq(http.extensions.custom.get("http.request.early_data") is None, true)
}

///|
test "a proxy's Early-Data reaches the application too" {
  // RFC 8470 §5.1: the header is how a request forwarded in 0-RTT arrives, so an origin reads it
  // whether it took the request early itself or was told about it by the hop in front.
  let config : @config.Config = @config.Config::new(
    logger=@config.Logger::silent(),
  )
  let scope = http_scope(
    link_with(early=false),
    config,
    "1.1",
    "POST",
    "/pay",
    [("early-data", "1")],
  )
  assert_true(early_data(scope))
}

///|
test "425 Too Early has a reason phrase" {
  assert_eq(@config.reason(425), "Too Early")
}
