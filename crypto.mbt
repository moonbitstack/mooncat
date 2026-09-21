// The algorithms this server uses, bound to the choices TLS 1.3 and QUIC make.
//
// Nothing is implemented here. Every line hands off to `mooncrypt`; what this
// file carries is the binding — AES-128-GCM with SHA-256, P-256 with SHA-256,
// X25519 — so the protocol code names an operation rather than restating the
// suite on every call.

///|
/// SHA-256 over a whole message — the digest TLS 1.3 and QUIC fix alongside
/// AES-128-GCM, named here so the protocol code does not restate the suite.
fn sha256(msg : Bytes) -> Bytes {
  @sha2.hash(msg[:])
}

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
/// HMAC-SHA256, the MAC the TLS 1.3 key schedule runs on.
fn hmac256(key : Bytes, msg : Bytes) -> Bytes {
  @hmac.mac(key[:], msg[:], digest)
}

///|
/// An expanded AES-128 key.
///
/// The key is always 16 bytes here: TLS 1.3 and QUIC both name AES-128-GCM, and
/// header protection samples a block under the same cipher. A key of another
/// length is a mistake in the program rather than something a peer can cause.
fn aes_key(key : Bytes) -> @aes.Cipher {
  @aes.Cipher::new(key[:]) catch {
    _ => abort("mooncat: a \{key.length()}-byte AES key is not AES-128")
  }
}

///|
/// One block under an expanded key — QUIC header protection samples exactly one
/// (RFC 9001 §5.4.3).
fn aes_block(cipher : @aes.Cipher, block : Bytes) -> Bytes {
  cipher.encrypt(block[:])
}

///|
/// AEAD_AES_128_GCM seal: the packet protection of RFC 9001 §5.3, and the record
/// protection of RFC 8446 §5.2.
fn gcm_seal(key : Bytes, nonce : Bytes, plain : Bytes, aad : Bytes) -> Bytes {
  aead(key).seal(nonce=nonce[:], plain=plain[:], aad=aad[:])
}

///|
/// The same, opened.
///
/// It answers `None` rather than raising because every caller here is reading
/// from the wire, where a tag that does not match is an ordinary event — a
/// corrupted datagram, a packet for a key that has been retired — and not an
/// exception.
fn gcm_open(key : Bytes, nonce : Bytes, packet : Bytes, aad : Bytes) -> Bytes? {
  Some(aead(key).open(nonce=nonce[:], cipher=packet[:], aad=aad[:])) catch {
    _ => None
  }
}

///|
fn aead(key : Bytes) -> @gcm.Gcm {
  @gcm.Gcm::new(aes_key(key)) catch {
    _ => abort("mooncat: AES-128-GCM refused a 16-byte key")
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
