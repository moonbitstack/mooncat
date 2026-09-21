// The TLS 1.3 handshake transcript hash (RFC 8446 §4.4.1) and the Finished verify_data
// (§4.4.4). A handshake progresses by feeding each message into a running hash; at the
// points a Finished is sent or checked, verify_data is HMAC(finished_key, transcript
// hash), where finished_key is derived from the sender's traffic secret. This is the
// accumulator and MAC the handshake driver keeps as it advances through the messages.

///|
/// A running transcript hash over the handshake messages seen so far.
pub struct TranscriptHash {
  messages : Buffer
}

///|
/// A fresh, empty transcript.
pub fn TranscriptHash::new() -> TranscriptHash {
  { messages: Buffer(), }
}

///|
/// Append a handshake message (its full `HandshakeType + Length + body` encoding) to the
/// transcript.
pub fn TranscriptHash::add(self : TranscriptHash, message : Bytes) -> Unit {
  self.messages.write_bytes(message)
}

///|
/// The SHA-256 transcript hash over every message added so far (RFC 8446 §4.4.1).
pub fn TranscriptHash::hash(self : TranscriptHash) -> Bytes {
  @sha2.hash(self.messages.to_bytes()[:])
}

///|
/// The Finished verify_data (RFC 8446 §4.4.4): `HMAC(finished_key, transcript_hash)`,
/// where `finished_key` is `HKDF-Expand-Label(base_key, "finished", "", Hash.length)`
/// over the sender's handshake traffic secret.
pub fn tls13_finished_verify_data(
  base_key : Bytes,
  transcript_hash : Bytes,
) -> Bytes {
  hmac256(tls13_finished_key(base_key), transcript_hash)
}

///|
/// Whether a received Finished's `verify_data` is the one expected for `base_key` over
/// `transcript_hash` — a constant set membership, the handshake authentication check.
pub fn tls13_finished_verify(
  base_key : Bytes,
  transcript_hash : Bytes,
  verify_data : Bytes,
) -> Bool {
  tls13_finished_verify_data(base_key, transcript_hash) == verify_data
}
