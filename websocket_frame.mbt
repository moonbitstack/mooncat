// The WebSocket frame layer (RFC 6455 §5.2), self-built so mooncat owns the whole server-side WS
// path: the async transport's `Conn::from_http_server` writes a fixed 101 (no negotiated
// subprotocol) and its frame reader/writer (`Conn::new`) is package-private, so echoing a
// subprotocol means writing our own 101 (see `websocket_handshake`) and framing over the raw
// upgraded socket ourselves. This is the codec half; the runtime half feeds it the socket's bytes.

///|
/// A WebSocket protocol violation, carrying the RFC 6455 §7.4.1 status code the connection must be
/// failed with (§7.1.7) and a diagnostic. Distinct from the reader's end-of-stream, which is not a
/// violation and closes the connection without a status.
pub suberror WsError {
  WsError(Int, String)
}

///|
/// §7.4.1 `1002`: the peer broke the protocol — a set RSV bit, a reserved opcode, an unmasked
/// client frame, or a malformed control frame.
let ws_protocol_error : Int = 1002

///|
/// §7.4.1 `1007`: a text message whose bytes are not valid UTF-8 (§8.1).
let ws_invalid_payload : Int = 1007

///|
/// §7.4.1 `1009`: the peer announced more payload than this endpoint will accept.
let ws_message_too_big : Int = 1009

///|
/// The default ceiling on a received payload, in bytes (← uvicorn's `--ws-max-size`, 16 MiB). It
/// bounds both a single frame and a reassembled fragmented message; past it the connection is
/// failed with `1009` rather than allocating whatever the peer asked for.
pub let ws_max_size : Int = 16 * 1024 * 1024

///|
/// A WebSocket frame opcode (RFC 6455 §5.2): the data opcodes (continuation / text / binary) and
/// the control opcodes (close / ping / pong).
pub(all) enum WsOpcode {
  Continuation
  Text
  Binary
  Close
  Ping
  Pong
} derive(Eq, Debug)

///|
/// The 4-bit wire value of an opcode.
pub fn WsOpcode::to_int(self : WsOpcode) -> Int {
  match self {
    Continuation => 0x0
    Text => 0x1
    Binary => 0x2
    Close => 0x8
    Ping => 0x9
    Pong => 0xA
  }
}

///|
/// Whether this is a control opcode (RFC 6455 §5.5), which the spec holds to tighter rules than a
/// data frame: at most 125 payload bytes, and never fragmented.
pub fn WsOpcode::is_control(self : WsOpcode) -> Bool {
  match self {
    Close | Ping | Pong => true
    Continuation | Text | Binary => false
  }
}

///|
/// The opcode for a 4-bit wire value, or `None` for a reserved opcode.
pub fn ws_opcode_of_int(n : Int) -> WsOpcode? {
  match n {
    0x0 => Some(Continuation)
    0x1 => Some(Text)
    0x2 => Some(Binary)
    0x8 => Some(Close)
    0x9 => Some(Ping)
    0xA => Some(Pong)
    _ => None
  }
}

///|
/// A decoded WebSocket frame (RFC 6455 §5.2): its FIN bit, opcode, and already-unmasked payload.
pub(all) struct WsFrame {
  fin : Bool
  opcode : WsOpcode
  payload : Bytes
} derive(Eq, Debug)

///|
/// Encode a WebSocket frame (RFC 6455 §5.2). A 4-byte `mask` sets the MASK bit and masks the
/// payload (clients MUST mask, servers MUST NOT — pass `b""` for an unmasked server frame). The
/// payload length takes the shortest of the 7-bit (≤125), 16-bit (`126`), or 64-bit (`127`) forms.
pub fn ws_encode_frame(
  fin : Bool,
  opcode : WsOpcode,
  payload : Bytes,
  mask? : Bytes = b"",
) -> Bytes {
  let buf = Buffer()
  let b0 = (if fin { 0x80 } else { 0x00 }) | opcode.to_int()
  buf.write_byte(b0.to_byte())
  let masked = mask.length() == 4
  let mask_bit = if masked { 0x80 } else { 0x00 }
  let len = payload.length()
  if len <= 125 {
    buf.write_byte((mask_bit | len).to_byte())
  } else if len <= 0xFFFF {
    buf.write_byte((mask_bit | 126).to_byte())
    buf.write_byte((len >> 8).to_byte())
    buf.write_byte(len.to_byte())
  } else {
    buf.write_byte((mask_bit | 127).to_byte())
    let l = len.to_int64()
    for i = 7; i >= 0; i = i - 1 {
      buf.write_byte((l >> (i * 8)).to_byte())
    }
  }
  if masked {
    for i = 0; i < 4; i = i + 1 {
      buf.write_byte(mask[i])
    }
    for i = 0; i < len; i = i + 1 {
      buf.write_byte((payload[i].to_int() ^ mask[i % 4].to_int()).to_byte())
    }
  } else {
    for i = 0; i < len; i = i + 1 {
      buf.write_byte(payload[i])
    }
  }
  buf.to_bytes()
}

///|
/// Check a frame's wire header against RFC 6455's receive rules and return its opcode. `b0` and
/// `b1` are the first two header bytes; `len` is the payload length already widened out of
/// whichever of the three length forms carried it.
///
/// Raises `WsError` with the status code the connection must then be failed with (§7.1.7):
///
/// * a set RSV1/2/3 bit, no extension having been negotiated → `1002` (§5.2);
/// * a reserved opcode → `1002` (§5.2);
/// * an unmasked frame, when `from_client` says the peer is a client → `1002` (§5.1);
/// * a control frame carrying more than 125 bytes, or fragmented → `1002` (§5.5);
/// * a length past `max_size` → `1009`, the 64-bit form's sign bit included (§5.2 reserves it).
///
/// Callers must run this *before* they read the payload: it is the length check that keeps a
/// 64-bit length from being truncated into a short allocation, and keeps an honest-but-enormous
/// one from being allocated at all.
pub fn ws_check_frame(
  b0 : Int,
  b1 : Int,
  len : Int64,
  from_client~ : Bool,
  max_size~ : Int,
) -> WsOpcode raise WsError {
  if (b0 & 0x70) != 0 {
    raise WsError(ws_protocol_error, "RSV bit set with no extension negotiated")
  }
  let opcode = match ws_opcode_of_int(b0 & 0x0F) {
    Some(op) => op
    None => raise WsError(ws_protocol_error, "reserved WebSocket opcode")
  }
  if from_client && (b1 & 0x80) == 0 {
    raise WsError(ws_protocol_error, "client frame is not masked")
  }
  if opcode.is_control() {
    if len > 125L {
      raise WsError(
        ws_protocol_error, "control frame carries more than 125 bytes",
      )
    }
    if (b0 & 0x80) == 0 {
      raise WsError(ws_protocol_error, "fragmented control frame")
    }
  }
  if len < 0L || len > max_size.to_int64() {
    raise WsError(
      ws_message_too_big,
      "payload length past the \{max_size}-byte ceiling",
    )
  }
  opcode
}

///|
/// Decode one WebSocket frame at the start of `b` (RFC 6455 §5.2), returning the frame (its payload
/// unmasked) and the byte count it consumed, or `None` when `b` does not yet hold a whole frame.
///
/// `from_client` selects the receive rules of a server reading a client (the default: masking is
/// mandatory); pass `false` to decode a frame travelling the other way. A frame that breaks the
/// rules raises `WsError` rather than returning `None`, so a violation is never mistaken for a
/// short buffer — see `ws_check_frame`.
pub fn ws_decode_frame(
  b : BytesView,
  from_client? : Bool = true,
  max_size? : Int = ws_max_size,
) -> (WsFrame, Int)? raise WsError {
  if b.length() < 2 {
    return None
  }
  let b0 = b[0].to_int()
  let b1 = b[1].to_int()
  let mut off = 2
  let mut len = (b1 & 0x7F).to_int64()
  if len == 126L {
    if b.length() < off + 2 {
      return None
    }
    len = ((b[off].to_int() << 8) | b[off + 1].to_int()).to_int64()
    off = off + 2
  } else if len == 127L {
    if b.length() < off + 8 {
      return None
    }
    let mut l = 0L
    for i = 0; i < 8; i = i + 1 {
      l = (l << 8) | b[off + i].to_int().to_int64()
    }
    len = l
    off = off + 8
  }
  let opcode = ws_check_frame(b0, b1, len, from_client~, max_size~)
  // Bounded by `ws_check_frame`, so narrowing cannot truncate.
  let n = len.to_int()
  let masked = (b1 & 0x80) != 0
  let mut mask_off = 0
  if masked {
    if b.length() < off + 4 {
      return None
    }
    mask_off = off
    off = off + 4
  }
  if b.length() < off + n {
    return None
  }
  let payload = Buffer()
  for i = 0; i < n; i = i + 1 {
    if masked {
      payload.write_byte(
        (b[off + i].to_int() ^ b[mask_off + i % 4].to_int()).to_byte(),
      )
    } else {
      payload.write_byte(b[off + i])
    }
  }
  Some(
    ({ fin: (b0 & 0x80) != 0, opcode, payload: payload.to_bytes(), }, off + n),
  )
}

///|
/// Read one WebSocket frame off a raw byte stream (RFC 6455 §5.2) — the runtime counterpart of
/// `ws_decode_frame`. Reads the 2-byte prefix, then the extended length (16- or 64-bit), and only
/// once `ws_check_frame` has passed the header does it read the masking key and the payload.
///
/// `from_client` defaults to the server's position — a client's frames must be masked (§5.1) —
/// so reading a frame the server sent needs `from_client=false`. Raises `WsError` carrying the
/// close code for any violation, and propagates the reader's end-of-stream.
pub async fn ws_read_frame(
  reader : &@io.Reader,
  from_client? : Bool = true,
  max_size? : Int = ws_max_size,
) -> WsFrame {
  let h = reader.read_exactly(2)
  let b0 = h[0].to_int()
  let b1 = h[1].to_int()
  let mut len = (b1 & 0x7F).to_int64()
  if len == 126L {
    let e = reader.read_exactly(2)
    len = ((e[0].to_int() << 8) | e[1].to_int()).to_int64()
  } else if len == 127L {
    let e = reader.read_exactly(8)
    let mut l = 0L
    for i = 0; i < 8; i = i + 1 {
      l = (l << 8) | e[i].to_int().to_int64()
    }
    len = l
  }
  let opcode = ws_check_frame(b0, b1, len, from_client~, max_size~)
  // Bounded by `ws_check_frame`, so narrowing cannot truncate.
  let n = len.to_int()
  let mask = if (b1 & 0x80) != 0 { reader.read_exactly(4) } else { b"" }
  let raw = reader.read_exactly(n)
  let payload = if mask.length() == 4 {
    let buf = Buffer()
    for i = 0; i < n; i = i + 1 {
      buf.write_byte((raw[i].to_int() ^ mask[i % 4].to_int()).to_byte())
    }
    buf.to_bytes()
  } else {
    raw
  }
  { fin: (b0 & 0x80) != 0, opcode, payload, }
}

///|
/// A complete WebSocket application message read off a raw stream: a text or binary message with
/// its reassembled payload, or a close with its code and reason bytes. Control frames never surface
/// here — `ws_read_message` handles them — matching what uvicorn hands the ASGI app.
///
/// A text message carries a `String`: §8.1 makes invalid UTF-8 a `1007` failure, so bytes that
/// would not decode never reach this far and the app cannot be handed a lossily-mangled message.
pub(all) enum WsMessage {
  WsText(String)
  WsBinary(Bytes)
  WsClose(Int, Bytes)
} derive(Eq, Debug)

///|
/// The status code of a close frame's payload (RFC 6455 §5.5.1 / §7.1.5): the leading 16-bit value,
/// or `1005` ("no status received") when the payload carries none.
fn ws_close_code(payload : Bytes) -> Int {
  if payload.length() >= 2 {
    (payload[0].to_int() << 8) | payload[1].to_int()
  } else {
    1005
  }
}

///|
/// Build a close frame's payload (RFC 6455 §5.5.1): the 16-bit status code big-endian followed by
/// the UTF-8 reason.
pub fn ws_close_payload(code : Int, reason : String) -> Bytes {
  let buf = Buffer()
  buf.write_byte((code >> 8).to_byte())
  buf.write_byte(code.to_byte())
  buf.write_bytes(@utf8.encode(reason))
  buf.to_bytes()
}

///|
/// The reason bytes of a close frame's payload — everything after the 2-byte status code.
fn ws_close_reason(payload : Bytes) -> Bytes {
  if payload.length() > 2 {
    payload[2:].to_owned()
  } else {
    b""
  }
}

///|
/// Read one complete WebSocket message off `reader`, reassembling a fragmented message from its
/// continuation frames (RFC 6455 §5.4) and handling interleaved control frames (§5.5): a ping is
/// answered on `writer` with a pong, a pong is dropped, and a close is echoed back per §5.5.1
/// before the message ends with its code and reason.
///
/// This is the server's receive path, so every frame must arrive masked. Raises `WsError` carrying
/// the close code the connection is then failed with: `1002` for a framing violation (a stray
/// continuation frame, or a new data frame arriving before the current message finished) and
/// whatever `ws_check_frame` decided for a bad header, `1007` for a text message that is not valid
/// UTF-8 (§8.1), `1009` for a reassembled message past `max_size`.
pub async fn ws_read_message(
  reader : &@io.Reader,
  writer : &@io.Writer,
  max_size? : Int = ws_max_size,
) -> WsMessage {
  let payload = Buffer()
  let mut kind : WsOpcode? = None
  for ;; {
    let frame = ws_read_frame(reader, max_size~)
    match frame.opcode {
      Ping => writer.write(ws_encode_frame(true, Pong, frame.payload))
      Pong => ()
      Close => {
        // §5.5.1: answer a close with a close before the connection goes. A close that carried no
        // status is echoed statusless — 1005 is a local sentinel and must never reach the wire.
        let echo = if frame.payload.length() >= 2 {
          ws_close_payload(ws_close_code(frame.payload), "")
        } else {
          b""
        }
        writer.write(ws_encode_frame(true, Close, echo))
        return WsClose(
          ws_close_code(frame.payload),
          ws_close_reason(frame.payload),
        )
      }
      Text | Binary => {
        if kind is Some(_) {
          raise WsError(
            ws_protocol_error, "a new data frame arrived before the message finished",
          )
        }
        kind = Some(frame.opcode)
        ws_append(payload, frame.payload, max_size)
        if frame.fin {
          break
        }
      }
      Continuation => {
        if kind is None {
          raise WsError(
            ws_protocol_error, "continuation frame with no message in progress",
          )
        }
        ws_append(payload, frame.payload, max_size)
        if frame.fin {
          break
        }
      }
    }
  }
  let data = payload.to_bytes()
  if kind is Some(Binary) {
    WsBinary(data)
  } else {
    // §8.1: a text message that is not valid UTF-8 fails the connection with 1007. Decoding it
    // lossily instead would hand the app a message the peer never sent.
    WsText(
      @utf8.decode(data[:]) catch {
        _ =>
          raise WsError(ws_invalid_payload, "text message is not valid UTF-8")
      },
    )
  }
}

///|
/// Append a fragment to the message being reassembled, failing the connection with `1009` when the
/// total passes `max_size`. A per-frame ceiling alone would not bound a message split into enough
/// small fragments.
fn ws_append(buf : Buffer, part : Bytes, max_size : Int) -> Unit raise WsError {
  if buf.length() + part.length() > max_size {
    raise WsError(
      ws_message_too_big,
      "message past the \{max_size}-byte ceiling",
    )
  }
  buf.write_bytes(part)
}

///|
pub extend WsFrame with Debug::{to_repr}

///|
pub extend WsFrame with Eq::{not_equal, equal}

///|
pub extend WsMessage with Debug::{to_repr}

///|
pub extend WsMessage with Eq::{not_equal, equal}

///|
pub extend WsOpcode with Debug::{to_repr}

///|
pub extend WsOpcode with Eq::{not_equal, equal}
