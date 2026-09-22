// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What is left of TLS here, now that the protocol is `moontls`.
//
// Two things a protocol library will not do, because doing them would mean
// holding a key or choosing an algorithm:
//
//   * the ECDHE that turns a peer's key share into a handshake secret, which
//     joins `mooncrypt`'s x25519 to `moontls`' key schedule;
//   * signing and checking a CertificateVerify, which joins `mooncrypt`'s
//     ECDSA to the signed content `moontls` frames.
//
// Both are this server's business: it is the one with the key.

///|
/// The ephemeral x25519 public key for a private scalar (RFC 7748 §5).
pub fn tls13_x25519_public(private_key : Bytes) -> Bytes {
  x25519_raw(private_key, @x25519.base)
}

///|
/// The x25519 shared secret with a peer's public key.
///
/// A low-order peer share makes the secret all zeroes, which `mooncrypt`
/// refuses; here that becomes an empty answer, because the handshake's response
/// to it is an alert rather than a crash.
pub fn tls13_ecdhe_shared(private_key : Bytes, peer_public : Bytes) -> Bytes {
  x25519_raw(private_key, peer_public)
}

///|
/// The Handshake Secret from our scalar and the peer's key share: run the ECDHE,
/// then RFC 8446 §7.1's ladder.
pub fn tls13_handshake_secret_from_ecdhe(
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
pub fn tls13_server_hs_secret_from_client_hello(
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
/// Sign a CertificateVerify over the transcript with an ES256 key
/// (RFC 8446 §4.4.3): the message body, its scheme and signature framed by
/// `moontls`, over the signed content `moontls` builds.
pub fn tls13_certificate_verify_sign(
  key : @ecdsa.PrivateKey,
  context : String,
  transcript_hash : Bytes,
) -> Bytes {
  let signature = ecdsa_sign(@msg.signed(context, transcript_hash[:]), key)
  @msg.certificate_verify(signature[:], @ext.ecdsa_secp256r1_sha256)
}

///|
/// Check a CertificateVerify body against the peer's ES256 public key.
///
/// False on a scheme this server does not verify, a malformed body, or a
/// signature that does not check out — one answer for every way of being wrong,
/// because which way it was wrong is not the peer's business.
pub fn tls13_certificate_verify_check(
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
pub fn tls13_quic_encrypted_extensions(
  alpn : String,
  params : Array[TransportParam],
) -> Bytes {
  let alpn_ext : @ext.Ext = { kind: Alpn, data: @ext.protocols([alpn][:]), }
  let quic_ext : @ext.Ext = {
    kind: QuicTransportParameters,
    data: encode_transport_params(params),
  }
  @msg.encrypted_extensions([alpn_ext, quic_ext][:])
}

///|
/// The QUIC transport parameters an extension list carries, in order.
///
/// Empty when the extension is absent or its block is truncated: a QUIC
/// endpoint treats a missing block as no parameters and falls back to the
/// defaults RFC 9000 §18.2 gives.
pub fn tls_hello_quic_transport_params(
  extensions : Array[@ext.Ext],
) -> Array[TransportParam] {
  match @ext.find(extensions[:], QuicTransportParameters) {
    Some(e) =>
      match decode_transport_params(e.data[:]) {
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
pub fn tls13_ecdhe_handshake_traffic_secret(
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
pub fn tls13_client_hello_x25519(client_hello : Bytes) -> Bytes? {
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
/// Both handshake traffic secrets from a ClientHello's key share: the server's
/// and the client's, in that order.
///
/// `None` when the ClientHello offers no x25519 share, which is the one case a
/// server has to answer with a HelloRetryRequest rather than a secret.
pub fn tls13_ecdhe_secrets_from_client_hello(
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
pub fn tls_server_hello_key_share(sh : @msg.Server) -> (Int, Bytes)? {
  match @ext.find(sh.extensions[:], KeyShare) {
    Some(e) => @ext.read_selected_share(e.data[:])
    None => None
  }
}

///|
/// The single ALPN protocol a server's extension list selected, or `None`.
pub fn tls_selected_alpn(extensions : Array[@ext.Ext]) -> String? {
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
