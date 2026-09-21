// QUIC Retry packet integrity (RFC 9001 §5.8). A Retry carries a 16-byte tag that
// binds it to the original Destination Connection ID, computed with AEAD_AES_128_GCM
// under a version-fixed key and nonce over a pseudo-packet — the same GCM the payload
// AEAD uses, here with an empty plaintext so the output is the tag alone.

///|
/// The version-1 Retry integrity key and nonce (RFC 9001 §5.8).
let quic_v1_retry_key : Bytes = b"\xbe\x0c\x69\x0b\x9f\x66\x57\x5a\x1d\x76\x6b\x54\xe3\x68\xc8\x4e"

///|
let quic_v1_retry_nonce : Bytes = b"\x46\x15\x99\xd3\x5d\x63\x2b\xf2\x23\x98\x25\xbb"

///|
/// The Retry integrity tag for a Retry packet (everything up to but not including the
/// tag) given the original Destination Connection ID. The AEAD associated data is the
/// Retry Pseudo-Packet: the ODCID length byte, the ODCID, then the Retry packet.
pub fn quic_retry_integrity_tag(
  retry_without_tag : Bytes,
  odcid : Bytes,
) -> Bytes {
  let pseudo = Buffer()
  pseudo.write_byte(odcid.length().to_byte())
  pseudo.write_bytes(odcid[:])
  pseudo.write_bytes(retry_without_tag[:])
  // Empty plaintext: seal returns ciphertext||tag with no ciphertext, i.e. the tag.
  gcm_seal(quic_v1_retry_key, quic_v1_retry_nonce, b"", pseudo.to_bytes())
}

///|
/// Verify a full Retry packet (ending in its 16-byte integrity tag): recompute the
/// tag over the leading bytes and compare, accumulating the difference so the check
/// does not exit early on the first mismatched byte.
pub fn quic_retry_verify(retry_packet : Bytes, odcid : Bytes) -> Bool {
  if retry_packet.length() < 16 {
    return false
  }
  let body_len = retry_packet.length() - 16
  let body = retry_packet[0:body_len].to_owned()
  let tag = quic_retry_integrity_tag(body, odcid)
  let mut diff = 0
  for i = 0; i < 16; i = i + 1 {
    diff = diff | (tag[i].to_int() ^ retry_packet[body_len + i].to_int())
  }
  diff == 0
}
