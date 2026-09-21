// The TLS 1.3 server handshake runner over the CRYPTO byte stream (RFC 8446 §4).

///|
/// Concatenate three byte strings (test helper).
fn cat3(a : Bytes, b : Bytes, c : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.write_bytes(c)
  buf.to_bytes()
}

///|
test "handshake driver: a full server handshake advances to Connected" {
  let ch = tls_encode_handshake(1, b"clienthello-body")
  let server_flight = tls_encode_handshake(2, b"serverhello-body")
  let client_finished = tls_encode_handshake(20, b"verify-data-bytes")
  let hs = TlsServerHandshake::new()
  assert_eq(hs.feed(ch), [1])
  assert_eq(hs.state(), RecvdClientHello)
  // The server sends its flight and advances (no client certificate requested).
  hs.record_sent(server_flight)
  hs.sent_flight(false)
  assert_eq(hs.state(), WaitFinished)
  assert_eq(hs.feed(client_finished), [20])
  assert_eq(hs.is_connected(), true)
  // The transcript is the hash of CH, then the server flight, then the client Finished,
  // in order.
  assert_eq(
    hs.transcript_hash(),
    @sha2.hash(cat3(ch, server_flight, client_finished)[:]),
  )
}

///|
test "handshake driver: a partial message is buffered until complete" {
  let ch = tls_encode_handshake(1, b"a-long-clienthello-body")
  let hs = TlsServerHandshake::new()
  // Feed only the first 10 bytes: not a whole message yet.
  assert_eq(hs.feed(ch[0:10].to_owned()), [])
  assert_eq(hs.state(), Start)
  // Feed the rest: the message completes and is processed.
  assert_eq(hs.feed(ch[10:ch.length()].to_owned()), [1])
  assert_eq(hs.state(), RecvdClientHello)
}

///|
test "handshake driver: two messages in one feed are processed in order" {
  // After the ClientHello and the server's flight, the client sends Certificate,
  // CertificateVerify, and Finished; here two arrive together.
  let hs = TlsServerHandshake::new()
  let _ = hs.feed(tls_encode_handshake(1, b"ch"))
  hs.sent_flight(true) // request a client certificate -> WAIT_CERT
  let cert = tls_encode_handshake(11, b"client-cert")
  let cert_verify = tls_encode_handshake(15, b"client-cv")
  assert_eq(hs.feed(bytes_concat(cert, cert_verify)), [11, 15])
  assert_eq(hs.state(), WaitFinished)
}
