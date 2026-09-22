// The QUIC server event loop against a real UDP socket: the deterministic tests beside this
// one prove the state machine, this one proves the wiring — that a datagram arriving on a
// bound socket reaches the connection table and the answer comes back out the same socket.

///|
async test "quic serve: the event loop demultiplexes a real datagram and answers over UDP" {
  @async.with_task_group(g => {
    let ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let addr = ep.local_addr()
    let server : QuicServer[@socket.Addr] = QuicServer::new(
      QuicServeConfig::default(),
    )
    let loop_task = g.spawn(() => quic_serve_endpoint(ep, server))
    @async.sleep(100)
    let client = QuicUdpEndpoint::bind("127.0.0.1:0")
    let cid = qv_hexb("8394c8f03e515708")
    client.send_datagram(
      qs_initial(cid, b"\xaa", 0L, [
        Crypto(offset=0, data=@msg.frame(ClientHello, b"heke1228"[:])),
      ]),
      addr,
    )
    let reply = match
      @async.with_timeout_opt(2000, () => client.recv_datagram()) {
      Some((datagram, _)) => datagram
      None => abort("the event loop sent nothing back within 2 s")
    }
    // The answer is the ACK the demultiplexed connection owed for the Initial it took in.
    let frames = match quic_recv_initial(reply, client_initial_keys(cid)) {
      Some((frames, _)) => frames
      None => abort("the event loop's reply did not authenticate")
    }
    assert_eq(frames.length(), 1)
    assert_eq(
      frames[0],
      Ack(largest=0UL, delay=0UL, first_range=0UL, ranges=[]),
    )
    assert_eq(server.count(), 1)
    let conn = qs_conn(server, cid)
    assert_eq(
      conn.core().client_hello(),
      @msg.frame(ClientHello, b"heke1228"[:]),
    )
    loop_task.cancel()
    client.close()
  })
}
