// The TLS 1.3 key_share extension (RFC 8446 §4.2.8) and the x25519 ECDHE agreement it carries.

///|
test "key_share: a KeyShareEntry serializes as group, length, key" {
  let key = qv_hexb(
    "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
  )
  let entry = tls_encode_key_share_entry(tls_group_x25519, key)
  // 001d (x25519) 0020 (32-byte key length) then the key.
  assert_eq(
    qv_hex(entry),
    "001d0020" +
    "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
  )
  match tls_decode_key_share_entry(entry[:]) {
    Some((group, k, consumed)) => {
      assert_eq(group, tls_group_x25519)
      assert_eq(k, key)
      assert_eq(consumed, entry.length())
    }
    None => abort("expected a KeyShareEntry")
  }
}

///|
test "key_share: ECDHE over the extension yields an agreed handshake secret" {
  // Two ephemeral x25519 key pairs (x25519 clamps the scalar, so any 32 bytes work).
  let a_priv = qv_hexb(
    "1111111111111111111111111111111111111111111111111111111111111111",
  )
  let b_priv = qv_hexb(
    "2222222222222222222222222222222222222222222222222222222222222222",
  )
  let a_pub = tls13_x25519_public(a_priv)
  let b_pub = tls13_x25519_public(b_priv)
  // The client offers its share in a ClientHello key_share; the server reads it back.
  let ch = tls_encode_key_share_client([(tls_group_x25519, a_pub)])
  let client_shares = tls_decode_key_share_client(ch[:])
  assert_eq(client_shares.length(), 1)
  assert_eq(client_shares[0].0, tls_group_x25519)
  assert_eq(client_shares[0].1, a_pub)
  // The server replies with its share in a ServerHello key_share; the client reads it back.
  let sh = tls_encode_key_share_server(tls_group_x25519, b_pub)
  let (group, peer_b_pub) = match tls_decode_key_share_server(sh[:]) {
    Some(v) => v
    None => abort("expected a ServerHello key_share")
  }
  assert_eq(group, tls_group_x25519)
  assert_eq(peer_b_pub, b_pub)
  // Each side computes the shared secret from its own private key and the peer's public key.
  let shared_client = x25519_raw(a_priv, peer_b_pub)
  let shared_server = x25519_raw(b_priv, client_shares[0].1)
  assert_eq(shared_client, shared_server)
  // And both derive the same Handshake Secret through the key schedule (RFC 8446 §7.1).
  let early = tls13_early_secret(Bytes::make(32, b'\x00'))
  assert_eq(
    tls13_handshake_secret(early, shared_client),
    tls13_handshake_secret(early, shared_server),
  )
}
