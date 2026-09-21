// A real ES256 CertificateVerify over the handshake transcript (RFC 8446 §4.4.3): the server
// signs, a peer verifies, and every way of tampering is rejected.

///|
test "certificate verify: the ES256 signed content follows RFC 8446 §4.4.3" {
  let th = sha256(b"handshake-through-certificate-lfanke")
  let content = tls13_certificate_verify_content(tls13_cv_context_server, th)
  // 64 octets of 0x20, then the 33-byte context, a 0x00 separator, then the 32-byte hash.
  assert_eq(content.length(), 64 + 33 + 1 + 32)
  for i = 0; i < 64; i = i + 1 {
    assert_eq(content[i], b'\x20')
  }
  assert_eq(content[64 + 33], b'\x00')
  assert_eq(content[65 + 33:content.length()].to_owned(), th)
}

///|
test "certificate verify: a server signature over the transcript verifies and tampering is rejected" {
  // A P-256 signing key (a scalar below the group order) and its public key.
  let key = ec_private(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let pub_key = key.public()
  let th = sha256(b"ch..sh..ee..certificate-heke1228")
  let body = tls13_certificate_verify_sign(key, tls13_cv_context_server, th)
  // The body is ecdsa_secp256r1_sha256 (0x0403) + a 64-byte r||s signature.
  assert_eq((body[0].to_int() << 8) | body[1].to_int(), 0x0403)
  assert_eq((body[2].to_int() << 8) | body[3].to_int(), 64)
  // The peer verifies it over the same transcript.
  assert_eq(
    tls13_certificate_verify_check(pub_key, tls13_cv_context_server, th, body),
    true,
  )
  // A different transcript does not verify.
  assert_eq(
    tls13_certificate_verify_check(
      pub_key,
      tls13_cv_context_server,
      sha256(b"a-different-transcript"),
      body,
    ),
    false,
  )
  // The client context does not verify a server signature (context separation).
  assert_eq(
    tls13_certificate_verify_check(pub_key, tls13_cv_context_client, th, body),
    false,
  )
  // A tampered signature byte does not verify.
  let tampered = Buffer()
  for i = 0; i < body.length(); i = i + 1 {
    if i == body.length() - 1 {
      tampered.write_byte((body[i].to_int() ^ 0xff).to_byte())
    } else {
      tampered.write_byte(body[i])
    }
  }
  assert_eq(
    tls13_certificate_verify_check(
      pub_key,
      tls13_cv_context_server,
      th,
      tampered.to_bytes(),
    ),
    false,
  )
  // A wrong SignatureScheme is rejected before any curve work.
  let wrong_scheme = Buffer()
  wrong_scheme.write_byte(0x08)
  wrong_scheme.write_byte(0x04) // ed25519, not the ES256 we signed with
  for i = 2; i < body.length(); i = i + 1 {
    wrong_scheme.write_byte(body[i])
  }
  assert_eq(
    tls13_certificate_verify_check(
      pub_key,
      tls13_cv_context_server,
      th,
      wrong_scheme.to_bytes(),
    ),
    false,
  )
}
