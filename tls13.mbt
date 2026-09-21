// TLS 1.3 key schedule (RFC 8446 §7.1). QUIC reuses TLS 1.3's secrets wholesale
// (RFC 9001), so the same ladder that keys a TLS record layer keys QUIC packet
// protection. Every step is HKDF-Extract or the Derive-Secret wrapper over
// HKDF-Expand-Label, both already self-built.

///|
/// The transcript hash over a run of handshake messages (RFC 8446 §4.4.1): here the
/// SHA-256 of their concatenation.
pub fn tls13_transcript_hash(messages : Bytes) -> Bytes {
  @sha2.hash(messages[:])
}

///|
/// Derive-Secret(Secret, Label, Messages) (RFC 8446 §7.1): HKDF-Expand-Label with the
/// transcript hash as context and the hash length as output. `transcript_hash` is the
/// Transcript-Hash of the messages (use `tls13_transcript_hash`, or the empty-string
/// hash for the "derived" steps).
pub fn tls13_derive_secret(
  secret : Bytes,
  label : Bytes,
  transcript_hash : Bytes,
) -> Bytes {
  hkdf_expand_label(secret, label, transcript_hash, 32)
}

///|
/// The Early Secret: HKDF-Extract(0, PSK), with an all-zero PSK when none is used.
pub fn tls13_early_secret(psk : Bytes) -> Bytes {
  hkdf_extract(Bytes::make(32, b'\x00'), psk)
}

///|
/// The Handshake Secret: HKDF-Extract over the ECDHE shared secret, salted by the
/// Early Secret run through the "derived" step (RFC 8446 §7.1).
pub fn tls13_handshake_secret(early_secret : Bytes, ecdhe : Bytes) -> Bytes {
  let derived = tls13_derive_secret(early_secret, b"derived", sha256(b""))
  hkdf_extract(derived, ecdhe)
}

///|
/// The Master Secret: HKDF-Extract over an all-zero IKM, salted by the Handshake
/// Secret run through the "derived" step (RFC 8446 §7.1).
pub fn tls13_master_secret(handshake_secret : Bytes) -> Bytes {
  let derived = tls13_derive_secret(handshake_secret, b"derived", sha256(b""))
  hkdf_extract(derived, Bytes::make(32, b'\x00'))
}

///|
/// A Finished key: HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
/// (RFC 8446 §4.4.4), the key that MACs the Finished message's verify_data.
pub fn tls13_finished_key(base_key : Bytes) -> Bytes {
  hkdf_expand_label(base_key, b"finished", b"", 32)
}
