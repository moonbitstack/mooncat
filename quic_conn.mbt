// A QUIC connection's numbering and handshake-input core (RFC 9000 §12.3, RFC 9001
// §4.1.3). A connection keeps three independent packet-number spaces — Initial,
// Handshake, and Application (1-RTT) — and a CRYPTO byte stream per encryption level,
// each ordered on its own. This skeleton routes a received packet's number to its space
// (for acknowledgement) and a received CRYPTO frame to its level's reassembler (yielding
// the contiguous TLS handshake bytes to feed the handshake), and hands out send-side
// packet numbers per space. It holds no keys or socket — the key schedule and the async
// UDP transport wrap this pure core.

///|
/// A QUIC encryption level / packet-number space (RFC 9001 §4.1.1). 0-RTT shares the
/// Application space, so the three long-lived spaces are Initial, Handshake, and
/// Application.
pub(all) enum QuicLevel {
  Initial
  Handshake
  Application
} derive(Eq, Debug)

///|
/// A QUIC connection's per-space numbering/ACK state and per-level CRYPTO streams.
pub struct QuicConnection {
  is_server : Bool
  initial_space : PacketNumberSpace
  handshake_space : PacketNumberSpace
  application_space : PacketNumberSpace
  initial_crypto : StreamReassembler
  handshake_crypto : StreamReassembler
  application_crypto : StreamReassembler
}

///|
/// A fresh connection (client or server) with empty spaces and CRYPTO streams.
pub fn QuicConnection::new(is_server : Bool) -> QuicConnection {
  {
    is_server,
    initial_space: PacketNumberSpace::new(),
    handshake_space: PacketNumberSpace::new(),
    application_space: PacketNumberSpace::new(),
    initial_crypto: StreamReassembler::new(),
    handshake_crypto: StreamReassembler::new(),
    application_crypto: StreamReassembler::new(),
  }
}

///|
/// Whether this endpoint is the server.
pub fn QuicConnection::is_server(self : QuicConnection) -> Bool {
  self.is_server
}

///|
/// The packet-number space for `level`.
pub fn QuicConnection::space(
  self : QuicConnection,
  level : QuicLevel,
) -> PacketNumberSpace {
  match level {
    Initial => self.initial_space
    Handshake => self.handshake_space
    Application => self.application_space
  }
}

///|
/// The CRYPTO reassembler for `level`.
pub fn QuicConnection::crypto_stream(
  self : QuicConnection,
  level : QuicLevel,
) -> StreamReassembler {
  match level {
    Initial => self.initial_crypto
    Handshake => self.handshake_crypto
    Application => self.application_crypto
  }
}

///|
/// Allocate the next packet number to send at `level`.
pub fn QuicConnection::next_packet_number(
  self : QuicConnection,
  level : QuicLevel,
) -> Int64 {
  self.space(level).next_packet_number()
}

///|
/// Record that a packet numbered `pn` arrived at `level`; `ack_eliciting` marks one that
/// must be acknowledged.
pub fn QuicConnection::on_packet_received(
  self : QuicConnection,
  level : QuicLevel,
  pn : Int64,
  ack_eliciting : Bool,
) -> Unit {
  self.space(level).on_packet_received(pn, ack_eliciting)
}

///|
/// Record the peer's acknowledgement of up to `largest` at `level`.
pub fn QuicConnection::on_ack_received(
  self : QuicConnection,
  level : QuicLevel,
  largest : Int64,
) -> Unit {
  self.space(level).on_ack_received(largest)
}

///|
/// Build the ACK frame owed at `level`, or `None` if nothing has been received there.
pub fn QuicConnection::build_ack(
  self : QuicConnection,
  level : QuicLevel,
  ack_delay : UInt64,
) -> QuicFrame? {
  self.space(level).build_ack(ack_delay)
}

///|
/// Feed a CRYPTO frame's `data` at `offset` and `level` into that level's handshake
/// stream, returning the newly contiguous TLS handshake bytes now readable (empty while
/// an earlier gap is still outstanding). CRYPTO streams carry no fin.
pub fn QuicConnection::on_crypto_frame(
  self : QuicConnection,
  level : QuicLevel,
  offset : UInt64,
  data : Bytes,
) -> Bytes raise ReassemblyError {
  let stream = self.crypto_stream(level)
  stream.insert(offset, data, false)
  stream.read()
}

///|
pub extend QuicLevel with Debug::{to_repr}

///|
pub extend QuicLevel with Eq::{not_equal, equal}
