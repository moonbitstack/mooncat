// The key_share extension carried through a real TLS 1.3 ServerHello message (RFC 8446
// §4.1.3, §4.2.8): the server publishes its ephemeral x25519 share in the ServerHello's
// extensions, and the client extracts it after decoding the message to derive the shared
// secret.

///|
test "hello key_share: a ServerHello carries the server's x25519 share through the message" {
  let server_priv = qv_hexb(
    "3333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_pub = tls13_x25519_public(server_priv)
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\x11'),
    session_id: b"",
    cipher_suite: 0x1301,
    extensions: [tls_key_share_extension(tls_group_x25519, server_pub)],
  }
  // Encode the ServerHello as a full handshake message and parse it back.
  let wire = encode_server_hello(sh)
  let (msg_type, body) = match tls_parse_handshake(wire[:]) {
    Some(v) => v
    None => abort("expected a handshake message")
  }
  assert_eq(msg_type, 2) // ServerHello
  let decoded = match decode_server_hello(body[:]) {
    Some(v) => v
    None => abort("expected a ServerHello")
  }
  // The client extracts the server's key_share from the decoded ServerHello.
  let (group, extracted) = match tls_server_hello_key_share(decoded) {
    Some(v) => v
    None => abort("ServerHello had no key_share extension")
  }
  assert_eq(group, tls_group_x25519)
  assert_eq(extracted, server_pub)
  // Using the extracted key, the client and server compute the same shared secret.
  let client_priv = qv_hexb(
    "4444444444444444444444444444444444444444444444444444444444444444",
  )
  let shared_client = x25519_raw(client_priv, extracted)
  let shared_server = x25519_raw(server_priv, tls13_x25519_public(client_priv))
  assert_eq(shared_client, shared_server)
}
