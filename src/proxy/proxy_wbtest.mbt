// `proxy_rewrite` (← uvicorn's `ProxyHeadersMiddleware`). The rule that matters is which peer is
// believed: these headers are attacker-controlled, so trusting the wrong one hands every client
// the ability to name its own address.

///|
/// The forwarding headers a proxy in front of the server would add.
fn forwarded() -> Map[String, String] {
  Map([
    ("x-forwarded-for", "203.0.113.7, 10.0.0.9"),
    ("x-forwarded-proto", "https"),
  ])
}

///|
/// The default `forwarded_allow_ips`: the loopback proxy and nothing else.
fn loopback() -> Array[String] {
  ["127.0.0.1"]
}

///|
test "proxy: a trusted peer's forwarded headers rewrite client and scheme" {
  let (client, scheme) = proxy_rewrite(
    forwarded(),
    Some(("127.0.0.1", 51234)),
    "http",
    trusted=loopback(),
  )
  // The chain's leftmost entry is the original client; a forwarded chain carries no port.
  assert_eq(client, Some(("203.0.113.7", 0)))
  assert_eq(scheme, "https")
}

///|
test "proxy: an untrusted peer's forwarded headers are ignored" {
  let peer = Some(("198.51.100.4", 51234))
  let (client, scheme) = proxy_rewrite(
    forwarded(),
    peer,
    "http",
    trusted=loopback(),
  )
  // Nothing moved: the peer is reported as itself and the scheme is the one the transport knows.
  assert_eq(client, peer)
  assert_eq(scheme, "http")
}

///|
/// A request whose peer is unknown has nothing to match against `forwarded_allow_ips`, so it is
/// not trusted. Defaulting the other way would make an unknown peer more privileged than a known
/// one — exactly backwards.
test "proxy: a request with no known peer is not trusted" {
  let (client, scheme) = proxy_rewrite(
    forwarded(),
    None,
    "http",
    trusted=loopback(),
  )
  assert_eq(client, None)
  assert_eq(scheme, "http")
}

///|
/// `"*"` trusts every peer. Only ever right when nothing but a proxy can reach the port.
test "proxy: the wildcard trusts any peer" {
  let (client, scheme) = proxy_rewrite(
    forwarded(),
    Some(("198.51.100.4", 9)),
    "http",
    trusted=["*"],
  )
  assert_eq(client, Some(("203.0.113.7", 0)))
  assert_eq(scheme, "https")
}

///|
/// A WebSocket scope's scheme is `ws`/`wss`, not `http`/`https`, so the forwarded protocol has to
/// be mapped rather than copied.
test "proxy: a websocket scope maps the forwarded protocol to ws/wss" {
  let (_c, secure) = proxy_rewrite(
    forwarded(),
    Some(("127.0.0.1", 1)),
    "ws",
    trusted=loopback(),
    websocket=true,
  )
  assert_eq(secure, "wss")
  let (_c2, plain) = proxy_rewrite(
    Map([("x-forwarded-proto", "http")]),
    Some(("127.0.0.1", 1)),
    "ws",
    trusted=loopback(),
    websocket=true,
  )
  assert_eq(plain, "ws")
}

///|
/// Each header stands alone: a proxy that forwards only one of the two leaves the other as the
/// transport reported it.
test "proxy: each forwarded header is applied on its own" {
  let peer = Some(("127.0.0.1", 7))
  let (only_for, scheme) = proxy_rewrite(
    Map([("x-forwarded-for", "203.0.113.7")]),
    peer,
    "http",
    trusted=loopback(),
  )
  assert_eq(only_for, Some(("203.0.113.7", 0)))
  assert_eq(scheme, "http")
  let (client, only_proto) = proxy_rewrite(
    Map([("x-forwarded-proto", " https ")]),
    peer,
    "http",
    trusted=loopback(),
  )
  assert_eq(client, peer)
  // The value is OWS-trimmed, as RFC 7230 §3.2 allows around any field value.
  assert_eq(only_proto, "https")
}

///|
/// An empty `X-Forwarded-For` names nobody, so the peer the transport reported stands.
test "proxy: an empty forwarded-for leaves the peer alone" {
  let peer = Some(("127.0.0.1", 7))
  let (client, _s) = proxy_rewrite(
    Map([("x-forwarded-for", "  ")]),
    peer,
    "http",
    trusted=loopback(),
  )
  assert_eq(client, peer)
}
