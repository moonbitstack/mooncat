// The HTTP/3 connection setup and unidirectional-stream demultiplexer (RFC 9114 §6.2): once the
// QUIC handshake completes, each endpoint opens a control stream and sends its SETTINGS first, then
// classifies every unidirectional stream the peer opens — control (whose SETTINGS it reads and
// keeps), the two QPACK instruction streams, a server push stream, or a reserved/greased type it
// ignores. This is the connection state that sits above the QUIC streams and drives the frame and
// QPACK codecs; the live QUIC connection supplies the stream bytes.

///|
/// Which side of the connection an endpoint is (RFC 9114 §3.1): a server must not receive a push
/// stream, so the role decides whether one is a protocol violation.
pub(all) enum Http3Role {
  ClientSide
  ServerSide
} derive(Eq, Debug)

///|
/// A connection-level HTTP/3 error (RFC 9114 §8): a broken control stream or a stream a peer must
/// not have opened.
pub suberror Http3ConnError {
  Http3ConnError(String)
}

///|
/// The result of accepting a peer's unidirectional stream: the control stream carries the peer's
/// SETTINGS, the QPACK streams carry table instructions, a push stream carries its id, and an
/// unrecognized type is reserved/greased.
pub(all) enum Http3UniEvent {
  ControlEstablished(Http3Settings)
  QpackEncoder
  QpackDecoder
  Push(UInt64)
  Reserved(UInt64)
} derive(Eq, Debug)

///|
/// One endpoint of an HTTP/3 connection: its role, the settings it advertises, and — once the peer
/// opens its control stream — the peer's settings.
pub struct Http3Conn {
  role : Http3Role
  local_settings : Http3Settings
  mut peer_settings : Http3Settings?
  mut control_seen : Bool
}

///|
/// A connection that will advertise `local_settings`.
pub fn Http3Conn::new(
  role : Http3Role,
  local_settings : Http3Settings,
) -> Http3Conn {
  { role, local_settings, peer_settings: None, control_seen: false, }
}

///|
/// The bytes to write when opening our control stream: the control-stream type then our SETTINGS
/// frame, which a control stream must send first (RFC 9114 §6.2.1).
pub fn Http3Conn::open_control_stream(self : Http3Conn) -> Bytes {
  http3_encode_control_stream(self.local_settings.to_pairs())
}

///|
/// Accept a peer's unidirectional stream from its opening bytes: classify it and, for the control
/// stream, decode and keep the peer's SETTINGS. A second control stream, a control stream not
/// opening with SETTINGS, and a server receiving a push stream are all connection errors
/// (RFC 9114 §6.2).
pub fn Http3Conn::accept_uni_stream(
  self : Http3Conn,
  bytes : Bytes,
) -> Http3UniEvent raise {
  guard http3_decode_stream_type(bytes[:]) is Some((stream_type, _)) else {
    raise Http3ConnError("truncated unidirectional stream header")
  }
  match stream_type {
    ControlStream => {
      if self.control_seen {
        raise Http3ConnError(
          "a second control stream is a connection error (RFC 9114 §6.2.1)",
        )
      }
      let settings = match http3_decode_control_stream(bytes[:]) {
        Some(s) => s
        None =>
          raise Http3ConnError(
            "a control stream must open with a SETTINGS frame",
          )
      }
      self.control_seen = true
      self.peer_settings = Some(settings)
      ControlEstablished(settings)
    }
    QpackEncoderStream => QpackEncoder
    QpackDecoderStream => QpackDecoder
    PushStream(id) => {
      if self.role == ServerSide {
        raise Http3ConnError(
          "a server must not receive a push stream (RFC 9114 §6.2.2)",
        )
      }
      Push(id)
    }
    ReservedStream(t) => Reserved(t)
  }
}

///|
/// Whether the peer's control-stream SETTINGS have been received (connection setup complete).
pub fn Http3Conn::settings_established(self : Http3Conn) -> Bool {
  self.peer_settings is Some(_)
}

///|
/// The peer's advertised settings, once its control stream has been accepted.
pub fn Http3Conn::peer_settings(self : Http3Conn) -> Http3Settings? {
  self.peer_settings
}

///|
pub extend Http3Role with Debug::{to_repr}

///|
pub extend Http3Role with Eq::{not_equal, equal}

///|
pub extend Http3UniEvent with Debug::{to_repr}

///|
pub extend Http3UniEvent with Eq::{not_equal, equal}
