// The HTTP/3 SETTINGS an endpoint advertises on its control stream (RFC 9114 §7.2.4): the QPACK
// dynamic-table capacity and blocked-stream limit the peer may use when encoding header fields,
// and the largest header section this endpoint will accept. A control stream must open with a
// SETTINGS frame; this names those settings and reads them off the control stream a peer sends —
// the negotiation curl performs before any request.

///|
/// SETTINGS_QPACK_MAX_TABLE_CAPACITY (RFC 9204 §5).
pub let h3_settings_qpack_max_table_capacity : UInt64 = 0x01

///|
/// SETTINGS_MAX_FIELD_SECTION_SIZE (RFC 9114 §7.2.4.1).
pub let h3_settings_max_field_section_size : UInt64 = 0x06

///|
/// SETTINGS_QPACK_BLOCKED_STREAMS (RFC 9204 §5).
pub let h3_settings_qpack_blocked_streams : UInt64 = 0x07

///|
/// An endpoint's HTTP/3 settings.
pub(all) struct Http3Settings {
  qpack_max_table_capacity : UInt64
  max_field_section_size : UInt64
  qpack_blocked_streams : UInt64
} derive(Eq, Debug)

///|
/// Settings with the given QPACK table capacity, maximum field section size, and blocked-stream
/// limit.
pub fn Http3Settings::new(
  qpack_max_table_capacity : UInt64,
  max_field_section_size : UInt64,
  qpack_blocked_streams : UInt64,
) -> Http3Settings {
  { qpack_max_table_capacity, max_field_section_size, qpack_blocked_streams, }
}

///|
/// The `(identifier, value)` pairs to carry in a SETTINGS frame.
pub fn Http3Settings::to_pairs(self : Http3Settings) -> Array[(UInt64, UInt64)] {
  [
    (h3_settings_qpack_max_table_capacity, self.qpack_max_table_capacity),
    (h3_settings_max_field_section_size, self.max_field_section_size),
    (h3_settings_qpack_blocked_streams, self.qpack_blocked_streams),
  ]
}

///|
/// Read settings from received `(identifier, value)` pairs, taking the value for each known
/// identifier (0 when absent) and ignoring unknown ones (RFC 9114 §7.2.4.1 grease tolerance).
pub fn Http3Settings::from_pairs(
  pairs : Array[(UInt64, UInt64)],
) -> Http3Settings {
  let mut qmtc = 0UL
  let mut mfss = 0UL
  let mut qbs = 0UL
  for p in pairs {
    if p.0 == h3_settings_qpack_max_table_capacity {
      qmtc = p.1
    } else if p.0 == h3_settings_max_field_section_size {
      mfss = p.1
    } else if p.0 == h3_settings_qpack_blocked_streams {
      qbs = p.1
    }
  }
  {
    qpack_max_table_capacity: qmtc,
    max_field_section_size: mfss,
    qpack_blocked_streams: qbs,
  }
}

///|
/// Decode an endpoint's control stream (RFC 9114 §6.2.1): its type prefix must be the control
/// stream, and its first frame a SETTINGS frame, whose settings are returned. `None` if the
/// stream is not a control stream or does not open with SETTINGS. Raises on a malformed frame.
pub fn http3_decode_control_stream(
  input : BytesView,
) -> Http3Settings? raise Http3FrameError {
  match http3_decode_stream_type(input) {
    Some((ControlStream, consumed)) => {
      let (frames, _) = http3_frame_decode_all(input[consumed:].to_owned())
      if frames.length() > 0 {
        match frames[0] {
          Settings(pairs) => Some(Http3Settings::from_pairs(pairs))
          _ => None
        }
      } else {
        None
      }
    }
    _ => None
  }
}

///|
pub extend Http3Settings with Debug::{to_repr}

///|
pub extend Http3Settings with Eq::{not_equal, equal}
