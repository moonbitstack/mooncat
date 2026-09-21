///|
/// The TLS 1.3 handshake state machines (RFC 8446 §4, Appendix A) driven over
/// the CRYPTO byte stream. The `TranscriptHash` accumulator equals the hash of
/// the concatenation; the server `TlsServerHandshake` runs ClientHello → flight
/// → Finished to Connected; and the client transition table walks its flight.
///
///     moon run examples/17-tls-handshake --target native
#coverage.skip
fn main {
  run() catch {
    e => println("handshake error: \{e}")
  }
}

///|
fn run() -> Unit raise {
  let ch = @mooncat.tls_encode_handshake(1, b"clienthello-body")
  let sh = @mooncat.tls_encode_handshake(2, b"serverhello-body")
  let t = @mooncat.TranscriptHash::new()
  t.add(ch)
  t.add(sh)
  println(
    "transcript == hash(concat) = \{t.hash() == @mooncat.tls13_transcript_hash(cat(ch, sh))}",
  )
  let hs = @mooncat.TlsServerHandshake::new()
  println("initial connected  = \{hs.is_connected()}")
  let got = hs.feed(ch)
  println("fed ClientHello    = \{ints(got)}  state=\{sstate(hs.state())}")
  let flight = @mooncat.tls_encode_handshake(2, b"serverhello-flight")
  hs.record_sent(flight)
  hs.sent_flight(false)
  println("after server flight = \{sstate(hs.state())}")
  let fin = @mooncat.tls_encode_handshake(20, b"verify-data-bytes")
  let _ = hs.feed(fin)
  println("after client Finished connected = \{hs.is_connected()}")
  println(
    "transcript = hash(CH++flight++Finished) = \{hs.transcript_hash() == @sha2.hash(cat(cat(ch, flight), fin))}",
  )
  let mut cs = @mooncat.TlsClientState::new()
  for mtype in [2, 8, 11, 15, 20] {
    cs = @mooncat.tls_client_next(cs, mtype)
  }
  println("client state after full flight = \{cstate(cs)}")
}

///|
fn cat(a : Bytes, b : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(a)
  buf.write_bytes(b)
  buf.to_bytes()
}

///|
fn ints(a : Array[Int]) -> String {
  let sb = StringBuilder()
  sb.write_char('[')
  for i = 0; i < a.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(a[i].to_string())
  }
  sb.write_char(']')
  sb.to_string()
}

///|
fn sstate(s : @mooncat.TlsServerState) -> String {
  match s {
    Start => "Start"
    RecvdClientHello => "RecvdClientHello"
    WaitCert => "WaitCert"
    WaitCertVerify => "WaitCertVerify"
    WaitFinished => "WaitFinished"
    Connected => "Connected"
  }
}

///|
fn cstate(s : @mooncat.TlsClientState) -> String {
  match s {
    WaitServerHello => "WaitServerHello"
    WaitEncryptedExtensions => "WaitEncryptedExtensions"
    WaitCertCertReq => "WaitCertCertReq"
    WaitCert => "WaitCert"
    WaitCertVerify => "WaitCertVerify"
    WaitFinished => "WaitFinished"
    Connected => "Connected"
  }
}
