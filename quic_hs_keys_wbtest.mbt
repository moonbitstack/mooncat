// The named TLS 1.3 traffic secrets and the QUIC Handshake/Application key wiring,
// checked against the RFC 8448 §3 published key-schedule values.

///|
test "RFC 8448 §3: named traffic secrets match the published values" {
  let handshake = qv_hexb(
    "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac",
  )
  let hs_th = qv_hexb(
    "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8",
  )
  assert_eq(
    qv_hex(@keys.client_handshake(handshake[:], hs_th[:])),
    "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21",
  )
  assert_eq(
    qv_hex(@keys.server_handshake(handshake[:], hs_th[:])),
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
  )
  let master = qv_hexb(
    "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919",
  )
  let ap_th = qv_hexb(
    "9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13",
  )
  assert_eq(
    qv_hex(@keys.client_application(master[:], ap_th[:])),
    "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5",
  )
  assert_eq(
    qv_hex(@keys.server_application(master[:], ap_th[:])),
    "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643",
  )
}

///|
test "QUIC Handshake keys are the packet keys of the handshake traffic secret" {
  let handshake = qv_hexb(
    "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac",
  )
  let hs_th = qv_hexb(
    "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8",
  )
  let client = quic_handshake_keys(handshake, hs_th, true)
  let expected = quic_packet_keys(
    qv_hexb("b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"),
  )
  assert_eq(client.key, expected.key)
  assert_eq(client.iv, expected.iv)
  assert_eq(client.hp, expected.hp)
  assert_eq(client.key.length(), 16)
  assert_eq(client.iv.length(), 12)
  assert_eq(client.hp.length(), 16)
  // The server direction derives distinct keys.
  let server = quic_handshake_keys(handshake, hs_th, false)
  assert_eq(client.key == server.key, false)
}

///|
test "QUIC Application keys derive from the master secret's traffic secret" {
  let master = qv_hexb(
    "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919",
  )
  let ap_th = qv_hexb(
    "9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13",
  )
  let client = quic_application_keys(master, ap_th, true)
  let expected = quic_packet_keys(
    qv_hexb("9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5"),
  )
  assert_eq(client.key, expected.key)
  assert_eq(client.iv, expected.iv)
  assert_eq(client.hp, expected.hp)
}
