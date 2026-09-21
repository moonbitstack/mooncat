// Deriving the TLS 1.3 handshake-space keys from a real x25519 ECDHE exchange (RFC 8446
// §7.1). Once the ClientHello and ServerHello have carried the two ephemeral key_shares, each
// endpoint owns its private key and the peer's public key, and computes the same shared
// secret. That shared secret feeds the key schedule — Early Secret → Handshake Secret — and
// then the ClientHello..ServerHello transcript derives each side's handshake traffic secret,
// from which `quic_handshake_keys` makes the AEAD key/iv/hp. This is the glue that turns the
// key_share codec, x25519, and the key schedule into the handshake secret a real connection
// derives, instead of one passed in from a test vector.

///|
/// The x25519 ECDHE shared secret from an endpoint's private key and the peer's public key.
pub fn tls13_ecdhe_shared(private_key : Bytes, peer_public : Bytes) -> Bytes {
  x25519_raw(private_key, peer_public)
}

///|
/// The Handshake Secret for an x25519 ECDHE exchange with no PSK (RFC 8446 §7.1): the key
/// schedule extracts the shared secret under the Early Secret's derived salt.
pub fn tls13_handshake_secret_from_ecdhe(
  private_key : Bytes,
  peer_public : Bytes,
) -> Bytes {
  tls13_handshake_secret(
    tls13_early_secret(Bytes::make(32, b'\x00')),
    tls13_ecdhe_shared(private_key, peer_public),
  )
}

///|
/// An endpoint's handshake traffic secret from the ECDHE exchange and the ClientHello..
/// ServerHello transcript hash (RFC 8446 §7.1): the client secret when `is_client`, otherwise
/// the server secret. Both peers derive matching secrets because they share the same DHE.
pub fn tls13_ecdhe_handshake_traffic_secret(
  private_key : Bytes,
  peer_public : Bytes,
  transcript_hash : Bytes,
  is_client : Bool,
) -> Bytes {
  let handshake_secret = tls13_handshake_secret_from_ecdhe(
    private_key, peer_public,
  )
  if is_client {
    tls13_client_hs_traffic_secret(handshake_secret, transcript_hash)
  } else {
    tls13_server_hs_traffic_secret(handshake_secret, transcript_hash)
  }
}

///|
/// The client's offered x25519 public key from a ClientHello message: parse it and pull the
/// x25519 key_share. `None` if the message is not a ClientHello or offers no x25519 share.
fn tls13_client_hello_x25519(client_hello : Bytes) -> Bytes? {
  let (msg_type, body) = match tls_parse_handshake(client_hello[:]) {
    Some(v) => v
    None => return None
  }
  if msg_type != tls_client_hello {
    return None
  }
  let ch = match decode_client_hello(body[:]) {
    Some(v) => v
    None => return None
  }
  let mut client_public : Bytes? = None
  for share in tls_client_hello_key_shares(ch.extensions) {
    if share.0 == tls_group_x25519 {
      client_public = Some(share.1)
    }
  }
  client_public
}

///|
/// The server's handshake traffic secret derived from a received ClientHello message alone:
/// pull the client's x25519 key_share and run the ECDHE with the server's ephemeral
/// `server_private` over the ClientHello..ServerHello `transcript_hash`. `None` if the
/// message is not a ClientHello or offers no x25519 share.
pub fn tls13_server_hs_secret_from_client_hello(
  client_hello : Bytes,
  server_private : Bytes,
  transcript_hash : Bytes,
) -> Bytes? {
  match tls13_client_hello_x25519(client_hello) {
    Some(pub_key) =>
      Some(
        tls13_ecdhe_handshake_traffic_secret(
          server_private, pub_key, transcript_hash, false,
        ),
      )
    None => None
  }
}

///|
/// Both handshake traffic secrets a server derives from a received ClientHello and its own
/// ephemeral private key (RFC 8446 §7.1), as `(server_secret, client_secret)`: pull the
/// client's x25519 key_share, run the ECDHE with `server_private` over the ClientHello..
/// ServerHello `transcript_hash`, and derive each side's secret. `None` if the message is
/// not a ClientHello or offers no x25519 share. A server protects its own flight with the
/// server secret and verifies the client Finished with the client secret — deriving both
/// from the wire ClientHello, never from the peer's copy.
pub fn tls13_ecdhe_secrets_from_client_hello(
  client_hello : Bytes,
  server_private : Bytes,
  transcript_hash : Bytes,
) -> (Bytes, Bytes)? {
  match tls13_client_hello_x25519(client_hello) {
    Some(pub_key) =>
      Some(
        (
          tls13_ecdhe_handshake_traffic_secret(
            server_private, pub_key, transcript_hash, false,
          ),
          tls13_ecdhe_handshake_traffic_secret(
            server_private, pub_key, transcript_hash, true,
          ),
        ),
      )
    None => None
  }
}
