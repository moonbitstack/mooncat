// HTTP/3 unidirectional stream types (RFC 9114 §6.2, RFC 9204 §4.2). Every unidirectional
// stream opens with a variable-length integer naming its type: the control stream (0x00)
// that carries SETTINGS and connection-control frames, a server push stream (0x01) prefixed
// with its push id, and the QPACK encoder (0x02) and decoder (0x03) streams that carry the
// dynamic-table instructions. Unrecognized types are reserved/greased and their payloads are
// ignored (§6.2, §6.2.3). This is the demultiplexer a connection runs over the raw QUIC
// unidirectional streams before dispatching to the frame and QPACK-instruction codecs.

///|
/// An HTTP/3 unidirectional stream's type (RFC 9114 §6.2, RFC 9204 §4.2).
pub(all) enum Http3UniStream {
  ControlStream
  PushStream(UInt64)
  QpackEncoderStream
  QpackDecoderStream
  ReservedStream(UInt64)
} derive(Eq, Debug)

///|
/// Encode a unidirectional stream's opening bytes: the type varint, plus the push id for a
/// push stream (RFC 9114 §6.2.2).
pub fn http3_encode_stream_type(stream : Http3UniStream) -> Bytes {
  match stream {
    ControlStream => @varint.encode(0x00)
    PushStream(push_id) => {
      let buf = Buffer()
      buf.write_bytes(@varint.encode(0x01))
      buf.write_bytes(@varint.encode(push_id))
      buf.to_bytes()
    }
    QpackEncoderStream => @varint.encode(0x02)
    QpackDecoderStream => @varint.encode(0x03)
    ReservedStream(t) => @varint.encode(t)
  }
}

///|
/// Decode a unidirectional stream's opening bytes: the type varint (and a push id for a push
/// stream). Returns the stream kind and bytes consumed, or `None` on a partial read.
pub fn http3_decode_stream_type(input : BytesView) -> (Http3UniStream, Int)? {
  let (stream_type, type_len) = match @varint.decode(input) {
    Some(v) => v
    None => return None
  }
  match stream_type {
    0x00 => Some((ControlStream, type_len))
    0x01 =>
      match @varint.decode(input[type_len:]) {
        Some((push_id, id_len)) =>
          Some((PushStream(push_id), type_len + id_len))
        None => None
      }
    0x02 => Some((QpackEncoderStream, type_len))
    0x03 => Some((QpackDecoderStream, type_len))
    other => Some((ReservedStream(other), type_len))
  }
}

///|
/// Encode a control stream (RFC 9114 §6.2.1): the control-stream type, then a SETTINGS frame
/// with `settings`, which a control stream must send first.
pub fn http3_encode_control_stream(settings : Array[(UInt64, UInt64)]) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(http3_encode_stream_type(ControlStream))
  buf.write_bytes(http3_frame_encode(Settings(settings)))
  buf.to_bytes()
}

///|
pub extend Http3UniStream with Debug::{to_repr}

///|
pub extend Http3UniStream with Eq::{not_equal, equal}
