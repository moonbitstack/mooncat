// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The socket half of WebSocket. The codec is `moonhttp/ws`, which takes bytes and answers
// with frames and messages; what is left here is reading those bytes off a stream and
// writing back the frames the protocol owes, which is the one thing a codec must not do.

///|
/// One frame off a stream (RFC 6455 §5.2).
///
/// The header is read in the order the format is laid out — two bytes, then the extended
/// length, then the mask — and `@ws.check` runs on the header before the payload is read,
/// so an enormous announced length is refused rather than allocated.
///
/// `client` is the server's position by default: a client's frames must be masked (§5.1),
/// so reading a server's frames takes `client=false`. Raises `@ws.Refused` carrying the
/// status the connection is then failed with, and passes the stream's end through.
pub async fn read_frame(
  reader : &@io.Reader,
  client? : Bool = true,
  limit? : Int = @ws.limit,
) -> @ws.Frame {
  let head = reader.read_exactly(2)
  let b0 = head[0].to_int()
  let b1 = head[1].to_int()
  let mut len = (b1 & 0x7f).to_int64()
  if len == 126L {
    let wide = reader.read_exactly(2)
    len = ((wide[0].to_int() << 8) | wide[1].to_int()).to_int64()
  } else if len == 127L {
    let wide = reader.read_exactly(8)
    let mut n = 0L
    for i = 0; i < 8; i = i + 1 {
      n = (n << 8) | wide[i].to_int().to_int64()
    }
    len = n
  }
  let opcode = @ws.check(b0, b1, len, client~, limit~)
  // `check` bounded it, so narrowing cannot truncate.
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
/// One complete message off a stream, with the control frames between its fragments
/// handled: a ping is answered on `writer`, a pong is dropped, and a close is echoed
/// before the message comes back as that close.
///
/// This is the server's receive path, so every frame must arrive masked. The reply frames
/// go out unmasked because a server must not mask (§5.1).
pub async fn read_message(
  reader : &@io.Reader,
  writer : &@io.Writer,
  limit? : Int = @ws.limit,
) -> @ws.Message {
  let assembling = @ws.Reader::new(limit~)
  for ;; {
    let frame = read_frame(reader, limit~)
    let step = assembling.feed(frame)
    match step.reply {
      Some(reply) => writer.write(reply.encode())
      None => ()
    }
    match step.message {
      Some(message) => return message
      None => ()
    }
  }
}
