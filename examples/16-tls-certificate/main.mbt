///|
/// The TLS 1.3 Certificate (RFC 8446 §4.4.2) and CertificateVerify (§4.4.3)
/// messages. A two-certificate chain round-trips through the Certificate wire
/// form; a real ES256 CertificateVerify signs the handshake transcript, verifies
/// under the server context, and is refused under the client context.
///
///     moon run examples/16-tls-certificate --target native
#coverage.skip
fn main {
  let leaf = b"leaf-cert-der-233"
  let ca = b"intermediate-ca-der-66666"
  let msg = @mooncat.tls13_encode_certificate(b"lfanke", [leaf, ca])
  println("certificate msg  = \{msg.length()} bytes")
  let chain_ok = match @mooncat.tls13_decode_certificate(msg[:]) {
    Some((ctx, chain)) =>
      ascii(ctx) == "lfanke" &&
      chain.length() == 2 &&
      chain[0] == leaf &&
      chain[1] == ca
    None => false
  }
  println("chain round-trip = \{chain_ok}")
  let key = @mooncat.ec_private(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let th = @sha2.hash(b"ch..sh..ee..cert transcript heke1228")
  let body = @mooncat.tls13_certificate_verify_sign(
    key, @mooncat.tls13_cv_context_server, th,
  )
  println(
    "cert_verify body = \{body.length()} bytes, prefix \{hex(body[0:4].to_owned())}",
  )
  let scheme = (body[0].to_int() << 8) | body[1].to_int()
  println("scheme ecdsa_secp256r1_sha256 = \{scheme == 0x0403}")
  let pubk = key.public()
  println(
    "verify (server ctx)  = \{@mooncat.tls13_certificate_verify_check(pubk, @mooncat.tls13_cv_context_server, th, body)}",
  )
  println(
    "verify (client ctx)  = \{@mooncat.tls13_certificate_verify_check(pubk, @mooncat.tls13_cv_context_client, th, body)}",
  )
}

///|
fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    let x = b[i].to_int()
    sb.write_char(digits[x >> 4].unsafe_to_char())
    sb.write_char(digits[x & 0xf].unsafe_to_char())
  }
  sb.to_string()
}

///|
fn ascii(b : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    sb.write_char(b[i].to_int().unsafe_to_char())
  }
  sb.to_string()
}
