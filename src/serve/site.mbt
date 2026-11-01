// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What a listener beside the TCP one needs from the server it runs in. HTTP/3 is the case: UDP on
// the same port, in a package of its own so that a server without it does not carry QUIC, but the
// same lifespan, the same scopes, the same limits and the same shutdown as the rest.

///|
/// The serving process, as a listener beside the TCP one sees it.
pub struct Site {
  priv config : @config.Config
  priv bound : @socket.Addr
  priv load : Load
  priv state : Map[String, Json]
}

///|
pub fn Site::config(self : Site) -> @config.Config {
  self.config
}

///|
/// The address the server listens on.
pub fn Site::bound(self : Site) -> @socket.Addr {
  self.bound
}

///|
/// Whether the server is shutting down, which is when a listener stops taking new work and lets
/// what is running finish.
pub fn Site::stopping(self : Site) -> Bool {
  self.load.stopping
}

///|
/// Take a new request, or refuse it past `limit_concurrency`. Every request taken is given back
/// with `finished`, which is what shutdown waits for.
pub fn Site::admit(self : Site) -> Bool {
  guard !self.load.busy(self.config.limit_concurrency) else {
    self.config.logger.log(
      @moonlog.warn, "Exceeded concurrency limit, refusing with 503",
    )
    return false
  }
  self.load.requests += 1
  true
}

///|
/// A request taken with `admit` is over.
pub async fn Site::finished(self : Site) -> Unit {
  self.load.requests -= 1
  self.load.count(self.config) |> ignore
}

///|
/// The ASGI scope for a request head (RFC 9110 §7) that arrived from `peer` under TLS on HTTP
/// version `version`, with `suite` naming its cipher.
pub fn Site::scope(
  self : Site,
  fields : Array[@header.Header],
  version~ : String,
  peer~ : @socket.Addr,
  suite~ : Int32,
) -> @moonasgi.Scope {
  let link : Link = {
    scheme: "https",
    bound: Some(self.bound),
    peer: Some(peer),
    tls: Some({
      server_cert: None,
      client_cert_chain: [],
      client_cert_name: None,
      client_cert_error: None,
      tls_version: Some(0x0304),
      cipher_suite: Some(suite),
    }),
    state: self.state,
  }
  field_scope(fields, link, self.config, version)
}

///|
/// A response head as a field section: `:status`, the application's fields that may cross, and the
/// configured server fields.
pub fn Site::head(
  self : Site,
  status : Int32,
  headers : Array[(String, String)],
) -> Array[@header.Header] {
  h2_response_headers(status, headers, self.config)
}

///|
/// The method and target of a request head, for the access log.
pub fn request_of(fields : Array[@header.Header]) -> (String, String) {
  request_line(fields)
}
