// The TLS 1.3 client handshake state machine (RFC 8446 Appendix A.1). After sending its
// ClientHello a client walks WAIT_SH -> WAIT_EE -> WAIT_CERT_CR -> WAIT_CERT ->
// WAIT_CV -> WAIT_FINISHED -> CONNECTED as it receives the server's flight, branching
// past the certificate messages on a PSK/resumption handshake. This is the pure
// transition the handshake driver runs on each received message; an out-of-order
// message raises. (The full-handshake, certificate-authenticated path is modelled; the
// certificate-request branch is included.)

///|
/// A client's handshake state (RFC 8446 A.1), after the ClientHello has been sent.
pub(all) enum TlsClientState {
  WaitServerHello
  WaitEncryptedExtensions
  WaitCertCertReq
  WaitCert
  WaitCertVerify
  WaitFinished
  Connected
} derive(Eq, Debug)

///|
/// The initial state, having just sent the ClientHello (START -> WAIT_SH; sending the
/// ClientHello is the client's output action, not a received message).
pub fn TlsClientState::new() -> TlsClientState {
  WaitServerHello
}

///|
/// TLS 1.3 handshake message types (RFC 8446 §4).
let tls_hs_server_hello : Int = 2

///|
let tls_hs_encrypted_extensions : Int = 8

///|
let tls_hs_certificate : Int = 11

///|
let tls_hs_certificate_request : Int = 13

///|
let tls_hs_certificate_verify : Int = 15

///|
let tls_hs_finished : Int = 20

///|
/// The next client state on receiving a handshake message of `msg_type` (RFC 8446 A.1).
/// A message that does not belong in the current state raises the unexpected_message alert
/// (§6.2).
pub fn tls_client_next(
  state : TlsClientState,
  msg_type : Int,
) -> TlsClientState raise TlsAlert {
  match (state, msg_type) {
    (WaitServerHello, t) if t == tls_hs_server_hello => WaitEncryptedExtensions
    (WaitEncryptedExtensions, t) if t == tls_hs_encrypted_extensions =>
      WaitCertCertReq
    // After EncryptedExtensions the server may request a client certificate, or send
    // its own Certificate directly.
    (WaitCertCertReq, t) if t == tls_hs_certificate_request => WaitCert
    (WaitCertCertReq, t) if t == tls_hs_certificate => WaitCertVerify
    (WaitCert, t) if t == tls_hs_certificate => WaitCertVerify
    (WaitCertVerify, t) if t == tls_hs_certificate_verify => WaitFinished
    (WaitFinished, t) if t == tls_hs_finished => Connected
    _ => raise tls_fatal(tls_alert_unexpected_message)
  }
}

///|
pub extend TlsClientState with Debug::{to_repr}

///|
pub extend TlsClientState with Eq::{not_equal, equal}
