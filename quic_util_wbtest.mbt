// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

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
