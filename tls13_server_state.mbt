// The TLS 1.3 server handshake state machine (RFC 8446 Appendix A.2). A server receives
// the ClientHello, negotiates and sends its whole flight (ServerHello, EncryptedExten-
// sions, an optional CertificateRequest, Certificate, CertificateVerify, Finished), then
// waits for the client's second flight: the client Certificate and CertificateVerify
// when client authentication was requested, and finally the client Finished. This models
// the full-handshake, certificate-authenticated path a mooncat server drives.

///|
/// A server's handshake state (RFC 8446 A.2).
pub(all) enum TlsServerState {
  Start
  RecvdClientHello
  WaitCert
  WaitCertVerify
  WaitFinished
  Connected
} derive(Eq, Debug)

///|
/// The initial state, awaiting the ClientHello.
pub fn TlsServerState::new() -> TlsServerState {
  Start
}

///|
/// The ClientHello handshake type (RFC 8446 §4), which the shared constants omit.
let tls_hs_client_hello : Int = 1

///|
/// The next server state on receiving a handshake message of `msg_type` (RFC 8446 A.2):
/// the ClientHello that opens the handshake, then the client's Certificate,
/// CertificateVerify, and Finished. A message that does not belong in the current state
/// raises the unexpected_message alert (§6.2), which is what the peer is owed.
pub fn tls_server_recv(
  state : TlsServerState,
  msg_type : Int,
) -> TlsServerState raise TlsAlert {
  match (state, msg_type) {
    (Start, t) if t == tls_hs_client_hello => RecvdClientHello
    (WaitCert, t) if t == tls_hs_certificate => WaitCertVerify
    (WaitCertVerify, t) if t == tls_hs_certificate_verify => WaitFinished
    (WaitFinished, t) if t == tls_hs_finished => Connected
    _ => raise tls_fatal(tls_alert_unexpected_message)
  }
}

///|
/// The server's own action after receiving the ClientHello: it negotiates and sends its
/// whole flight, then waits for the client's Certificate (when `request_client_cert` is
/// set) or straight for the client Finished. Sending the flight in any other state is this
/// endpoint's own bug, not the peer's, so it raises internal_error (§6.2).
pub fn tls_server_send_flight(
  state : TlsServerState,
  request_client_cert : Bool,
) -> TlsServerState raise TlsAlert {
  match state {
    RecvdClientHello =>
      if request_client_cert {
        WaitCert
      } else {
        WaitFinished
      }
    _ => raise tls_fatal(tls_alert_internal_error)
  }
}

///|
pub extend TlsServerState with Debug::{to_repr}

///|
pub extend TlsServerState with Eq::{not_equal, equal}
