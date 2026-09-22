// The QUIC server event loop, driven deterministically (RFC 9000 §5.2, §8.1, §10, §14.1):
// an injected clock and a `QuicServer[String]` whose "socket" is whatever `poll_out` hands
// back, so every timer and every byte on the wire is exact rather than raced.

///|
/// A client Initial datagram addressed to `dcid` from `scid`, carrying `frames` at packet
/// number `pn` under the Initial keys the DCID derives (RFC 9001 §5.2). Padded to the 1200
/// bytes a client's first flight has to reach unless `pad` says otherwise.
fn qs_initial(
  dcid : Bytes,
  scid : Bytes,
  pn : Int64,
  frames : Array[QuicFrame],
  pad? : Bool = true,
) -> Bytes {
  let keys = client_initial_keys(dcid)
  let payload = quic_encode_payload(frames)
  let build = p => {
    quic_protect_initial(
      1U,
      dcid,
      scid,
      b"",
      pn,
      4,
      p,
      keys.key,
      keys.iv,
      keys.hp,
    )
  }
  if pad {
    quic_pad_datagram(payload, build, quic_min_initial_datagram)
  } else {
    build(payload)
  }
}

///|
fn[A] qs_conn(server : QuicServer[A], cid : Bytes) -> QuicServeConn[A] {
  match server.conn(cid) {
    Some(c) => c
    None => abort("the server is holding no connection for that id")
  }
}

///|
fn[A] qs_next(server : QuicServer[A], now? : Int64 = 0L) -> Bytes raise {
  match server.poll_out(now) {
    Some((datagram, _)) => datagram
    None => abort("the server had no datagram ready")
  }
}

///|
/// Everything the server will send at `now`, as `(datagrams, bytes)`.
fn[A] qs_drain(server : QuicServer[A], now? : Int64 = 0L) -> (Int, Int) raise {
  let mut count = 0
  let mut bytes = 0
  for ;; {
    match server.poll_out(now) {
      Some((datagram, _)) => {
        count = count + 1
        bytes = bytes + datagram.length()
      }
      None => break
    }
  }
  (count, bytes)
}

///|
/// The packet number a protected 1-RTT packet carries.
fn qs_short_pn(
  packet : Bytes,
  dcid_len : Int,
  keys : QuicPacketKeys,
) -> Int64 raise {
  match quic_recv_short(packet, dcid_len, keys) {
    Some((_, pn)) => pn
    None => abort("the 1-RTT packet did not authenticate")
  }
}

///|
fn qs_open(packet : Bytes, cid : Bytes) -> Array[QuicFrame] raise {
  match quic_recv_initial(packet, client_initial_keys(cid)) {
    Some((frames, _)) => frames
    None => abort("the server's Initial packet did not authenticate")
  }
}

///|
test "quic serve: two datagrams for different connection ids reach different connections (RFC 9000 §5.2)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid_a = qv_hexb("8394c8f03e515708")
  let cid_b = qv_hexb("1122334455667788")
  let hello_a = @msg.frame(ClientHello, b"emm"[:])
  let hello_b = @msg.frame(ClientHello, b"hhh"[:])
  server.recv(
    qs_initial(cid_a, b"\xaa", 0L, [Crypto(offset=0, data=hello_a)]),
    "client-a",
    0L,
  )
  server.recv(
    qs_initial(cid_b, b"\xbb", 0L, [Crypto(offset=0, data=hello_b)]),
    "client-b",
    0L,
  )
  server.recv(qs_initial(cid_a, b"\xaa", 1L, [Ping]), "client-a", 0L)
  assert_eq(server.count(), 2)
  let a = qs_conn(server, cid_a)
  let b = qs_conn(server, cid_b)
  assert_eq(a.peer(), "client-a")
  assert_eq(b.peer(), "client-b")
  assert_eq(a.packets_received(), 2)
  assert_eq(b.packets_received(), 1)
  // Each connection reassembled its own CRYPTO stream, not the other's.
  assert_eq(a.core().client_hello(), hello_a)
  assert_eq(b.core().client_hello(), hello_b)
}

///|
test "quic serve: an ack-eliciting Initial datagram is padded to 1200 bytes (RFC 9000 §14.1)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  server.recv(
    qs_initial(cid, b"\xaa", 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    0L,
  )
  let conn = qs_conn(server, cid)
  // The ACK the server owes is not ack-eliciting, so §14.1 does not ask it to be padded.
  let ack = qs_next(server)
  assert_eq(ack.length() < quic_min_initial_datagram, true)
  let server_hello = @msg.frame(ServerHello, b"serverhello"[:])
  conn.send(QuicLevel::Initial, [Crypto(offset=0, data=server_hello)])
  let flight = qs_next(server)
  assert_eq(flight.length() >= quic_min_initial_datagram, true)
  // Padded to the floor, not past it — the length varint growing is the only slack.
  assert_eq(flight.length() <= quic_min_initial_datagram + 4, true)
  // The padding rides inside the protected payload, so the packet still opens.
  assert_eq(qs_open(flight, cid)[0], Crypto(offset=0, data=server_hello))
}

///|
test "quic serve: a server sends at most 3x what it received before the address is validated (RFC 9000 §8.1)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  let first = qs_initial(cid, b"\xaa", 0L, [
    Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
  ])
  server.recv(first, "peer", 0L)
  let conn = qs_conn(server, cid)
  let budget = 3 * first.length()
  // Far more than the budget: each of these is padded to 1200 bytes.
  for _i = 0; _i < 8; _i = _i + 1 {
    conn.send(QuicLevel::Initial, [
      Crypto(
        offset=0,
        data=@msg.frame(ServerHello, b"serverhello-many-bytes"[:]),
      ),
    ])
  }
  let (count, sent) = qs_drain(server)
  assert_eq(count > 0, true)
  assert_eq(sent <= budget, true)
  assert_eq(conn.validated(), false)
  // It stopped because of the limit, not because the queue ran dry.
  assert_eq(conn.pending() > 0, true)
  // A Handshake packet proves the address, and the rest goes out.
  let secret = Bytes::make(32, b'\x23')
  conn.install_handshake_keys(secret, secret)
  server.recv(
    quic_send_handshake(
      1U,
      cid,
      b"\xaa",
      0L,
      4,
      [Ping],
      quic_packet_keys(secret),
    ),
    "peer",
    0L,
  )
  assert_eq(conn.validated(), true)
  let (more_count, more) = qs_drain(server)
  assert_eq(more_count > 0, true)
  assert_eq(sent + more > budget, true)
}

///|
test "quic serve: an idle connection times out on the injected clock (RFC 9000 §10.1)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  server.recv(
    qs_initial(cid, b"\xaa", 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    1_000L,
  )
  let conn = qs_conn(server, cid)
  // The server advertises 30 s; the peer asks for 100 ms, and the smaller one wins.
  conn.apply_peer_params([transport_param_int(tp_max_idle_timeout, 100UL)])
  assert_eq(conn.idle_timeout(), 100_000L)
  server.tick(1_000L + 99_999L)
  assert_eq(server.count(), 1)
  server.tick(1_000L + 100_000L)
  assert_eq(server.count(), 0)
}

///|
test "quic serve: closing a connection puts CONNECTION_CLOSE on the wire (RFC 9000 §10.2)" {
  let cfg = QuicServeConfig::default()
  let server : QuicServer[String] = QuicServer::new(cfg)
  let cid = qv_hexb("8394c8f03e515708")
  server.recv(
    qs_initial(cid, b"\xaa", 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    0L,
  )
  let _ = qs_drain(server)
  server.close(cid, 0x0cUL, b"qwq", 0L)
  let conn = qs_conn(server, cid)
  assert_eq(conn.phase(), Closing)
  let closed = qs_next(server)
  assert_eq(
    qs_open(closed, cid).contains(
      ConnectionClose(error_code=0x0cUL, frame_type=Some(0UL), reason=b"qwq"),
    ),
    true,
  )
  // §10.2.1: a packet arriving in the closing state is answered with the same frame.
  server.recv(qs_initial(cid, b"\xaa", 1L, [Ping]), "peer", 0L)
  assert_eq(
    qs_open(qs_next(server), cid).contains(
      ConnectionClose(error_code=0x0cUL, frame_type=Some(0UL), reason=b"qwq"),
    ),
    true,
  )
  // §10.2: the closing period ends, and the connection is gone.
  server.tick(cfg.close_period)
  assert_eq(server.count(), 0)
}

///|
test "quic serve: an ECN-enabled peer's ACK_ECN advances the acknowledged number (RFC 9000 §19.3.2)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  server.recv(
    qs_initial(cid, b"\xaa", 0L, [
      AckEcn(
        largest=7UL,
        delay=0UL,
        first_range=0UL,
        ranges=[],
        ect0=66UL,
        ect1=6UL,
        ce=1UL,
      ),
      Ping,
    ]),
    "peer",
    0L,
  )
  let conn = qs_conn(server, cid)
  assert_eq(conn.largest_acked(QuicLevel::Initial), Some(7L))
}

///|
test "quic serve: queued stream data leaves as a protected 1-RTT packet (RFC 9002 §7)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  let scid = b"\xaa\xbb"
  server.recv(
    qs_initial(cid, scid, 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    0L,
  )
  let conn = qs_conn(server, cid)
  let app_secret = Bytes::make(32, b'\x66')
  conn.install_app_keys(app_secret, app_secret)
  conn.queue_stream(0UL, b"heke1228")
  let _ = qs_next(server) // the Initial ACK first
  let packet = qs_next(server)
  let frames = match
    quic_recv_short(packet, scid.length(), quic_packet_keys(app_secret)) {
    Some((frames, _)) => frames
    None => abort("the 1-RTT packet did not authenticate")
  }
  assert_eq(frames, [Stream(id=0UL, offset=0UL, fin=false, data=b"heke1228")])
}

///|
test "quic serve: the probe timeout re-queues an unacknowledged packet (RFC 9002 §6.2.4)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  let scid = b"\xaa\xbb"
  server.recv(
    qs_initial(cid, scid, 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    0L,
  )
  let conn = qs_conn(server, cid)
  let app_secret = Bytes::make(32, b'\x66')
  conn.install_app_keys(app_secret, app_secret)
  conn.queue_stream(0UL, b"lfanke")
  let _ = qs_drain(server)
  assert_eq(server.poll_out(0L) is None, true)
  // Well past the initial probe timeout, well inside the 30-second idle timeout.
  let later = 1_000_000L
  server.tick(later)
  let probe = qs_next(server, now=later)
  let frames = match
    quic_recv_short(probe, scid.length(), quic_packet_keys(app_secret)) {
    Some((frames, _)) => frames
    None => abort("the probe packet did not authenticate")
  }
  assert_eq(frames, [Stream(id=0UL, offset=0UL, fin=false, data=b"lfanke")])
}

///|
test "quic serve: a short-header datagram is demultiplexed by the id it carries (RFC 9000 §17.3)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  server.recv(
    qs_initial(cid, b"\xaa\xbb", 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    0L,
  )
  let conn = qs_conn(server, cid)
  let app_secret = Bytes::make(32, b'\x66')
  conn.install_app_keys(app_secret, app_secret)
  let _ = conn.take_received()
  // A short header carries no connection-id length, so the only route back to the connection
  // is matching the bytes after the first against the ids the server issued.
  let data : QuicFrame = Stream(id=4UL, offset=0UL, fin=true, data=b"qwq")
  server.recv(
    quic_send_short(
      false,
      false,
      cid,
      0L,
      4,
      [data],
      quic_packet_keys(app_secret),
    ),
    "peer",
    0L,
  )
  assert_eq(conn.packets_received(), 2)
  assert_eq(conn.take_received(), [(QuicLevel::Application, data)])
}

///|
test "quic serve: the send loop and the connection number one Application space between them (RFC 9000 §12.3)" {
  let server : QuicServer[String] = QuicServer::new(QuicServeConfig::default())
  let cid = qv_hexb("8394c8f03e515708")
  let scid = b"\xaa\xbb"
  server.recv(
    qs_initial(cid, scid, 0L, [
      Crypto(offset=0, data=@msg.frame(ClientHello, b"emm"[:])),
    ]),
    "peer",
    0L,
  )
  let conn = qs_conn(server, cid)
  let app_secret = Bytes::make(32, b'\x66')
  let app_keys = quic_packet_keys(app_secret)
  conn.install_app_keys(app_secret, app_secret)
  let _ = qs_next(server) // the Initial ACK
  // Reusing a packet number in one space would repeat an AEAD nonce, so the connection's own
  // packets and the send loop's have to advance the same counter.
  conn.send(QuicLevel::Application, [Ping])
  let first = qs_next(server)
  conn.queue_stream(0UL, b"heke1228")
  let second = qs_next(server)
  conn.send(QuicLevel::Application, [Ping])
  let third = qs_next(server)
  assert_eq(qs_short_pn(first, scid.length(), app_keys), 0L)
  assert_eq(qs_short_pn(second, scid.length(), app_keys), 1L)
  assert_eq(qs_short_pn(third, scid.length(), app_keys), 2L)
}
