// Which HTTP/3 frames are permitted on which stream (RFC 9114 §7.2): the codec decodes any frame,
// but an endpoint must reject one that appears where the protocol does not allow it (an
// H3_FRAME_UNEXPECTED connection error). DATA/HEADERS ride request and push streams; SETTINGS,
// GOAWAY, MAX_PUSH_ID, and CANCEL_PUSH ride only the control stream; PUSH_PROMISE rides a request
// stream; a greased reserved type is ignored anywhere; and the frame types HTTP/3 reserves because
// HTTP/2 used them (PRIORITY 0x02, PING 0x06, WINDOW_UPDATE 0x08, CONTINUATION 0x09) are a
// connection error on any stream (§7.2.1, §11.2.1).

///|
/// The stream a frame was received on, for the purpose of frame-placement rules (RFC 9114 §6.2).
pub(all) enum Http3StreamCtx {
  ControlCtx
  RequestCtx
  PushCtx
} derive(Eq, Debug)

///|
/// Whether `frame` is permitted on a stream of kind `ctx` (RFC 9114 §7.2).
pub fn http3_frame_allowed(frame : Http3Frame, ctx : Http3StreamCtx) -> Bool {
  match frame {
    ReservedHttp2(_) => false
    Data(_) | Headers(_) => ctx == RequestCtx || ctx == PushCtx
    Settings(_) | GoAway(_) | MaxPushId(_) | CancelPush(_) => ctx == ControlCtx
    PushPromise(_, _) => ctx == RequestCtx
    Reserved(_, _) => true
  }
}

///|
/// Raise `Http3FrameError` (H3_FRAME_UNEXPECTED) when `frame` is not permitted on `ctx`.
pub fn http3_check_frame(
  frame : Http3Frame,
  ctx : Http3StreamCtx,
) -> Unit raise Http3FrameError {
  if !http3_frame_allowed(frame, ctx) {
    raise Http3FrameError(
      "frame not permitted on this stream (RFC 9114 §7.2, H3_FRAME_UNEXPECTED)",
    )
  }
}

///|
pub extend Http3StreamCtx with Debug::{to_repr}

///|
pub extend Http3StreamCtx with Eq::{not_equal, equal}
