// The transcript-hash accumulator (RFC 8446 §4.4.1) and Finished verify_data (§4.4.4).

///|
/// Concatenate two byte strings (test helper).
fn cat2(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
test "transcript: incremental hash equals the hash of the concatenation" {
  let ch = tls_encode_handshake(1, b"clienthello-body") // ClientHello
  let sh = tls_encode_handshake(2, b"serverhello-body") // ServerHello
  let t = TranscriptHash::new()
  t.add(ch)
  t.add(sh)
  let combined = cat2(ch, sh)
  assert_eq(t.hash(), @sha2.hash(combined[:]))
  assert_eq(t.hash(), tls13_transcript_hash(combined))
}

///|
test "transcript: an empty transcript is the hash of the empty string" {
  let t = TranscriptHash::new()
  assert_eq(t.hash(), sha256(b""))
}

///|
test "transcript: message order changes the hash" {
  let a = tls_encode_handshake(1, b"A")
  let b = tls_encode_handshake(2, b"B")
  let ab = TranscriptHash::new()
  ab.add(a)
  ab.add(b)
  let ba = TranscriptHash::new()
  ba.add(b)
  ba.add(a)
  assert_eq(ab.hash() == ba.hash(), false)
}

///|
test "finished: verify_data is the finished-key HMAC and round-trips through verify" {
  // Use the RFC 8448 §3 server handshake traffic secret as the base key.
  let base_key = qv_hexb(
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
  )
  let t = TranscriptHash::new()
  t.add(tls_encode_handshake(1, b"clienthello"))
  t.add(tls_encode_handshake(2, b"serverhello"))
  let th = t.hash()
  let vd = tls13_finished_verify_data(base_key, th)
  assert_eq(vd.length(), 32)
  // verify_data is exactly HMAC(finished_key, transcript_hash).
  assert_eq(vd, hmac256(tls13_finished_key(base_key), th))
  // A genuine verify_data is accepted; a tampered one is rejected.
  assert_eq(tls13_finished_verify(base_key, th, vd), true)
  let tampered = cat2(vd[0:31].to_owned(), b"\x00")
  assert_eq(tls13_finished_verify(base_key, th, tampered), false)
}
