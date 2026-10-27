// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The TLS 1.3 pieces the whitebox tests build a peer's flight from: the ECDHE, the key schedule
// steps, CertificateVerify, and reading the extensions back. The server's own handshake is
// moonquic's, on moontls.
// These are the ones only the socket tests use.

///|
/// Both handshake traffic secrets from a ClientHello's key share: the server's
/// and the client's, in that order.
///
/// `None` when the ClientHello offers no x25519 share, which is the one case a
/// server has to answer with a HelloRetryRequest rather than a secret.
fn tls13_ecdhe_secrets_from_client_hello(
  client_hello : Bytes,
  server_private : Bytes,
  transcript_hash : Bytes,
) -> (Bytes, Bytes)? {
  match tls13_client_hello_x25519(client_hello) {
    Some(peer) =>
      Some(
        (
          tls13_ecdhe_handshake_traffic_secret(
            server_private, peer, transcript_hash, false,
          ),
          tls13_ecdhe_handshake_traffic_secret(
            server_private, peer, transcript_hash, true,
          ),
        ),
      )
    None => None
  }
}

///|
/// The group and key a ServerHello's `key_share` selected.
fn tls_server_hello_key_share(sh : @msg.Server) -> (Int32, Bytes)? {
  match @ext.find(sh.extensions[:], KeyShare) {
    Some(e) => @ext.read_selected_share(e.data[:])
    None => None
  }
}
