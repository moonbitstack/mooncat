// QUIC Handshake packet protection (RFC 9000 §17.2.4 long header + RFC 9001 §5.3–§5.4).
// A Handshake packet is a long-header packet like Initial but with the Handshake type
// bits (0b10) and no Token field; it carries the server's second flight (EncryptedExtensions,
// Certificate, CertificateVerify, Finished) and the client's Finished in CRYPTO frames,
// protected with the handshake traffic keys. The AEAD sealing and header protection are
// the same as Initial (quic_nonce / aes128_gcm / quic_header_protect are shared), so only
// the header layout differs — this file is the Handshake-space counterpart of the Initial
// packet path.

///|
/// Build a Handshake long header (RFC 9000 §17.2.4): the first byte carries the header
/// form, fixed bit, Handshake type (0b10), and the two-bit packet-number length; there is
/// no Token field. `sealed_len` is the packet-number length plus the sealed payload.
fn quic_handshake_header(
  version : UInt,
  dcid : Bytes,
  scid : Bytes,
  packet_number : Int64,
  pn_length : Int,
  sealed_len : Int,
) -> Bytes {
  let h = Buffer()
  h.write_byte((0xe0 | ((pn_length - 1) & 0x03)).to_byte())
  for i = 3; i >= 0; i = i - 1 {
    h.write_byte(((version >> (i * 8)) & 0xffU).to_byte())
  }
  h.write_byte(dcid.length().to_byte())
  h.write_bytes(dcid[:])
  h.write_byte(scid.length().to_byte())
  h.write_bytes(scid[:])
  h.write_bytes(quic_varint_encode((pn_length + sealed_len).to_uint64())[:])
  for i = pn_length - 1; i >= 0; i = i - 1 {
    h.write_byte(((packet_number >> (i * 8)) & 0xffL).to_byte())
  }
  h.to_bytes()
}

///|
/// Protect a QUIC Handshake packet: assemble the long header, AEAD-seal `payload` with the
/// unprotected header as associated data, then apply header protection (RFC 9001 §5.3–§5.4).
/// `sealed_len` in the length field accounts for the 16-byte tag.
pub fn quic_protect_handshake(
  version : UInt,
  dcid : Bytes,
  scid : Bytes,
  packet_number : Int64,
  pn_length : Int,
  payload : Bytes,
  key : Bytes,
  iv : Bytes,
  hp : Bytes,
) -> Bytes {
  let header = quic_handshake_header(
    version,
    dcid,
    scid,
    packet_number,
    pn_length,
    payload.length() + 16,
  )
  let pn_offset = header.length() - pn_length
  let nonce = quic_nonce(iv, packet_number)
  let box = gcm_seal(key, nonce, payload, header)
  let packet = Buffer()
  packet.write_bytes(header[:])
  packet.write_bytes(box[:])
  quic_header_protect(packet.to_bytes(), pn_offset, pn_length, hp)
}

///|
/// The offset of the packet-number field in a received Handshake packet, walking its long
/// header: first byte, version, the two connection ids, and the length field (RFC 9000
/// §17.2.4 — no token field, unlike Initial).
pub fn quic_handshake_pn_offset(packet : Bytes) -> Int raise QuicPayloadError {
  let view = packet[:]
  let mut off = 1 + 4 // first byte + version
  if off + 1 > view.length() {
    raise QuicPayloadError("Handshake packet truncated before DCID")
  }
  let dcid_len = view[off].to_int()
  off = off + 1 + dcid_len
  if off + 1 > view.length() {
    raise QuicPayloadError("Handshake packet truncated before SCID")
  }
  let scid_len = view[off].to_int()
  off = off + 1 + scid_len
  let (_length, ll) = match quic_varint_decode(view[off:]) {
    Some(v) => v
    None => raise QuicPayloadError("Handshake packet truncated in length field")
  }
  off + ll
}

///|
/// Build a protected Handshake packet carrying `frames`: encode them into a payload and
/// protect it with the handshake-space keys (RFC 9001 §5.3–§5.4).
pub fn quic_send_handshake(
  version : UInt,
  dcid : Bytes,
  scid : Bytes,
  packet_number : Int64,
  pn_length : Int,
  frames : Array[QuicFrame],
  keys : QuicPacketKeys,
) -> Bytes {
  quic_protect_handshake(
    version,
    dcid,
    scid,
    packet_number,
    pn_length,
    quic_encode_payload(frames),
    keys.key,
    keys.iv,
    keys.hp,
  )
}

///|
/// Receive a protected Handshake `packet` with the handshake-space keys: remove protection
/// (the protected long-header trailer — header protection over the packet number, AEAD over
/// the payload — is shared with the Initial path), parse the payload, and return its frames
/// and packet number. `None` if authentication fails.
pub fn quic_recv_handshake(
  packet : Bytes,
  keys : QuicPacketKeys,
) -> (Array[QuicFrame], Int64)? raise QuicPayloadError {
  let pn_offset = quic_handshake_pn_offset(packet)
  match quic_unprotect_initial(packet, pn_offset, keys.key, keys.iv, keys.hp) {
    Some((payload, pn)) => Some((quic_parse_payload(payload), pn))
    None => None
  }
}
