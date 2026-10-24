// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The TLS 1.3 pieces the whitebox tests build a peer's flight from: the ECDHE, the key schedule
// steps, CertificateVerify, and reading the extensions back. The server's own handshake is
// moonquic's, on moontls.

///|
/// A P-256 private key from the hex of its scalar.
///
/// Hex is what a fixture and an example carry. A key from a file is PEM or DER,
/// which is `mooncrypt/key`'s to read when that package lands; until then a
/// deployment reads its own file and hands the scalar in.
fn ec_private(scalar : String) -> @ecdsa.PrivateKey {
  @ecdsa.PrivateKey::new(@base16.decode_lossy(scalar)[:], curve=P256) catch {
    _ => abort("mooncat: not a P-256 scalar")
  }
}

///|
/// X25519, the group TLS 1.3 offers first.
///
/// A low-order peer share makes the shared secret all zeroes, which `mooncrypt`
/// refuses; here that becomes an empty answer, because the handshake's response
/// to it is an alert rather than a crash.
fn x25519_raw(scalar : Bytes, point : Bytes) -> Bytes {
  @x25519.shared(scalar[:], point[:]) catch {
    _ => b""
  }
}

///|
/// The other direction. It answers `Bool` and never raises: a bad signature is
/// an expected answer, not an exceptional one.
fn ecdsa_verify(msg : Bytes, sig : Bytes, key : @ecdsa.PublicKey) -> Bool {
  key.verify(msg[:], sig[:])
}

///|
/// The ephemeral x25519 public key for a private scalar (RFC 7748 §5).
fn tls13_x25519_public(private_key : Bytes) -> Bytes {
  x25519_raw(private_key, @x25519.base)
}

///|
/// The x25519 shared secret with a peer's public key.
///
/// A low-order peer share makes the secret all zeroes, which `mooncrypt`
/// refuses; here that becomes an empty answer, because the handshake's response
/// to it is an alert rather than a crash.
fn tls13_ecdhe_shared(private_key : Bytes, peer_public : Bytes) -> Bytes {
  x25519_raw(private_key, peer_public)
}

///|
/// The Handshake Secret from our scalar and the peer's key share: run the ECDHE,
/// then RFC 8446 §7.1's ladder.
fn tls13_handshake_secret_from_ecdhe(
  private_key : Bytes,
  peer_public : Bytes,
) -> Bytes {
  let shared = tls13_ecdhe_shared(private_key, peer_public)
  @keys.handshake(@keys.early()[:], shared[:])
}

///|
/// A server's handshake traffic secret from the ClientHello it received: pull
/// the client's x25519 `key_share` and run the ECDHE with `server_private` over
/// the ClientHello..ServerHello transcript.
///
/// `None` if the message is not a ClientHello or offers no x25519 share — the
/// case a server answers with a HelloRetryRequest rather than a secret.
fn tls13_server_hs_secret_from_client_hello(
  client_hello : Bytes,
  server_private : Bytes,
  transcript_hash : Bytes,
) -> Bytes? {
  match tls13_client_hello_x25519(client_hello) {
    Some(peer) =>
      Some(
        tls13_ecdhe_handshake_traffic_secret(
          server_private, peer, transcript_hash, false,
        ),
      )
    None => None
  }
}

///|
/// Check a CertificateVerify body against the peer's ES256 public key.
///
/// False on a scheme this server does not verify, a malformed body, or a
/// signature that does not check out — one answer for every way of being wrong,
/// because which way it was wrong is not the peer's business.
fn tls13_certificate_verify_check(
  key : @ecdsa.PublicKey,
  context : String,
  transcript_hash : Bytes,
  body : Bytes,
) -> Bool {
  guard @msg.read_certificate_verify(body[:]) is Some((scheme, signature)) else {
    return false
  }
  if scheme != @ext.ecdsa_secp256r1_sha256 {
    return false
  }
  ecdsa_verify(@msg.signed(context, transcript_hash[:]), signature, key)
}

///|
/// A QUIC server's EncryptedExtensions body: the negotiated ALPN protocol and
/// the server's transport parameters.
///
/// RFC 9001 §8.2 makes `quic_transport_parameters` mandatory for a QUIC server,
/// and the parameters themselves are QUIC's — `moontls` carries the extension
/// without reading it, so encoding them is this side's job.
fn tls13_quic_encrypted_extensions(
  alpn : String,
  params : Array[@conn.Param],
) -> Bytes {
  let alpn_ext : @ext.Ext = { kind: Alpn, data: @ext.protocols([alpn][:]), }
  let quic_ext : @ext.Ext = {
    kind: QuicTransportParameters,
    data: @conn.encode(params),
  }
  @msg.encrypted_extensions([alpn_ext, quic_ext][:])
}

///|
/// The QUIC transport parameters an extension list carries, in order.
///
/// Empty when the extension is absent or its block is truncated: a QUIC
/// endpoint treats a missing block as no parameters and falls back to the
/// defaults RFC 9000 §18.2 gives.
fn tls_hello_quic_transport_params(
  extensions : Array[@ext.Ext],
) -> Array[@conn.Param] {
  match @ext.find(extensions[:], QuicTransportParameters) {
    Some(e) =>
      match @conn.decode(e.data[:]) {
        Some(params) => params
        None => []
      }
    None => []
  }
}

///|
/// A handshake traffic secret straight from an ECDHE exchange and a transcript.
///
/// `is_client` picks which side's secret: the two are derived from the same
/// handshake secret under different labels (RFC 8446 §7.1), so one call serves
/// both ends of a test and both ends of a connection.
fn tls13_ecdhe_handshake_traffic_secret(
  private_key : Bytes,
  peer_public : Bytes,
  transcript_hash : Bytes,
  is_client : Bool,
) -> Bytes {
  let handshake = tls13_handshake_secret_from_ecdhe(private_key, peer_public)
  if is_client {
    @keys.client_handshake(handshake[:], transcript_hash[:])
  } else {
    @keys.server_handshake(handshake[:], transcript_hash[:])
  }
}

///|
/// The x25519 public key a ClientHello's `key_share` offers, or `None` when it
/// carries none for that group.
fn tls13_client_hello_x25519(client_hello : Bytes) -> Bytes? {
  guard @msg.unframe(client_hello[:]) is Some((kind, body)) else { return None }
  if kind != ClientHello {
    return None
  }
  guard @msg.read_hello(body[:]) is Some(ch) else { return None }
  guard @ext.find(ch.extensions[:], KeyShare) is Some(e) else { return None }
  for share in @ext.read_shares(e.data[:]) {
    if share.0 == @ext.x25519 {
      return Some(share.1)
    }
  }
  None
}

///|
/// The single ALPN protocol a server's extension list selected, or `None`.
fn tls_selected_alpn(extensions : Array[@ext.Ext]) -> String? {
  match @ext.find(extensions[:], Alpn) {
    Some(e) => {
      let names = @ext.read_protocols(e.data[:])
      if names.length() == 1 {
        Some(names[0])
      } else {
        None
      }
    }
    None => None
  }
}
