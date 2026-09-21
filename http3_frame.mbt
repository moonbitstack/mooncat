// The HTTP/3 frame layer (RFC 9114 §7.2): every frame on an HTTP/3 stream is a
// variable-length `Type`, a variable-length `Length`, and that many payload octets.
// This is the mapping that turns a QUIC stream's bytes into the DATA / HEADERS /
// SETTINGS / GOAWAY / … frames HTTP/3 runs on, built directly on the QUIC varint codec.
// DATA and HEADERS carry opaque payloads (a body, or a QPACK-encoded field section —
// QPACK is a separate layer); SETTINGS is decoded into its identifier/value pairs.

///|
/// A malformed HTTP/3 frame (a protocol error, distinct from an incomplete read).
pub suberror Http3FrameError {
  Http3FrameError(String)
}

///|
/// HTTP/3 frame type codes (RFC 9114 §11.2.1).
let h3_frame_data : UInt64 = 0x00

///|
let h3_frame_headers : UInt64 = 0x01

///|
let h3_frame_cancel_push : UInt64 = 0x03

///|
let h3_frame_settings : UInt64 = 0x04

///|
let h3_frame_push_promise : UInt64 = 0x05

///|
let h3_frame_goaway : UInt64 = 0x07

///|
let h3_frame_max_push_id : UInt64 = 0x0d

///|
/// A decoded HTTP/3 frame. `Data`/`Headers`/`PushPromise` carry their opaque payloads;
/// `Settings` carries the decoded `(identifier, value)` pairs. `Reserved` is any
/// unknown or grease frame type (RFC 9114 §7.2.8 / §9), which a receiver ignores;
/// `ReservedHttp2` is one of the frame types reused from HTTP/2 (0x02, 0x06, 0x08,
/// 0x09), which RFC 9114 §7.2 requires be treated as a connection error.
pub(all) enum Http3Frame {
  Data(Bytes)
  Headers(Bytes)
  CancelPush(UInt64)
  Settings(Array[(UInt64, UInt64)])
  PushPromise(UInt64, Bytes)
  GoAway(UInt64)
  MaxPushId(UInt64)
  Reserved(UInt64, Bytes)
  ReservedHttp2(UInt64)
} derive(Eq, Debug)

///|
/// Whether `t` is an HTTP/2 frame type reused in HTTP/3's registry with no HTTP/3
/// meaning (PRIORITY, PING, WINDOW_UPDATE, CONTINUATION) — a connection error on
/// receipt (RFC 9114 §11.2.1).
fn h3_is_reserved_http2(t : UInt64) -> Bool {
  t == 0x02 || t == 0x06 || t == 0x08 || t == 0x09
}

///|
/// Encode one HTTP/3 frame: its type, its payload length, then the payload.
pub fn http3_frame_encode(frame : Http3Frame) -> Bytes {
  let (frame_type, payload) = match frame {
    Data(body) => (h3_frame_data, body)
    Headers(block) => (h3_frame_headers, block)
    CancelPush(id) => (h3_frame_cancel_push, quic_varint_encode(id))
    Settings(pairs) => (h3_frame_settings, http3_settings_encode(pairs))
    PushPromise(id, block) => (h3_frame_push_promise, http3_prefixed(id, block))
    GoAway(id) => (h3_frame_goaway, quic_varint_encode(id))
    MaxPushId(id) => (h3_frame_max_push_id, quic_varint_encode(id))
    Reserved(t, body) => (t, body)
    ReservedHttp2(t) => (t, b"")
  }
  let buf = Buffer()
  buf.write_bytes(quic_varint_encode(frame_type))
  buf.write_bytes(quic_varint_encode(payload.length().to_uint64()))
  buf.write_bytes(payload)
  buf.to_bytes()
}

///|
/// A varint-prefixed id followed by an opaque block (a PUSH_PROMISE payload).
fn http3_prefixed(id : UInt64, block : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(quic_varint_encode(id))
  buf.write_bytes(block)
  buf.to_bytes()
}

///|
/// Encode a SETTINGS payload: each pair as its identifier varint then its value varint
/// (RFC 9114 §7.2.4).
pub fn http3_settings_encode(pairs : Array[(UInt64, UInt64)]) -> Bytes {
  let buf = Buffer()
  for pair in pairs {
    buf.write_bytes(quic_varint_encode(pair.0))
    buf.write_bytes(quic_varint_encode(pair.1))
  }
  buf.to_bytes()
}

///|
/// Decode one HTTP/3 frame from the front of `input`. Returns `Some((frame, consumed))`
/// on a complete frame, `None` when more bytes are needed (a partial frame — the type,
/// the length, or the payload has not fully arrived), and raises on a malformed frame
/// (a truncated SETTINGS pair or a required varint field that is absent).
pub fn http3_frame_decode(
  input : BytesView,
) -> (Http3Frame, Int)? raise Http3FrameError {
  let (frame_type, type_len) = match quic_varint_decode(input) {
    Some(v) => v
    None => return None
  }
  let rest = input[type_len:]
  let (length, len_len) = match quic_varint_decode(rest) {
    Some(v) => v
    None => return None
  }
  let payload_len = length.to_int()
  let header_len = type_len + len_len
  if input.length() < header_len + payload_len {
    return None
  }
  let payload = input[header_len:header_len + payload_len].to_owned()
  let consumed = header_len + payload_len
  let frame = http3_frame_from_payload(frame_type, payload)
  Some((frame, consumed))
}

///|
/// Build the typed frame from its type code and its already-sliced payload.
fn http3_frame_from_payload(
  frame_type : UInt64,
  payload : Bytes,
) -> Http3Frame raise Http3FrameError {
  if frame_type == h3_frame_data {
    Data(payload)
  } else if frame_type == h3_frame_headers {
    Headers(payload)
  } else if frame_type == h3_frame_cancel_push {
    CancelPush(http3_one_varint(payload, "CANCEL_PUSH"))
  } else if frame_type == h3_frame_settings {
    Settings(http3_settings_decode(payload))
  } else if frame_type == h3_frame_push_promise {
    let (id, id_len) = http3_lead_varint(payload, "PUSH_PROMISE")
    PushPromise(id, payload[id_len:payload.length()].to_owned())
  } else if frame_type == h3_frame_goaway {
    GoAway(http3_one_varint(payload, "GOAWAY"))
  } else if frame_type == h3_frame_max_push_id {
    MaxPushId(http3_one_varint(payload, "MAX_PUSH_ID"))
  } else if h3_is_reserved_http2(frame_type) {
    ReservedHttp2(frame_type)
  } else {
    Reserved(frame_type, payload)
  }
}

///|
/// Decode a SETTINGS payload into its `(identifier, value)` pairs. A trailing partial
/// pair (an identifier with no value, or a truncated varint) is a frame error.
pub fn http3_settings_decode(
  payload : Bytes,
) -> Array[(UInt64, UInt64)] raise Http3FrameError {
  let pairs : Array[(UInt64, UInt64)] = []
  let view = payload[:]
  let mut off = 0
  let n = view.length()
  while off < n {
    let (id, id_len) = match quic_varint_decode(view[off:]) {
      Some(v) => v
      None => raise Http3FrameError("truncated SETTINGS identifier")
    }
    off += id_len
    let (value, val_len) = match quic_varint_decode(view[off:]) {
      Some(v) => v
      None => raise Http3FrameError("truncated SETTINGS value")
    }
    off += val_len
    pairs.push((id, value))
  }
  pairs
}

///|
/// A payload that is exactly one varint (CANCEL_PUSH / GOAWAY / MAX_PUSH_ID).
fn http3_one_varint(
  payload : Bytes,
  name : String,
) -> UInt64 raise Http3FrameError {
  let (value, _) = http3_lead_varint(payload, name)
  value
}

///|
/// The leading varint of a payload plus the octets it consumed.
fn http3_lead_varint(
  payload : Bytes,
  name : String,
) -> (UInt64, Int) raise Http3FrameError {
  match quic_varint_decode(payload[:]) {
    Some(v) => v
    None => raise Http3FrameError(name + " frame missing its varint field")
  }
}

///|
/// Decode every complete frame at the front of `input`, returning the frames and the
/// number of octets consumed (the tail, a partial frame, is left for the next read). A
/// stream reader feeds accumulated bytes and keeps the unconsumed remainder.
pub fn http3_frame_decode_all(
  input : Bytes,
) -> (Array[Http3Frame], Int) raise Http3FrameError {
  let frames : Array[Http3Frame] = []
  let mut off = 0
  let view = input[:]
  for ;; {
    match http3_frame_decode(view[off:]) {
      Some((frame, consumed)) => {
        frames.push(frame)
        off += consumed
      }
      None => break
    }
  }
  (frames, off)
}

///|
pub extend Http3Frame with Debug::{to_repr}

///|
pub extend Http3Frame with Eq::{not_equal, equal}
