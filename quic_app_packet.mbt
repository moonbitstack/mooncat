// QUIC 1-RTT (Application) packet protection (RFC 9000 §17.3 short header + RFC 9001 §5.3–§5.4).
// Once the handshake completes, every application packet uses a short header — no length
// field (the payload runs to the end of the datagram) and no connection-id lengths on the
// wire (the receiver knows its own) — protected with the application traffic keys. The
// AEAD sealing and header protection are shared with the Initial/Handshake paths; only the
// header layout and the receiver's need for the destination-CID length differ. This is the
// third and last packet-protection key space.

///|
/// Assemble a short (1-RTT) header (RFC 9000 §17.3): the first byte (form 0, fixed bit,
/// spin, two reserved zero bits, key phase, and the two-bit packet-number length minus
/// one), the destination connection id with no length prefix, and the packet number.
fn quic_short_header_bytes(
  spin : Bool,
  key_phase : Bool,
  dcid : Bytes,
  packet_number : Int64,
  pn_length : Int,
) -> Bytes {
  let first = 0x40 |
    (if spin { 0x20 } else { 0 }) |
    (if key_phase { 0x04 } else { 0 }) |
    ((pn_length - 1) & 0x03)
  let h = Buffer()
  h.write_byte(first.to_byte())
  h.write_bytes(dcid[:])
  for i = pn_length - 1; i >= 0; i = i - 1 {
    h.write_byte(((packet_number >> (i * 8)) & 0xffL).to_byte())
  }
  h.to_bytes()
}

///|
/// Protect a QUIC 1-RTT packet: assemble the short header, AEAD-seal `payload` with the
/// unprotected header as associated data, then apply header protection (RFC 9001 §5.3–§5.4).
pub fn quic_protect_short(
  spin : Bool,
  key_phase : Bool,
  dcid : Bytes,
  packet_number : Int64,
  pn_length : Int,
  payload : Bytes,
  key : Bytes,
  iv : Bytes,
  hp : Bytes,
) -> Bytes {
  let header = quic_short_header_bytes(
    spin, key_phase, dcid, packet_number, pn_length,
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
/// Remove protection from a received 1-RTT packet, given the length of the destination
/// connection id this endpoint issued: the packet-number field starts right after the
/// first byte and the connection id, and the payload runs to the end (RFC 9000 §17.3).
/// The protected long-header trailer strip (header protection over the packet number, AEAD
/// over the payload) is shared with the Initial/Handshake paths. `None` if it fails.
pub fn quic_unprotect_short(
  packet : Bytes,
  dcid_len : Int,
  key : Bytes,
  iv : Bytes,
  hp : Bytes,
) -> (Bytes, Int64)? {
  quic_unprotect_initial(packet, 1 + dcid_len, key, iv, hp)
}

///|
/// Build a protected 1-RTT packet carrying `frames`: encode them into a payload and
/// protect it with the application-space keys (RFC 9001 §5.3–§5.4).
pub fn quic_send_short(
  spin : Bool,
  key_phase : Bool,
  dcid : Bytes,
  packet_number : Int64,
  pn_length : Int,
  frames : Array[QuicFrame],
  keys : QuicPacketKeys,
) -> Bytes {
  quic_protect_short(
    spin,
    key_phase,
    dcid,
    packet_number,
    pn_length,
    quic_encode_payload(frames),
    keys.key,
    keys.iv,
    keys.hp,
  )
}

///|
/// Receive a protected 1-RTT `packet` with the application-space keys, given the length of
/// the destination connection id this endpoint issued: remove protection, parse the
/// payload, and return its frames and packet number. `None` if authentication fails.
pub fn quic_recv_short(
  packet : Bytes,
  dcid_len : Int,
  keys : QuicPacketKeys,
) -> (Array[QuicFrame], Int64)? raise QuicPayloadError {
  match quic_unprotect_short(packet, dcid_len, keys.key, keys.iv, keys.hp) {
    Some((payload, pn)) => Some((quic_parse_payload(payload), pn))
    None => None
  }
}
