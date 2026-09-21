// Deriving the handshake-space keys from a real x25519 ECDHE carried by the ClientHello and
// ServerHello key_shares (RFC 8446 §7.1).

///|
test "ECDHE: peers agree on the handshake traffic secrets via their hello key_shares" {
  // Two ephemeral x25519 key pairs.
  let client_priv = qv_hexb(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_priv = qv_hexb(
    "6666666666666666666666666666666666666666666666666666666666666666",
  )
  let client_pub = tls13_x25519_public(client_priv)
  let server_pub = tls13_x25519_public(server_priv)
  // Real hello messages carry the shares: the ClientHello a client_shares list, the
  // ServerHello a single entry.
  let ch = TlsClientHello::{
    random: Bytes::make(32, b'\x23'),
    session_id: b"heke1228",
    cipher_suites: [0x1301],
    extensions: [
      {
        ext_type: tls_ext_key_share,
        data: tls_encode_key_share_client([(tls_group_x25519, client_pub)]),
      },
    ],
  }
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\x66'),
    session_id: b"heke1228",
    cipher_suite: 0x1301,
    extensions: [tls_key_share_extension(tls_group_x25519, server_pub)],
  }
  let transcript = bytes_concat(
    encode_client_hello(ch),
    encode_server_hello(sh),
  )
  let th = @sha2.hash(transcript[:])
  // Each peer extracts the other's key_share from the decoded hello messages.
  let peer_client_pub = tls_client_hello_key_shares(ch.extensions)[0].1
  let peer_server_pub = match tls_server_hello_key_share(sh) {
    Some(v) => v.1
    None => abort("ServerHello had no key_share")
  }
  // Server side (its private + the client's public) and client side (its private + the
  // server's public) derive the same server handshake traffic secret.
  assert_eq(
    tls13_ecdhe_handshake_traffic_secret(
      server_priv, peer_client_pub, th, false,
    ),
    tls13_ecdhe_handshake_traffic_secret(
      client_priv, peer_server_pub, th, false,
    ),
  )
  // And the same client handshake traffic secret.
  assert_eq(
    tls13_ecdhe_handshake_traffic_secret(server_priv, peer_client_pub, th, true),
    tls13_ecdhe_handshake_traffic_secret(client_priv, peer_server_pub, th, true),
  )
  // The server can derive its handshake secret from the received ClientHello message alone.
  let server_from_ch = match
    tls13_server_hs_secret_from_client_hello(
      encode_client_hello(ch),
      server_priv,
      th,
    ) {
    Some(v) => v
    None => abort("server could not derive from the ClientHello")
  }
  assert_eq(
    server_from_ch,
    tls13_ecdhe_handshake_traffic_secret(
      client_priv, peer_server_pub, th, false,
    ),
  )
}
