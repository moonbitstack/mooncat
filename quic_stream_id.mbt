// QUIC stream identifiers (RFC 9000 §2.1): a stream ID is a variable-length integer
// whose two least-significant bits classify the stream — bit 0 is the initiator (client
// 0, server 1) and bit 1 the directionality (bidirectional 0, unidirectional 1) — and
// whose remaining bits are the stream's sequence number within its type. Streams of one
// type are created in ascending ID order, four apart. This is the pure classification
// and generation the stream manager routes on.

///|
/// Which endpoint opened a stream (RFC 9000 §2.1).
pub(all) enum StreamInitiator {
  Client
  Server
} derive(Eq, Debug)

///|
/// Whether a stream carries data one way or both (RFC 9000 §2.1).
pub(all) enum StreamDirection {
  Bidirectional
  Unidirectional
} derive(Eq, Debug)

///|
/// The endpoint that initiated stream `id` (bit 0).
pub fn stream_initiator(id : UInt64) -> StreamInitiator {
  if (id & 1) == 0 {
    Client
  } else {
    Server
  }
}

///|
/// The directionality of stream `id` (bit 1).
pub fn stream_direction(id : UInt64) -> StreamDirection {
  if (id & 2) == 0 {
    Bidirectional
  } else {
    Unidirectional
  }
}

///|
/// Whether stream `id` is bidirectional.
pub fn stream_is_bidi(id : UInt64) -> Bool {
  (id & 2) == 0
}

///|
/// Whether stream `id` was opened by the client.
pub fn stream_is_client_initiated(id : UInt64) -> Bool {
  (id & 1) == 0
}

///|
/// The stream's sequence number within its type (the ID with its low two bits removed).
pub fn stream_sequence(id : UInt64) -> UInt64 {
  id >> 2
}

///|
/// The stream ID for the `seq`-th (0-based) stream of the given initiator and direction.
pub fn stream_id_of(
  initiator : StreamInitiator,
  direction : StreamDirection,
  seq : UInt64,
) -> UInt64 {
  let init_bit = match initiator {
    Client => 0UL
    Server => 1UL
  }
  let dir_bit = match direction {
    Bidirectional => 0UL
    Unidirectional => 2UL
  }
  (seq << 2) | dir_bit | init_bit
}

///|
/// Whether stream `id` was opened by this endpoint, given whether it is the server.
pub fn stream_is_locally_initiated(id : UInt64, is_server : Bool) -> Bool {
  match stream_initiator(id) {
    Client => !is_server
    Server => is_server
  }
}

///|
/// Whether this endpoint may send on stream `id`: it may send on a stream it opened, or
/// on a bidirectional stream its peer opened; it may not send on a peer-opened
/// unidirectional (receive-only) stream (RFC 9000 §2.1, §3).
pub fn stream_is_writable(id : UInt64, is_server : Bool) -> Bool {
  stream_is_locally_initiated(id, is_server) || stream_is_bidi(id)
}

///|
pub extend StreamDirection with Debug::{to_repr}

///|
pub extend StreamDirection with Eq::{not_equal, equal}

///|
pub extend StreamInitiator with Debug::{to_repr}

///|
pub extend StreamInitiator with Eq::{not_equal, equal}
