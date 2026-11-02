// Several workers behind one UDP port. The supervisor holds the socket and hands each datagram to
// the worker its Destination Connection ID names; a worker puts its own number in the first byte
// of every id it issues, which is how the id names it. The worker and the supervisor talk over a
// loopback TCP connection in frames: the peer's address, then the datagram.

///|
/// The worker a datagram goes to, out of `workers`: the first byte of its Destination Connection
/// ID. After the handshake every id a client uses is one its worker issued, so it goes home. The
/// id a client makes up for its first Initial is random, and the same rule sends every
/// retransmission of it to the same worker, so the handshake does not split.
fn worker_of(datagram : BytesView, workers : Int32) -> Int32 {
  guard workers > 1 && datagram.length() > 0 else { return 0 }
  // RFC 9000 §17.2: a long header has the version in bytes 1 to 4 and the id's length in 5; a
  // short header (§17.3) has the id straight after the first byte, at the length this server
  // issues.
  let at = if (datagram[0].to_int() & 0x80) != 0 {
    guard datagram.length() > 6 && datagram[5] != b'\x00' else { return 0 }
    6
  } else {
    1
  }
  guard datagram.length() > at else { return 0 }
  datagram[at].to_int() % workers
}

///|
/// The connection ids worker `index` issues: its number, then randomness.
fn issued_by(index : Int32, rand : (Int32) -> Bytes) -> () -> Bytes {
  () => Bytes::make(1, index.to_byte()) + rand(@conn.cid_size - 1)
}

///|
/// One datagram on the supervisor's link to a worker: the peer's address and the datagram, each
/// after its length.
fn relay_frame(peer : String, datagram : BytesView) -> Bytes {
  let addr = @utf8.encode(peer)
  let out = Buffer()
  out.write_byte(addr.length().to_byte())
  out.write_bytes(addr)
  out.write_byte((datagram.length() >> 8).to_byte())
  out.write_byte(datagram.length().to_byte())
  out.write_bytesview(datagram)
  out.to_bytes()
}

///|
/// The secret a worker opens its link with, so that nothing else on the machine can.
fn relay_hello(token : String, index : Int32) -> String {
  "\{token} \{index}\n"
}

///|
/// The worker number in a hello line, if the token in it is `token`.
fn read_hello(line : StringView, token : String, workers : Int32) -> Int32? {
  guard line.split(" ").collect() is [given, number] && given == token else {
    return None
  }
  let index = @string.parse_int(number) catch { _ => return None }
  if index >= 0 && index < workers {
    Some(index)
  } else {
    None
  }
}
