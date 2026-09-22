// Forwarded-header handling (← uvicorn's `ProxyHeadersMiddleware`, which uvicorn installs by
// default). Native-only because it leans on the request-head helpers (`ascii_trim`, `index_of`)
// that live with the HTTP/1.1 codec, and because nothing but the server paths ever calls it.

///|
/// Whether a peer's forwarding headers are believed: its host appears in `trusted`, or `trusted`
/// holds the wildcard `"*"`. A request with no known peer is never trusted — there is nothing to
/// match, and defaulting to trust would make an unknown peer more privileged than a known one.
fn is_trusted_proxy(client : (String, Int)?, trusted : Array[String]) -> Bool {
  let host = match client {
    Some((h, _)) => h
    None => ""
  }
  for t in trusted {
    if t == "*" || (host != "" && t == host) {
      return true
    }
  }
  false
}

///|
/// The leftmost entry of an `X-Forwarded-For` chain — the original client. Each hop appends its
/// own peer to the right, so the left end is the address furthest from this server.
fn first_forwarded(raw : String) -> String {
  let head = match raw.find(",") {
    Some(comma) => raw[0:comma].to_owned()
    None => raw
  }
  ascii_trim(head)
}

///|
/// Rewrite a request's `client` and `scheme` from a trusted proxy's forwarding headers
/// (← uvicorn's `ProxyHeadersMiddleware`).
///
/// Nothing is rewritten unless the peer itself is trusted: these headers are attacker-controlled,
/// and believing them from an arbitrary client lets that client name any address it likes for a
/// rate limiter, an allowlist or an audit log. Behind a proxy the peer is the proxy, which is why
/// `forwarded_allow_ips` defaults to `127.0.0.1` and not to `*`.
///
/// `X-Forwarded-For` yields the chain's leftmost entry with port `0`, since a forwarded chain
/// carries no port. `X-Forwarded-Proto` replaces the scheme, mapped to `wss`/`ws` for a WebSocket
/// scope, whose scheme names differ from the `https`/`http` the header spells.
pub fn proxy_rewrite(
  headers : Map[String, String],
  client : (String, Int)?,
  scheme : String,
  trusted~ : Array[String],
  websocket? : Bool = false,
) -> ((String, Int)?, String) {
  guard is_trusted_proxy(client, trusted) else { return (client, scheme) }
  let rewritten = match headers.get("x-forwarded-for") {
    Some(raw) => {
      let first = first_forwarded(raw)
      if first.length() > 0 {
        Some((first, 0))
      } else {
        client
      }
    }
    None => client
  }
  let proto = match headers.get("x-forwarded-proto") {
    Some(raw) => {
      let p = ascii_trim(raw)
      if websocket {
        if p == "https" || p == "wss" {
          "wss"
        } else {
          "ws"
        }
      } else {
        p
      }
    }
    None => scheme
  }
  (rewritten, proto)
}
