///|
/// The TLS 1.3 key schedule (RFC 8446 §7.1) — the HKDF ladder from the Early
/// Secret through the Handshake and Master Secrets, reproducing the RFC 8448 §3
/// vectors. The Finished verify_data (§4.4.4) is then computed and checked.
///
///     moon run examples/13-tls-keyschedule --target native
#coverage.skip
fn main {
  let early = @mooncat.tls13_early_secret(Bytes::make(32, b'\x00'))
  println("early secret       = \{hex(early)}")
  println(
    "derived-for-hs     = \{hex(@mooncat.tls13_derive_secret(early, b"derived", @sha2.hash(b"")))}",
  )
  let ecdhe = hexb(
    "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d",
  )
  let hs = @mooncat.tls13_handshake_secret(early, ecdhe)
  println("handshake secret   = \{hex(hs)}")
  println("master secret      = \{hex(@mooncat.tls13_master_secret(hs))}")
  let base = hexb(
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
  )
  let th = @sha2.hash(b"transcript-heke1228")
  let vd = @mooncat.tls13_finished_verify_data(base, th)
  println("finished verify_data = \{hex(vd)}")
  println(
    "finished verifies    = \{@mooncat.tls13_finished_verify(base, th, vd)}",
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
