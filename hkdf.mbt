// TLS 1.3's key schedule (RFC 8446 §7.1), which QUIC reuses verbatim (RFC 9001
// §5.2). The HKDF underneath is `mooncrypt/kdf/hkdf`; what is here is the part
// that belongs to the protocol rather than to the primitive — the SHA-256 this
// cipher suite fixes, and the structured HkdfLabel the expansion runs under.

///|
/// The digest TLS 1.3 pairs with AES-128-GCM, bound once so the key schedule
/// does not name it on every line.
fn digest() -> &@spec.Hash {
  @sha2.Hasher::new()
}

///|
/// HKDF-Extract (RFC 5869 §2.2). An empty salt becomes `HashLen` zero bytes,
/// which is what the RFC says and what `mooncrypt` already does.
pub fn hkdf_extract(salt : Bytes, ikm : Bytes) -> Bytes {
  @hkdf.extract(ikm[:], digest, salt=salt[:])
}

///|
/// HKDF-Expand (RFC 5869 §2.3).
pub fn hkdf_expand(prk : Bytes, info : Bytes, length : Int) -> Bytes {
  @hkdf.expand(prk[:], digest, info=info[:], len=length)
}

///|
/// HKDF-Expand-Label (RFC 8446 §7.1): expand under the structured HkdfLabel
///
///   struct { uint16 length; opaque label<7..255>; opaque context<0..255>; }
///
/// where the label is prefixed with "tls13 ". QUIC reuses it unchanged, which is
/// why this sits here rather than in the KDF: the prefix and the framing are the
/// protocol's, not HKDF's.
pub fn hkdf_expand_label(
  secret : Bytes,
  label : Bytes,
  context : Bytes,
  length : Int,
) -> Bytes {
  let full = Buffer()
  full.write_bytes(b"tls13 "[:])
  full.write_bytes(label[:])
  let full_bytes = full.to_bytes()
  let hkdf_label = Buffer()
  hkdf_label.write_byte(((length >> 8) & 0xff).to_byte())
  hkdf_label.write_byte((length & 0xff).to_byte())
  hkdf_label.write_byte(full_bytes.length().to_byte())
  hkdf_label.write_bytes(full_bytes[:])
  hkdf_label.write_byte(context.length().to_byte())
  hkdf_label.write_bytes(context[:])
  hkdf_expand(secret, hkdf_label.to_bytes(), length)
}
