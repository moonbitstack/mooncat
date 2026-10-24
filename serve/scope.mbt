///|
/// What a connection knows about itself, carried to every scope made on it: the scheme it
/// arrived under, the two addresses, and its TLS facts when it is TLS.
priv struct Link {
  scheme : String
  bound : @socket.Addr?
  peer : @socket.Addr?
  tls : @moonasgi.TlsExtension?
  // The lifespan state, of which every scope gets a shallow copy (ASGI lifespan sub-spec).
  state : Map[String, Json]
}

///|
/// A connection in the clear with nothing known about either end.
fn Link::plain() -> Link {
  { scheme: "http", bound: None, peer: None, tls: None, state: {}, }
}

///|
/// The ASGI TLS extension for a connection: the version, the suite, and the certificate the
/// server presented, PEM as the extension asks.
fn tls_facts(conn : @tcp.Conn, chain : Array[Bytes]) -> @moonasgi.TlsExtension? {
  guard conn.tls() is Some(t) else { return None }
  Some({
    server_cert: if chain.length() > 0 {
      Some(pem(chain[0]))
    } else {
      None
    },
    client_cert_chain: [],
    client_cert_name: None,
    client_cert_error: None,
    tls_version: Some(0x0304),
    cipher_suite: t.suite().map(s => s.code()),
  })
}

///|
fn pem(der : Bytes) -> String {
  let text = @base64.encode(der[:])
  let out = StringBuilder()
  out.write_string("-----BEGIN CERTIFICATE-----\n")
  for i = 0; i < text.length(); i = i + 64 {
    let end = if i + 64 < text.length() { i + 64 } else { text.length() }
    out.write_string(text[i:end].to_owned())
    out.write_string("\n")
  }
  out.write_string("-----END CERTIFICATE-----\n")
  out.to_string()
}

///|
/// The extensions an HTTP scope here advertises: 103 Early Hints and response trailers, which
/// both versions honour, and the TLS facts on a TLS connection.
fn http_extensions(link : Link) -> @moonasgi.Extensions {
  let base = @moonasgi.Extensions::none().enable_early_hint().enable_trailers()
  match link.tls {
    Some(t) => base.with_tls(t)
    None => base
  }
}

///|
/// The extensions a WebSocket scope here advertises: the TLS facts on a TLS connection.
fn ws_extensions(link : Link) -> @moonasgi.Extensions {
  match link.tls {
    Some(t) => @moonasgi.Extensions::none().with_tls(t)
    None => @moonasgi.Extensions::none()
  }
}

///|
/// The client and the scheme a request is to be seen from: the connection's, or what trusted
/// proxy headers say (← uvicorn's `--proxy-headers`).
fn seen_from(
  link : Link,
  config : @config.Config,
  headers : Array[(String, String)],
  scheme : String,
  websocket~ : Bool = false,
) -> ((String, Int32)?, String) {
  let peer = link.peer.map(addr_pair)
  guard config.proxy_headers else { return (peer, scheme) }
  let map : Map[String, String] = Map([])
  for h in headers {
    map[h.0.to_lower()] = h.1
  }
  @proxy.proxy_rewrite(
    map,
    peer,
    scheme,
    trusted=config.forwarded_allow_ips,
    websocket~,
  )
}

///|
/// An HTTP scope, the same for HTTP/1.1 and HTTP/2: the query split off, the path
/// percent-decoded beside the raw one (a router must tell `%2F` from `/`), the client and
/// scheme as `seen_from` gives them, the root path, the addresses and the extensions.
fn http_scope(
  link : Link,
  config : @config.Config,
  version : String,
  verb : String,
  target : String,
  headers : Array[(String, String)],
) -> @moonasgi.Scope {
  let (raw_path, query) = split_query(target)
  let (client, scheme) = seen_from(link, config, headers, link.scheme)
  Http({
    http_version: version,
    http_method: verb,
    scheme,
    path: @utf8.decode_lossy(percent_decode(raw_path)),
    raw_path: @utf8.encode(raw_path),
    query_string: @utf8.encode(query),
    root_path: config.root_path,
    headers,
    client,
    server: server_pair(link.bound),
    asgi: @moonasgi.AsgiVersion::http(),
    extensions: http_extensions(link),
    state: link.state.copy(),
  })
}
