///|
/// `n` copies of one byte, which is how RFC 5869's test vectors give their input.
fn rep_byte(b : Int, n : Int) -> Bytes {
  Bytes::make(n, b.to_byte())
}

///|
test "HKDF matches RFC 5869 Test Case 1 (SHA-256)" {
  let ikm = rep_byte(0x0b, 22)
  let salt = qv_hexb("000102030405060708090a0b0c")
  let info = qv_hexb("f0f1f2f3f4f5f6f7f8f9")
  let prk = hkdf_extract(salt, ikm)
  assert_eq(
    qv_hex(prk),
    "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
  )
  let okm = hkdf_expand(prk, info, 42)
  assert_eq(
    qv_hex(okm),
    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
  )
}

///|
test "QUIC Initial secrets and keys match RFC 9001 Appendix A.1" {
  let dcid = qv_hexb("8394c8f03e515708")
  assert_eq(
    qv_hex(quic_initial_secret(dcid)),
    "7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44",
  )
  let cli = quic_client_initial_secret(dcid)
  assert_eq(
    qv_hex(cli),
    "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea",
  )
  assert_eq(
    qv_hex(quic_server_initial_secret(dcid)),
    "3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b",
  )
  let keys = quic_packet_keys(cli)
  assert_eq(qv_hex(keys.key), "1f369613dd76d5467730efcbe3b1a22d")
  assert_eq(qv_hex(keys.iv), "fa044b2f42a3fd3b46fb255c")
  assert_eq(qv_hex(keys.hp), "9f50449e04a0e810283a1e9933adedd2")
}
