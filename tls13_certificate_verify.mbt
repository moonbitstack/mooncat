// The TLS 1.3 CertificateVerify message (RFC 8446 §4.4.3): after its Certificate, an endpoint
// proves it holds the certificate's private key by signing the handshake transcript. The
// signed content is 64 octets of 0x20, a context string that separates client and server
// signatures (and TLS 1.3 from earlier versions), a 0x00 separator, and the transcript hash
// through the Certificate message. The message body is the SignatureScheme and the signature;
// mooncat signs with ecdsa_secp256r1_sha256 (ES256), so a real client — curl included — can
// authenticate the server. This turns the handshake's Certificate/CertificateVerify from
// carried placeholders into a real, verifiable server signature.

///|
/// The ecdsa_secp256r1_sha256 (ES256) SignatureScheme (RFC 8446 §4.2.3).
pub let tls_sig_ecdsa_secp256r1_sha256 : Int = 0x0403

///|
/// The server's CertificateVerify context string (RFC 8446 §4.4.3).
pub let tls13_cv_context_server : String = "TLS 1.3, server CertificateVerify"

///|
/// The client's CertificateVerify context string (RFC 8446 §4.4.3).
pub let tls13_cv_context_client : String = "TLS 1.3, client CertificateVerify"

///|
/// The content a CertificateVerify signs (RFC 8446 §4.4.3): 64 octets of 0x20, the `context`
/// string, a single 0x00 separator, then the `transcript_hash` through the Certificate.
pub fn tls13_certificate_verify_content(
  context : String,
  transcript_hash : Bytes,
) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(Bytes::make(64, b'\x20')[:])
  buf.write_bytes(@utf8.encode(context)[:])
  buf.write_byte(0)
  buf.write_bytes(transcript_hash[:])
  buf.to_bytes()
}

///|
/// Sign a CertificateVerify over the transcript with an ES256 key (RFC 8446 §4.4.3): returns
/// the message body — the SignatureScheme (ecdsa_secp256r1_sha256) and the two-byte-length-
/// prefixed raw r||s signature over the §4.4.3 signed content.
pub fn tls13_certificate_verify_sign(
  key : @ecdsa.PrivateKey,
  context : String,
  transcript_hash : Bytes,
) -> Bytes {
  let sig = ecdsa_sign(
    tls13_certificate_verify_content(context, transcript_hash),
    key,
  )
  let buf = Buffer()
  buf.write_byte(((tls_sig_ecdsa_secp256r1_sha256 >> 8) & 0xff).to_byte())
  buf.write_byte((tls_sig_ecdsa_secp256r1_sha256 & 0xff).to_byte())
  buf.write_byte(((sig.length() >> 8) & 0xff).to_byte())
  buf.write_byte((sig.length() & 0xff).to_byte())
  buf.write_bytes(sig[:])
  buf.to_bytes()
}

///|
/// Verify a CertificateVerify message `body` against the peer's ES256 public key over the
/// transcript (RFC 8446 §4.4.3): parse the SignatureScheme and signature, then check the
/// ECDSA signature over the §4.4.3 signed content. False on a wrong scheme, a malformed body,
/// or an invalid signature.
pub fn tls13_certificate_verify_check(
  key : @ecdsa.PublicKey,
  context : String,
  transcript_hash : Bytes,
  body : Bytes,
) -> Bool {
  if body.length() < 4 {
    return false
  }
  let scheme = (body[0].to_int() << 8) | body[1].to_int()
  if scheme != tls_sig_ecdsa_secp256r1_sha256 {
    return false
  }
  let sig_len = (body[2].to_int() << 8) | body[3].to_int()
  if body.length() != 4 + sig_len {
    return false
  }
  ecdsa_verify(
    tls13_certificate_verify_content(context, transcript_hash),
    body[4:4 + sig_len].to_owned(),
    key,
  )
}
