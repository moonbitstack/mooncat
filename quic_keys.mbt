// QUIC key update (RFC 9001 §6.1): once the 1-RTT keys are in use, an endpoint can roll
// them by deriving the next generation's traffic secret from the current one with the
// "quic ku" label, then re-deriving the AEAD key/iv/hp from it. The Key Phase bit in the
// short header signals which generation protects a packet. The per-secret key derivation
// itself is `quic_packet_keys`, shared with the Initial and handshake keys.

///|
/// The next-generation 1-RTT traffic secret, `HKDF-Expand-Label(secret, "quic ku", "",
/// Hash.length)` (RFC 9001 §6.1). Applying it again advances another generation.
pub fn quic_key_update(secret : Bytes) -> Bytes {
  @keys.expand_label(secret[:], b"quic ku"[:], b""[:], len=32)
}

///|
/// Roll to the next key generation: the updated traffic secret and the AEAD key/iv/hp
/// derived from it.
pub fn quic_next_keys(secret : Bytes) -> (Bytes, QuicPacketKeys) {
  let next = quic_key_update(secret)
  (next, quic_packet_keys(next))
}
