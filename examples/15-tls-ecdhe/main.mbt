///|
/// The TLS 1.3 ECDHE agreement (RFC 8446 §7.1) that turns the two hello
/// key_shares into the handshake keys. Two ephemeral x25519 pairs derive the
/// same shared secret, the same server/client handshake traffic secrets, and the
/// same handshake secret through the key schedule.
///
///     moon run examples/15-tls-ecdhe --target native
#coverage.skip
fn main {
  let client_priv = hexb(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_priv = hexb(
    "6666666666666666666666666666666666666666666666666666666666666666",
  )
  let client_pub = @mooncat.tls13_x25519_public(client_priv)
  let server_pub = @mooncat.tls13_x25519_public(server_priv)
  let th = @sha2.hash(b"ch..sh transcript heke1228")
  let s_server = @mooncat.tls13_ecdhe_handshake_traffic_secret(
    server_priv, client_pub, th, false,
  )
  let s_client = @mooncat.tls13_ecdhe_handshake_traffic_secret(
    client_priv, server_pub, th, false,
  )
  println("server-side  s hs traffic = \{hex(s_server)}")
  println("client-side  s hs traffic = \{hex(s_client)}")
  println("traffic secrets agree     = \{s_server == s_client}")
  let shared_c = @mooncat.tls13_ecdhe_shared(client_priv, server_pub)
  let shared_s = @mooncat.tls13_ecdhe_shared(server_priv, client_pub)
  println("ecdhe shared agree        = \{shared_c == shared_s}")
  let early = @mooncat.tls13_early_secret(Bytes::make(32, b'\x00'))
  println(
    "handshake secret agree    = \{@mooncat.tls13_handshake_secret(early, shared_c) == @mooncat.tls13_handshake_secret(early, shared_s)}",
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
fn hexb(h : String) -> Bytes {
  let buf = Buffer()
  for i = 0; i < h.length(); i = i + 2 {
    buf.write_byte(
      ((nib(h[i].to_int()) << 4) | nib(h[i + 1].to_int())).to_byte(),
    )
  }
  buf.to_bytes()
}

///|
fn nib(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else {
    0
  }
}
