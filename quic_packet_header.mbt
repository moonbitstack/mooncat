// QUIC long packet headers (RFC 9000 §17.2). Long headers carry the handshake
// packets (Initial, 0-RTT, Handshake, Retry): they are fully self-describing —
// version, and length-prefixed destination and source connection IDs — which is
// the version-independent invariant RFC 8999 pins down. The third QUIC brick,
// on top of the varint and packet-number primitives.

///|
/// The four long-header packet types (RFC 9000 §17.2), in the encoding of the
/// first byte's type bits: Initial 0, 0-RTT 1, Handshake 2, Retry 3.
pub(all) enum QuicLongPacketType {
  Initial
  ZeroRtt
  Handshake
  Retry
} derive(Eq, Debug)

///|
/// A long packet header's invariant fields: its type, the type-specific low four
/// bits of the first byte (the packet-number length for Initial/Handshake/0-RTT,
/// unused by Retry), the 32-bit version, and the destination and source connection
/// IDs.
pub(all) struct QuicLongHeader {
  packet_type : QuicLongPacketType
  type_specific : Int
  version : UInt
  dcid : Bytes
  scid : Bytes
} derive(Eq, Debug)

///|
/// The first byte's 2-bit type code for a packet type.
fn long_type_code(t : QuicLongPacketType) -> Int {
  match t {
    Initial => 0
    ZeroRtt => 1
    Handshake => 2
    Retry => 3
  }
}

///|
/// Encode a long header: first byte (`1` header-form, `1` fixed bit, 2-bit type,
/// 4 type-specific bits), the version big-endian, then each connection ID prefixed
/// by its one-byte length.
pub fn encode_long_header(h : QuicLongHeader) -> Bytes {
  let first = 0xc0 |
    (long_type_code(h.packet_type) << 4) |
    (h.type_specific & 0x0f)
  let buf = Buffer()
  buf.write_byte(first.to_byte())
  buf.write_byte((h.version >> 24).to_byte())
  buf.write_byte((h.version >> 16).to_byte())
  buf.write_byte((h.version >> 8).to_byte())
  buf.write_byte(h.version.to_byte())
  buf.write_byte(h.dcid.length().to_byte())
  buf.write_bytes(h.dcid[:])
  buf.write_byte(h.scid.length().to_byte())
  buf.write_bytes(h.scid[:])
  buf.to_bytes()
}

///|
/// Parse a long header at the start of `b`, returning it and the number of bytes it
/// occupied, or `None` if the first byte is not a long header or `b` is truncated
/// before the header ends.
pub fn parse_long_header(b : BytesView) -> (QuicLongHeader, Int)? {
  if b.length() < 5 {
    return None
  }
  let first = b[0].to_int()
  // Header form is the high bit; a long header has it set.
  if (first & 0x80) == 0 {
    return None
  }
  let packet_type = match (first >> 4) & 0x03 {
    0 => QuicLongPacketType::Initial
    1 => ZeroRtt
    2 => QuicLongPacketType::Handshake
    _ => Retry
  }
  let type_specific = first & 0x0f
  let version = (b[1].to_int() << 24).reinterpret_as_uint() |
    (b[2].to_int() << 16).reinterpret_as_uint() |
    (b[3].to_int() << 8).reinterpret_as_uint() |
    b[4].to_int().reinterpret_as_uint()
  let mut off = 5
  if b.length() < off + 1 {
    return None
  }
  let dcil = b[off].to_int()
  off = off + 1
  if b.length() < off + dcil {
    return None
  }
  let dcid = b[off:off + dcil].to_owned()
  off = off + dcil
  if b.length() < off + 1 {
    return None
  }
  let scil = b[off].to_int()
  off = off + 1
  if b.length() < off + scil {
    return None
  }
  let scid = b[off:off + scil].to_owned()
  off = off + scil
  Some(({ packet_type, type_specific, version, dcid, scid, }, off))
}

///|
pub extend QuicLongHeader with Debug::{to_repr}

///|
pub extend QuicLongHeader with Eq::{not_equal, equal}

///|
pub extend QuicLongPacketType with Debug::{to_repr}

///|
pub extend QuicLongPacketType with Eq::{not_equal, equal}
