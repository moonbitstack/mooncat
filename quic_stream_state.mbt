// QUIC stream state machines (RFC 9000 §3). A stream has independent send and receive
// halves, each a small state machine. The sender moves Ready -> Send -> Data Sent ->
// Data Recvd as it writes and its data is acknowledged, or into Reset Sent -> Reset
// Recvd when it resets. The receiver moves Recv -> Size Known -> Data Recvd -> Data Read
// as data and the final size arrive and the application reads, or into Reset Recvd ->
// Reset Read on an incoming reset. These are the pure transitions the stream manager
// drives; an illegal transition raises.

///|
/// The send half's state (RFC 9000 §3.1).
pub(all) enum SendStreamState {
  Ready
  Send
  DataSent
  DataRecvd
  ResetSent
  ResetRecvd
} derive(Eq, Debug)

///|
/// A send-half event: writing a STREAM frame (with `fin` on the last), all sent data
/// being acknowledged, sending a RESET_STREAM, or that reset being acknowledged.
pub(all) enum SendStreamEvent {
  Write(fin~ : Bool)
  AllAcked
  ResetStream
  ResetAcked
} derive(Eq, Debug)

///|
/// An illegal stream-state transition.
pub suberror StreamStateError {
  StreamStateError(String)
}

///|
/// The next send state for `event` in `state` (RFC 9000 §3.1). A stream may be reset
/// from any pre-terminal state; writing after a terminal or reset state is illegal.
pub fn send_stream_next(
  state : SendStreamState,
  event : SendStreamEvent,
) -> SendStreamState raise StreamStateError {
  match (state, event) {
    (Ready, Write(fin~)) | (Send, Write(fin~)) =>
      if fin {
        DataSent
      } else {
        Send
      }
    (DataSent, AllAcked) => DataRecvd
    (Ready, ResetStream) | (Send, ResetStream) | (DataSent, ResetStream) =>
      ResetSent
    (ResetSent, ResetAcked) => ResetRecvd
    _ => raise StreamStateError("illegal send-stream transition")
  }
}

///|
/// The receive half's state (RFC 9000 §3.2).
pub(all) enum RecvStreamState {
  Recv
  SizeKnown
  DataReceived
  DataRead
  ResetReceived
  ResetRead
} derive(Eq, Debug)

///|
/// A receive-half event: a STREAM frame arriving (with `fin` fixing the final size), all
/// data up to the final size received, the application reading all data, a RESET_STREAM
/// arriving, or the application being notified of that reset.
pub(all) enum RecvStreamEvent {
  Receive(fin~ : Bool)
  AllReceived
  AppRead
  ReceiveReset
  AppReadReset
} derive(Eq, Debug)

///|
/// The next receive state for `event` in `state` (RFC 9000 §3.2). A stream may be reset
/// from any pre-terminal state; the read events apply only once the data or reset has
/// fully arrived.
pub fn recv_stream_next(
  state : RecvStreamState,
  event : RecvStreamEvent,
) -> RecvStreamState raise StreamStateError {
  match (state, event) {
    (Recv, Receive(fin~)) => if fin { SizeKnown } else { Recv }
    (SizeKnown, AllReceived) => DataReceived
    (DataReceived, AppRead) => DataRead
    (Recv, ReceiveReset)
    | (SizeKnown, ReceiveReset)
    | (DataReceived, ReceiveReset) => ResetReceived
    (ResetReceived, AppReadReset) => ResetRead
    _ => raise StreamStateError("illegal recv-stream transition")
  }
}

///|
pub extend RecvStreamEvent with Debug::{to_repr}

///|
pub extend RecvStreamEvent with Eq::{not_equal, equal}

///|
pub extend RecvStreamState with Debug::{to_repr}

///|
pub extend RecvStreamState with Eq::{not_equal, equal}

///|
pub extend SendStreamEvent with Debug::{to_repr}

///|
pub extend SendStreamEvent with Eq::{not_equal, equal}

///|
pub extend SendStreamState with Debug::{to_repr}

///|
pub extend SendStreamState with Eq::{not_equal, equal}
