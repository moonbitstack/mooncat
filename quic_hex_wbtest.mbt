// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A hex string as bytes, and back — the shape the QUIC and TLS RFCs print their
/// vectors in, and what the tests here read them with.
fn qv_hexb(h : String) -> Bytes {
  let buf = Buffer()
  for i = 0; i < h.length(); i = i + 2 {
    buf.write_byte(
      ((qv_nibble(h[i].to_int()) << 4) | qv_nibble(h[i + 1].to_int())).to_byte(),
    )
  }
  buf.to_bytes()
}

///|
fn qv_nibble(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else {
    0
  }
}

///|
fn qv_hex(b : Bytes) -> String {
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
/// Two byte strings joined.
///
/// The handshake transcripts and the CRYPTO streams here are built by appending one
/// message to the last, and a `Buffer` per join reads worse than a name for it.
fn bytes_concat(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}
