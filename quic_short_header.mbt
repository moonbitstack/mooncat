// QUIC short packet headers (RFC 9000 §17.3) — the 1-RTT header that carries every
// packet once the handshake is done. Unlike a long header it does not carry the
// connection-ID lengths on the wire (the receiver already knows how long its own
// connection IDs are), so parsing takes the expected destination-CID length. The
// fifth QUIC brick, completing header parsing alongside the long header.

///|
/// A short header's fields: the latency spin bit, the key-phase bit, the
/// packet-number length (1–4 bytes, from the low two bits of the first byte plus
/// one), and the destination connection ID.
pub(all) struct QuicShortHeader {
  spin : Bool
  key_phase : Bool
  pn_length : Int
  dcid : Bytes
} derive(Eq, Debug)

///|
/// Encode a short header: first byte (`0` header-form, `1` fixed bit, spin, two
/// reserved zero bits, key phase, and the 2-bit packet-number length minus one),
/// then the destination connection ID with no length prefix. The (protected)
/// packet number follows, encoded separately.
pub fn encode_short_header(h : QuicShortHeader) -> Bytes {
  let first = 0x40 |
    (if h.spin { 0x20 } else { 0 }) |
    (if h.key_phase { 0x04 } else { 0 }) |
    ((h.pn_length - 1) & 0x03)
  let buf = Buffer()
  buf.write_byte(first.to_byte())
  buf.write_bytes(h.dcid[:])
  buf.to_bytes()
}

///|
/// Parse a short header at the start of `b`, given the length of the destination
/// connection ID this endpoint issued. Returns the header and the bytes consumed
/// (first byte plus the connection ID), or `None` if the first byte is a long
/// header or `b` is shorter than that.
pub fn parse_short_header(
  b : BytesView,
  dcid_len : Int,
) -> (QuicShortHeader, Int)? {
  if b.length() < 1 + dcid_len {
    return None
  }
  let first = b[0].to_int()
  // Header form is the high bit; a short header has it clear.
  if (first & 0x80) != 0 {
    return None
  }
  let spin = (first & 0x20) != 0
  let key_phase = (first & 0x04) != 0
  let pn_length = (first & 0x03) + 1
  let dcid = b[1:1 + dcid_len].to_owned()
  Some(({ spin, key_phase, pn_length, dcid, }, 1 + dcid_len))
}

///|
pub extend QuicShortHeader with Debug::{to_repr}

///|
pub extend QuicShortHeader with Eq::{not_equal, equal}
