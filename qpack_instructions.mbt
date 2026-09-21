// QPACK encoder- and decoder-stream instructions (RFC 9204 §4.3, §4.4). The encoder
// stream carries the instructions that mutate the dynamic table — set its capacity, insert
// an entry (by name reference or with a literal name), or duplicate an existing entry — and
// the decoder stream carries the acknowledgements that let the encoder reclaim table space:
// a section acknowledgement, a stream cancellation, and an insert-count increment. Each
// instruction is a pattern in the high bits of its first byte over a QPACK prefixed integer
// (and, for inserts, string literals). This is the wire codec the dynamic-table state
// machine drives; the table itself is built on top of it.

///|
/// An encoder-stream instruction (RFC 9204 §4.3).
pub(all) enum QpackEncoderInst {
  /// Set Dynamic Table Capacity (§4.3.1): `001` + capacity (5-bit prefix).
  SetCapacity(Int)
  /// Insert With Name Reference (§4.3.2): `1` + T (static/dynamic) + name index (6-bit
  /// prefix), then the value string.
  InsertNameRef(is_static~ : Bool, index~ : Int, value~ : Bytes)
  /// Insert With Literal Name (§4.3.3): `01` + H + name length (5-bit prefix) + name,
  /// then the value string.
  InsertLiteralName(name~ : Bytes, value~ : Bytes)
  /// Duplicate (§4.3.4): `000` + index (5-bit prefix).
  Duplicate(index~ : Int)
} derive(Eq, Debug)

///|
/// A decoder-stream instruction (RFC 9204 §4.4).
pub(all) enum QpackDecoderInst {
  /// Section Acknowledgement (§4.4.1): `1` + stream id (7-bit prefix).
  SectionAck(stream_id~ : Int)
  /// Stream Cancellation (§4.4.2): `01` + stream id (6-bit prefix).
  StreamCancel(stream_id~ : Int)
  /// Insert Count Increment (§4.4.3): `00` + increment (6-bit prefix).
  InsertCountIncrement(increment~ : Int)
} derive(Eq, Debug)

///|
/// Encode an encoder-stream instruction (RFC 9204 §4.3). `huffman` chooses whether the
/// literal strings of the insert instructions are Huffman-coded.
pub fn qpack_encode_encoder_inst(
  inst : QpackEncoderInst,
  huffman? : Bool = true,
) -> Bytes {
  match inst {
    SetCapacity(capacity) => qpack_int_encode(capacity, 5, 0x20)
    InsertNameRef(is_static~, index~, value~) => {
      let buf = Buffer()
      buf.write_bytes(
        qpack_int_encode(index, 6, 0x80 | (if is_static { 0x40 } else { 0 })),
      )
      buf.write_bytes(qpack_encode_string(value, 7, 0, huffman))
      buf.to_bytes()
    }
    InsertLiteralName(name~, value~) => {
      let buf = Buffer()
      buf.write_bytes(qpack_encode_string(name, 5, 0x40, huffman))
      buf.write_bytes(qpack_encode_string(value, 7, 0, huffman))
      buf.to_bytes()
    }
    Duplicate(index~) => qpack_int_encode(index, 5, 0x00)
  }
}

///|
/// Decode one encoder-stream instruction from the front of `input` (RFC 9204 §4.3),
/// dispatching on the pattern in the first byte's high bits. Returns `(instruction,
/// bytes-consumed)`, or `None` when the instruction has not fully arrived.
pub fn qpack_decode_encoder_inst(
  input : BytesView,
) -> (QpackEncoderInst, Int)? raise QpackError {
  if input.length() == 0 {
    return None
  }
  let b0 = input[0].to_int()
  if (b0 & 0x80) != 0 {
    let is_static = (b0 & 0x40) != 0
    let (index, ic) = match qpack_int_decode(input, 6) {
      Some(v) => v
      None => return None
    }
    match qpack_decode_string(input[ic:], 7) {
      Some((value, vc)) =>
        Some((InsertNameRef(is_static~, index~, value~), ic + vc))
      None => None
    }
  } else if (b0 & 0x40) != 0 {
    let (name, nc) = match qpack_decode_string(input, 5) {
      Some(v) => v
      None => return None
    }
    match qpack_decode_string(input[nc:], 7) {
      Some((value, vc)) => Some((InsertLiteralName(name~, value~), nc + vc))
      None => None
    }
  } else if (b0 & 0x20) != 0 {
    match qpack_int_decode(input, 5) {
      Some((capacity, cc)) => Some((SetCapacity(capacity), cc))
      None => None
    }
  } else {
    match qpack_int_decode(input, 5) {
      Some((index, dc)) => Some((Duplicate(index~), dc))
      None => None
    }
  }
}

///|
/// Encode a decoder-stream instruction (RFC 9204 §4.4).
pub fn qpack_encode_decoder_inst(inst : QpackDecoderInst) -> Bytes {
  match inst {
    SectionAck(stream_id~) => qpack_int_encode(stream_id, 7, 0x80)
    StreamCancel(stream_id~) => qpack_int_encode(stream_id, 6, 0x40)
    InsertCountIncrement(increment~) => qpack_int_encode(increment, 6, 0x00)
  }
}

///|
/// Decode one decoder-stream instruction from the front of `input` (RFC 9204 §4.4).
/// Returns `(instruction, bytes-consumed)`, or `None` on a partial read.
pub fn qpack_decode_decoder_inst(input : BytesView) -> (QpackDecoderInst, Int)? {
  if input.length() == 0 {
    return None
  }
  let b0 = input[0].to_int()
  if (b0 & 0x80) != 0 {
    match qpack_int_decode(input, 7) {
      Some((sid, c)) => Some((SectionAck(stream_id=sid), c))
      None => None
    }
  } else if (b0 & 0x40) != 0 {
    match qpack_int_decode(input, 6) {
      Some((sid, c)) => Some((StreamCancel(stream_id=sid), c))
      None => None
    }
  } else {
    match qpack_int_decode(input, 6) {
      Some((inc, c)) => Some((InsertCountIncrement(increment=inc), c))
      None => None
    }
  }
}

///|
pub extend QpackDecoderInst with Debug::{to_repr}

///|
pub extend QpackDecoderInst with Eq::{not_equal, equal}

///|
pub extend QpackEncoderInst with Debug::{to_repr}

///|
pub extend QpackEncoderInst with Eq::{not_equal, equal}
