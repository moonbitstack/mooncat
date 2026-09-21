// QUIC frames (RFC 9000 §19) — the content carried inside a packet's payload. Each
// frame starts with a varint type; its fields are varints too, except the fixed-width
// connection-ID tokens and path-validation data. This covers the full §19 frame set:
// PADDING/PING/ACK/ACK_ECN, CRYPTO and STREAM, the flow-control family (MAX_*, *_BLOCKED),
// the stream-control frames (RESET_STREAM/STOP_SENDING), connection management
// (NEW_CONNECTION_ID/RETIRE_CONNECTION_ID/NEW_TOKEN), path validation
// (PATH_CHALLENGE/PATH_RESPONSE), and the lifecycle frames
// (HANDSHAKE_DONE/CONNECTION_CLOSE).

///|
/// A decoded QUIC frame. `Padding` collapses a run of zero bytes to its length;
/// `Stream` carries application data on a stream, with a byte `offset` and a `fin`
/// flag marking the end of the stream (RFC 9000 §19.8).
pub(all) enum QuicFrame {
  Padding(Int)
  Ping
  Crypto(offset~ : UInt64, data~ : Bytes)
  Stream(id~ : UInt64, offset~ : UInt64, fin~ : Bool, data~ : Bytes)
  Ack(
    largest~ : UInt64,
    delay~ : UInt64,
    first_range~ : UInt64,
    ranges~ : Array[(UInt64, UInt64)]
  )
  // ACK_ECN (0x03) repeats the ACK body, then the ECT(0), ECT(1) and CE counts the peer
  // has seen on this path (RFC 9000 §19.3.2).
  AckEcn(
    largest~ : UInt64,
    delay~ : UInt64,
    first_range~ : UInt64,
    ranges~ : Array[(UInt64, UInt64)],
    ect0~ : UInt64,
    ect1~ : UInt64,
    ce~ : UInt64
  )
  ResetStream(id~ : UInt64, error_code~ : UInt64, final_size~ : UInt64)
  StopSending(id~ : UInt64, error_code~ : UInt64)
  NewToken(token~ : Bytes)
  MaxData(UInt64)
  MaxStreamData(id~ : UInt64, max~ : UInt64)
  // `bidi` selects the 0x12/0x16 (bidirectional) vs 0x13/0x17 (unidirectional) type.
  MaxStreams(bidi~ : Bool, max~ : UInt64)
  DataBlocked(UInt64)
  StreamDataBlocked(id~ : UInt64, max~ : UInt64)
  StreamsBlocked(bidi~ : Bool, max~ : UInt64)
  NewConnectionId(
    seq~ : UInt64,
    retire_prior_to~ : UInt64,
    conn_id~ : Bytes,
    reset_token~ : Bytes
  )
  RetireConnectionId(UInt64)
  PathChallenge(Bytes)
  PathResponse(Bytes)
  HandshakeDone
  // `frame_type` is `Some` for a transport-error close (0x1c) and `None` for an
  // application-error close (0x1d), which omits the triggering frame type.
  ConnectionClose(error_code~ : UInt64, frame_type~ : UInt64?, reason~ : Bytes)
} derive(Eq, Debug)

///|
/// Write an ACK frame's body — Largest Acknowledged, ACK Delay, the range count, First ACK
/// Range, then the `(Gap, ACK Range Length)` pairs. ACK and ACK_ECN share it; ACK_ECN adds
/// its counts after.
fn write_ack_body(
  buf : Buffer,
  largest : UInt64,
  delay : UInt64,
  first_range : UInt64,
  ranges : Array[(UInt64, UInt64)],
) -> Unit {
  buf.write_bytes(quic_varint_encode(largest)[:])
  buf.write_bytes(quic_varint_encode(delay)[:])
  buf.write_bytes(quic_varint_encode(ranges.length().to_uint64())[:])
  buf.write_bytes(quic_varint_encode(first_range)[:])
  for r in ranges {
    let (gap, len) = r
    buf.write_bytes(quic_varint_encode(gap)[:])
    buf.write_bytes(quic_varint_encode(len)[:])
  }
}

///|
/// Encode a frame to its wire bytes.
pub fn encode_frame(f : QuicFrame) -> Bytes {
  let buf = Buffer()
  match f {
    Padding(n) =>
      for _i = 0; _i < n; _i = _i + 1 {
        buf.write_byte(b'\x00')
      }
    Ping => buf.write_bytes(quic_varint_encode(1UL)[:])
    Crypto(offset~, data~) => {
      buf.write_bytes(quic_varint_encode(6UL)[:])
      buf.write_bytes(quic_varint_encode(offset)[:])
      buf.write_bytes(quic_varint_encode(data.length().to_uint64())[:])
      buf.write_bytes(data[:])
    }
    Stream(id~, offset~, fin~, data~) => {
      // Always emit with the OFF and LEN bits set (0x0e) so the frame is
      // self-delimiting; the FIN bit rides the low bit.
      let type_byte = 0x0e | (if fin { 1 } else { 0 })
      buf.write_bytes(quic_varint_encode(type_byte.to_uint64())[:])
      buf.write_bytes(quic_varint_encode(id)[:])
      buf.write_bytes(quic_varint_encode(offset)[:])
      buf.write_bytes(quic_varint_encode(data.length().to_uint64())[:])
      buf.write_bytes(data[:])
    }
    Ack(largest~, delay~, first_range~, ranges~) => {
      buf.write_bytes(quic_varint_encode(2UL)[:])
      write_ack_body(buf, largest, delay, first_range, ranges)
    }
    AckEcn(largest~, delay~, first_range~, ranges~, ect0~, ect1~, ce~) => {
      buf.write_bytes(quic_varint_encode(3UL)[:])
      write_ack_body(buf, largest, delay, first_range, ranges)
      buf.write_bytes(quic_varint_encode(ect0)[:])
      buf.write_bytes(quic_varint_encode(ect1)[:])
      buf.write_bytes(quic_varint_encode(ce)[:])
    }
    ResetStream(id~, error_code~, final_size~) => {
      buf.write_bytes(quic_varint_encode(4UL)[:])
      buf.write_bytes(quic_varint_encode(id)[:])
      buf.write_bytes(quic_varint_encode(error_code)[:])
      buf.write_bytes(quic_varint_encode(final_size)[:])
    }
    StopSending(id~, error_code~) => {
      buf.write_bytes(quic_varint_encode(5UL)[:])
      buf.write_bytes(quic_varint_encode(id)[:])
      buf.write_bytes(quic_varint_encode(error_code)[:])
    }
    NewToken(token~) => {
      buf.write_bytes(quic_varint_encode(7UL)[:])
      buf.write_bytes(quic_varint_encode(token.length().to_uint64())[:])
      buf.write_bytes(token[:])
    }
    MaxData(v) => {
      buf.write_bytes(quic_varint_encode(0x10UL)[:])
      buf.write_bytes(quic_varint_encode(v)[:])
    }
    MaxStreamData(id~, max~) => {
      buf.write_bytes(quic_varint_encode(0x11UL)[:])
      buf.write_bytes(quic_varint_encode(id)[:])
      buf.write_bytes(quic_varint_encode(max)[:])
    }
    MaxStreams(bidi~, max~) => {
      buf.write_bytes(quic_varint_encode(if bidi { 0x12UL } else { 0x13UL })[:])
      buf.write_bytes(quic_varint_encode(max)[:])
    }
    DataBlocked(v) => {
      buf.write_bytes(quic_varint_encode(0x14UL)[:])
      buf.write_bytes(quic_varint_encode(v)[:])
    }
    StreamDataBlocked(id~, max~) => {
      buf.write_bytes(quic_varint_encode(0x15UL)[:])
      buf.write_bytes(quic_varint_encode(id)[:])
      buf.write_bytes(quic_varint_encode(max)[:])
    }
    StreamsBlocked(bidi~, max~) => {
      buf.write_bytes(quic_varint_encode(if bidi { 0x16UL } else { 0x17UL })[:])
      buf.write_bytes(quic_varint_encode(max)[:])
    }
    NewConnectionId(seq~, retire_prior_to~, conn_id~, reset_token~) => {
      buf.write_bytes(quic_varint_encode(0x18UL)[:])
      buf.write_bytes(quic_varint_encode(seq)[:])
      buf.write_bytes(quic_varint_encode(retire_prior_to)[:])
      buf.write_byte(conn_id.length().to_byte())
      buf.write_bytes(conn_id[:])
      buf.write_bytes(reset_token[:])
    }
    RetireConnectionId(seq) => {
      buf.write_bytes(quic_varint_encode(0x19UL)[:])
      buf.write_bytes(quic_varint_encode(seq)[:])
    }
    PathChallenge(data) => {
      buf.write_bytes(quic_varint_encode(0x1aUL)[:])
      buf.write_bytes(data[:])
    }
    PathResponse(data) => {
      buf.write_bytes(quic_varint_encode(0x1bUL)[:])
      buf.write_bytes(data[:])
    }
    HandshakeDone => buf.write_bytes(quic_varint_encode(0x1eUL)[:])
    ConnectionClose(error_code~, frame_type~, reason~) => {
      match frame_type {
        Some(ft) => {
          buf.write_bytes(quic_varint_encode(0x1cUL)[:])
          buf.write_bytes(quic_varint_encode(error_code)[:])
          buf.write_bytes(quic_varint_encode(ft)[:])
        }
        None => {
          buf.write_bytes(quic_varint_encode(0x1dUL)[:])
          buf.write_bytes(quic_varint_encode(error_code)[:])
        }
      }
      buf.write_bytes(quic_varint_encode(reason.length().to_uint64())[:])
      buf.write_bytes(reason[:])
    }
  }
  buf.to_bytes()
}

///|
/// Parse an ACK frame's body starting at `start` in `b` — Largest Acknowledged, ACK Delay,
/// the range count, First ACK Range, then that many `(Gap, ACK Range Length)` pairs — with
/// the offset just past it. ACK (0x02) ends there; ACK_ECN (0x03) reads its three counts on.
fn parse_ack_body(
  b : BytesView,
  start : Int,
) -> (UInt64, UInt64, UInt64, Array[(UInt64, UInt64)], Int)? {
  let mut off = start
  guard quic_varint_decode(b[off:]) is Some((largest, l1)) else { return None }
  off = off + l1
  guard quic_varint_decode(b[off:]) is Some((delay, l2)) else { return None }
  off = off + l2
  guard quic_varint_decode(b[off:]) is Some((count, l3)) else { return None }
  off = off + l3
  guard quic_varint_decode(b[off:]) is Some((first_range, l4)) else {
    return None
  }
  off = off + l4
  let ranges : Array[(UInt64, UInt64)] = []
  for _i = 0; _i < count.to_int(); _i = _i + 1 {
    guard quic_varint_decode(b[off:]) is Some((gap, lg)) else { return None }
    off = off + lg
    guard quic_varint_decode(b[off:]) is Some((rlen, lr)) else { return None }
    off = off + lr
    ranges.push((gap, rlen))
  }
  Some((largest, delay, first_range, ranges, off))
}

///|
/// Parse one frame at the start of `b`, returning it and the bytes it occupied, or
/// `None` on a truncated frame or a type this brick does not yet decode. A PADDING
/// frame absorbs the whole run of leading zero bytes.
pub fn parse_frame(b : BytesView) -> (QuicFrame, Int)? {
  guard quic_varint_decode(b) is Some((ftype, tlen)) else { return None }
  match ftype {
    0UL => {
      let mut n = 0
      while n < b.length() && b[n].to_int() == 0 {
        n = n + 1
      }
      Some((Padding(n), n))
    }
    1UL => Some((Ping, tlen))
    2UL => {
      guard parse_ack_body(b, tlen)
        is Some((largest, delay, first_range, ranges, off)) else {
        return None
      }
      Some((Ack(largest~, delay~, first_range~, ranges~), off))
    }
    3UL => {
      guard parse_ack_body(b, tlen)
        is Some((largest, delay, first_range, ranges, body_end)) else {
        return None
      }
      let mut off = body_end
      guard quic_varint_decode(b[off:]) is Some((ect0, l1)) else { return None }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((ect1, l2)) else { return None }
      off = off + l2
      guard quic_varint_decode(b[off:]) is Some((ce, l3)) else { return None }
      off = off + l3
      Some(
        (
          AckEcn(largest~, delay~, first_range~, ranges~, ect0~, ect1~, ce~),
          off,
        ),
      )
    }
    6UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((offset, olen)) else {
        return None
      }
      off = off + olen
      guard quic_varint_decode(b[off:]) is Some((length, llen)) else {
        return None
      }
      off = off + llen
      let dlen = length.to_int()
      if b.length() < off + dlen {
        return None
      }
      let data = b[off:off + dlen].to_owned()
      off = off + dlen
      Some((Crypto(offset~, data~), off))
    }
    ty if ty >= 8UL && ty <= 15UL => {
      let ti = ty.to_int()
      let has_off = (ti & 0x04) != 0
      let has_len = (ti & 0x02) != 0
      let fin = (ti & 0x01) != 0
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((id, ilen)) else { return None }
      off = off + ilen
      let mut offset = 0UL
      if has_off {
        guard quic_varint_decode(b[off:]) is Some((o, olen)) else {
          return None
        }
        offset = o
        off = off + olen
      }
      let data = if has_len {
        guard quic_varint_decode(b[off:]) is Some((length, llen)) else {
          return None
        }
        off = off + llen
        let dlen = length.to_int()
        if b.length() < off + dlen {
          return None
        }
        let d = b[off:off + dlen].to_owned()
        off = off + dlen
        d
      } else {
        // No length field: the stream data runs to the end of the buffer.
        let d = b[off:].to_owned()
        off = b.length()
        d
      }
      Some((Stream(id~, offset~, fin~, data~), off))
    }
    4UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((id, l1)) else { return None }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((error_code, l2)) else {
        return None
      }
      off = off + l2
      guard quic_varint_decode(b[off:]) is Some((final_size, l3)) else {
        return None
      }
      off = off + l3
      Some((ResetStream(id~, error_code~, final_size~), off))
    }
    5UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((id, l1)) else { return None }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((error_code, l2)) else {
        return None
      }
      off = off + l2
      Some((StopSending(id~, error_code~), off))
    }
    7UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((length, ll)) else {
        return None
      }
      off = off + ll
      let n = length.to_int()
      if b.length() < off + n {
        return None
      }
      let token = b[off:off + n].to_owned()
      off = off + n
      Some((NewToken(token~), off))
    }
    0x10UL => {
      guard quic_varint_decode(b[tlen:]) is Some((v, vl)) else { return None }
      Some((MaxData(v), tlen + vl))
    }
    0x11UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((id, l1)) else { return None }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((max, l2)) else { return None }
      off = off + l2
      Some((MaxStreamData(id~, max~), off))
    }
    ty if ty == 0x12UL || ty == 0x13UL => {
      guard quic_varint_decode(b[tlen:]) is Some((max, vl)) else { return None }
      Some((MaxStreams(bidi=ty == 0x12UL, max~), tlen + vl))
    }
    0x14UL => {
      guard quic_varint_decode(b[tlen:]) is Some((v, vl)) else { return None }
      Some((DataBlocked(v), tlen + vl))
    }
    0x15UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((id, l1)) else { return None }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((max, l2)) else { return None }
      off = off + l2
      Some((StreamDataBlocked(id~, max~), off))
    }
    ty if ty == 0x16UL || ty == 0x17UL => {
      guard quic_varint_decode(b[tlen:]) is Some((max, vl)) else { return None }
      Some((StreamsBlocked(bidi=ty == 0x16UL, max~), tlen + vl))
    }
    0x18UL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((seq, l1)) else { return None }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((retire_prior_to, l2)) else {
        return None
      }
      off = off + l2
      if b.length() < off + 1 {
        return None
      }
      let cid_len = b[off].to_int()
      off = off + 1
      if b.length() < off + cid_len + 16 {
        return None
      }
      let conn_id = b[off:off + cid_len].to_owned()
      off = off + cid_len
      let reset_token = b[off:off + 16].to_owned()
      off = off + 16
      Some(
        (NewConnectionId(seq~, retire_prior_to~, conn_id~, reset_token~), off),
      )
    }
    0x19UL => {
      guard quic_varint_decode(b[tlen:]) is Some((seq, vl)) else { return None }
      Some((RetireConnectionId(seq), tlen + vl))
    }
    0x1aUL => {
      if b.length() < tlen + 8 {
        return None
      }
      Some((PathChallenge(b[tlen:tlen + 8].to_owned()), tlen + 8))
    }
    0x1bUL => {
      if b.length() < tlen + 8 {
        return None
      }
      Some((PathResponse(b[tlen:tlen + 8].to_owned()), tlen + 8))
    }
    0x1eUL => Some((HandshakeDone, tlen))
    0x1cUL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((error_code, l1)) else {
        return None
      }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((ft, l2)) else { return None }
      off = off + l2
      guard quic_varint_decode(b[off:]) is Some((rlen, l3)) else { return None }
      off = off + l3
      let n = rlen.to_int()
      if b.length() < off + n {
        return None
      }
      let reason = b[off:off + n].to_owned()
      off = off + n
      Some((ConnectionClose(error_code~, frame_type=Some(ft), reason~), off))
    }
    0x1dUL => {
      let mut off = tlen
      guard quic_varint_decode(b[off:]) is Some((error_code, l1)) else {
        return None
      }
      off = off + l1
      guard quic_varint_decode(b[off:]) is Some((rlen, l2)) else { return None }
      off = off + l2
      let n = rlen.to_int()
      if b.length() < off + n {
        return None
      }
      let reason = b[off:off + n].to_owned()
      off = off + n
      Some((ConnectionClose(error_code~, frame_type=None, reason~), off))
    }
    _ => None
  }
}

///|
pub extend QuicFrame with Debug::{to_repr}

///|
pub extend QuicFrame with Eq::{not_equal, equal}
