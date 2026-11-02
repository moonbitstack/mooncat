///|
fn long_header(dcid : Bytes) -> Bytes {
  let out = Buffer()
  out.write_byte(b'\xc3')
  out.write_bytes(b"\x00\x00\x00\x01")
  out.write_byte(dcid.length().to_byte())
  out.write_bytes(dcid)
  out.write_byte(b'\x08')
  out.write_bytes(b"clientid")
  out.write_bytes(Bytes::make(1180, 0))
  out.to_bytes()
}

///|
fn short_header(dcid : Bytes) -> Bytes {
  b"\x41" + dcid + Bytes::make(40, 7)
}

///|
test "route: a datagram goes to the worker its connection id names" {
  let issued = issued_by(2, n => Bytes::make(n, 0xab))()
  assert_eq(issued.length(), @conn.cid_size)
  assert_eq(issued[0], b'\x02')
  assert_eq(worker_of(short_header(issued)[:], 3), 2)
  assert_eq(worker_of(long_header(issued)[:], 3), 2)
}

///|
test "route: a client's own id sends every copy of its Initial to the same worker" {
  let made_up = b"\x0b\x17\x29\x3a\x4c\x5d\x6e\x7f"
  let first = worker_of(long_header(made_up)[:], 4)
  assert_eq(first, 0x0b % 4)
  for _ in 0..<3 {
    assert_eq(worker_of(long_header(made_up)[:], 4), first)
  }
}

///|
test "route: one worker, an empty id, or a datagram too short to name one, goes to worker 0" {
  assert_eq(
    worker_of(short_header(b"\x05\x00\x00\x00\x00\x00\x00\x00")[:], 1),
    0,
  )
  assert_eq(worker_of(long_header(b"")[:], 4), 0)
  assert_eq(worker_of(b"\xc3\x00\x00"[:], 4), 0)
  assert_eq(worker_of(b""[:], 4), 0)
}

///|
test "route: a relay frame carries the address and the datagram after their lengths" {
  let frame = relay_frame("192.0.2.7:4433", b"\x01\x02\x03"[:])
  assert_eq(frame[0], b'\x0e')
  assert_eq(@utf8.decode_lossy(frame[1:15]), "192.0.2.7:4433")
  assert_eq(frame[15:17].to_owned(), b"\x00\x03")
  assert_eq(frame[17:].to_owned(), b"\x01\x02\x03")
  let big = relay_frame("[2001:db8::1]:443", Bytes::make(1350, 1)[:])
  assert_eq(big.length(), 1 + 17 + 2 + 1350)
  assert_eq(big[18:20].to_owned(), b"\x05\x46")
}

///|
test "route: a link opens only with the token and a worker number in range" {
  let token = "c0ffee"
  assert_eq(read_hello("c0ffee 1", token, 2), Some(1))
  assert_eq(
    read_hello(relay_hello(token, 0).trim_end(chars="\n"), token, 2),
    Some(0),
  )
  assert_eq(read_hello("c0ffee 2", token, 2), None)
  assert_eq(read_hello("c0ffee -1", token, 2), None)
  assert_eq(read_hello("decaf 1", token, 2), None)
  assert_eq(read_hello("c0ffee one", token, 2), None)
  assert_eq(read_hello("c0ffee", token, 2), None)
}
