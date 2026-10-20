// The algorithms this server uses, bound to the choices TLS 1.3 and QUIC make.
//
// Nothing is implemented here. Every line hands off to `mooncrypt`; what this
// file carries is the binding — AES-128-GCM with SHA-256, P-256 with SHA-256,
// X25519 — so the protocol code names an operation rather than restating the
// suite on every call.

///|
/// A P-256 private key from the hex of its scalar.
///
/// Hex is what a fixture and an example carry. A key from a file is PEM or DER,
/// which is `mooncrypt/key`'s to read when that package lands; until then a
/// deployment reads its own file and hands the scalar in.
pub fn ec_private(scalar : String) -> @ecdsa.PrivateKey {
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
/// ECDSA over P-256 with SHA-256, which is what `ecdsa-with-SHA256` names in a
/// certificate and what CertificateVerify signs with.
fn ecdsa_sign(msg : Bytes, key : @ecdsa.PrivateKey) -> Bytes {
  key.sign(msg[:])
}

///|
/// The other direction. It answers `Bool` and never raises: a bad signature is
/// an expected answer, not an exceptional one.
fn ecdsa_verify(msg : Bytes, sig : Bytes, key : @ecdsa.PublicKey) -> Bool {
  key.verify(msg[:], sig[:])
}
