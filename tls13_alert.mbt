// The TLS 1.3 alert protocol (RFC 8446 §6): the two bytes — a level and a description — an
// endpoint sends to say why it is giving up. The description is the only diagnostic the peer
// ever receives, so it is what makes a failed handshake readable from the other end; a
// connection that just goes away tells the client nothing. TLS 1.3 treats every alert as fatal
// except close_notify and user_canceled. This is the §6 table, the codec, and the error the
// handshake raises where it used to return a silent `None`.

///|
/// The warning alert level (RFC 8446 §6). TLS 1.3 acts on the description rather than the
/// level: only close_notify and user_canceled leave the connection usable, whichever level
/// carries them.
pub let tls_alert_level_warning : Int = 1

///|
/// The fatal alert level (RFC 8446 §6): the sender closes the connection immediately and
/// discards the keys.
pub let tls_alert_level_fatal : Int = 2

///|
/// Alert descriptions (RFC 8446 §6.1, §6.2). Only the codes the RFC assigns are named; an
/// unrecognized description on the wire is still carried through as its number.
///
/// The sender is done writing — a clean shutdown, not a failure.
pub let tls_alert_close_notify : Int = 0

///|
/// A message arrived that the state machine was not waiting for, or out of order.
pub let tls_alert_unexpected_message : Int = 10

///|
/// A record failed to decrypt or to authenticate.
pub let tls_alert_bad_record_mac : Int = 20

///|
/// A record's plaintext ran past the 2^14-octet limit.
pub let tls_alert_record_overflow : Int = 22

///|
/// No parameters both endpoints support — no shared group, cipher suite, or signature scheme.
pub let tls_alert_handshake_failure : Int = 40

///|
/// A certificate was corrupt, or carried a signature that did not verify.
pub let tls_alert_bad_certificate : Int = 42

///|
/// The certificate was of a type the receiver does not support.
pub let tls_alert_unsupported_certificate : Int = 43

///|
/// The signer revoked the certificate.
pub let tls_alert_certificate_revoked : Int = 44

///|
/// The certificate has expired, or is not yet valid.
pub let tls_alert_certificate_expired : Int = 45

///|
/// Some other problem with the certificate, with no more precise description to give.
pub let tls_alert_certificate_unknown : Int = 46

///|
/// A field was well-formed on its own but its value contradicts the rest of the message.
pub let tls_alert_illegal_parameter : Int = 47

///|
/// The chain verified but ended at no trusted anchor.
pub let tls_alert_unknown_ca : Int = 48

///|
/// The certificate verified, but the receiver declines to proceed with this peer.
pub let tls_alert_access_denied : Int = 49

///|
/// A message could not be parsed: a length overran what was there, or a field was out of range.
pub let tls_alert_decode_error : Int = 50

///|
/// A handshake signature or a Finished MAC failed to verify.
pub let tls_alert_decrypt_error : Int = 51

///|
/// The peer offered no protocol version this endpoint supports.
pub let tls_alert_protocol_version : Int = 70

///|
/// handshake_failure, narrowed: the peer's parameters are weaker than this endpoint accepts.
pub let tls_alert_insufficient_security : Int = 71

///|
/// A local failure, unrelated to the peer or to the correctness of the protocol.
pub let tls_alert_internal_error : Int = 80

///|
/// The peer fell back to an older version for a reason this endpoint does not accept.
pub let tls_alert_inappropriate_fallback : Int = 86

///|
/// The handshake is being abandoned for a reason outside the protocol.
pub let tls_alert_user_canceled : Int = 90

///|
/// A message lacked an extension RFC 8446 §9.2 makes mandatory for it.
pub let tls_alert_missing_extension : Int = 109

///|
/// A server sent back an extension the ClientHello never offered.
pub let tls_alert_unsupported_extension : Int = 110

///|
/// No server exists for the name the client's server_name extension asked for.
pub let tls_alert_unrecognized_name : Int = 112

///|
/// The stapled OCSP response was invalid.
pub let tls_alert_bad_certificate_status_response : Int = 113

///|
/// The PSK identity the client offered is unknown and no full handshake will be run instead.
pub let tls_alert_unknown_psk_identity : Int = 115

///|
/// The client sent no certificate where the server requires one.
pub let tls_alert_certificate_required : Int = 116

///|
/// None of the ALPN protocols the client offered is one this server speaks (RFC 7301 §3.2).
pub let tls_alert_no_application_protocol : Int = 120

///|
/// An alert (RFC 8446 §6). It is the error the handshake raises, so a caller catches the
/// reason and the two bytes to send in one value.
pub(all) suberror TlsAlert {
  TlsAlert(level~ : Int, description~ : Int)
} derive(Eq, Debug)

///|
/// A fatal alert carrying `description` — every way a TLS 1.3 handshake can fail.
pub fn tls_fatal(description : Int) -> TlsAlert {
  TlsAlert(level=tls_alert_level_fatal, description~)
}

///|
/// A warning alert carrying `description`: close_notify and user_canceled, the two the peer
/// may act on without tearing the connection down.
pub fn tls_warning(description : Int) -> TlsAlert {
  TlsAlert(level=tls_alert_level_warning, description~)
}

///|
/// The two bytes an alert goes on the wire as (RFC 8446 §6).
pub fn tls_encode_alert(alert : TlsAlert) -> Bytes {
  let TlsAlert(level~, description~) = alert
  let buf = Buffer()
  buf.write_byte((level & 0xff).to_byte())
  buf.write_byte((description & 0xff).to_byte())
  buf.to_bytes()
}

///|
/// Read an alert back off the wire, or `None` if fewer than two bytes are there.
pub fn tls_decode_alert(view : BytesView) -> TlsAlert? {
  if view.length() < 2 {
    return None
  }
  Some(TlsAlert(level=view[0].to_int(), description=view[1].to_int()))
}

///|
/// Whether an alert ends the connection (RFC 8446 §6.1): everything but close_notify and
/// user_canceled, whatever level the sender put on it.
pub fn tls_alert_is_fatal(alert : TlsAlert) -> Bool {
  let TlsAlert(description~, ..) = alert
  description != tls_alert_close_notify &&
  description != tls_alert_user_canceled
}

///|
pub extend TlsAlert with Debug::{to_repr}

///|
pub extend TlsAlert with Eq::{not_equal, equal}
