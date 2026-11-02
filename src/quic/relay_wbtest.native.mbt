///|
/// A wait that fails the test instead of hanging it when the datagram never comes.
async fn[T] soon(f : async () -> T) -> T {
  @async.with_timeout(2000, f)
}

///|
/// A relay on a free loopback port, with `workers` places.
async fn test_relay(workers : Int32) -> Relay {
  Relay::open(@config.Config::new(host="127.0.0.1", port=0, workers~))
}

///|
async test "relay: datagrams reach the worker their id names, and answers leave through the port" {
  @async.with_task_group(g => {
    let relay = test_relay(2)
    g.spawn_bg(no_wait=true, () => relay.run())
    let link = relay.listener.addr.to_string()
    let zero = Endpoint::relay(link, relay.token, 0, relay.udp.addr)
    let one = Endpoint::relay(link, relay.token, 1, relay.udp.addr)
    // The links register once the relay has read their hellos.
    for _ in 0..<50 {
      if relay.links[0] is Some(_) && relay.links[1] is Some(_) {
        break
      }
      @async.sleep(10)
    }
    let client = @socket.UdpClient::UdpClient(relay.udp.addr)
    client.send(short_header(issued_by(1, n => Bytes::make(n, 0x55))()))
    let (datagram, from) = soon(() => one.recv_datagram())
    assert_eq(datagram[0], b'\x41')
    assert_eq(datagram[1], b'\x01')
    assert_eq(from.to_string(), client.addr.to_string())
    one.send_datagram(b"from one", from)
    let buf = FixedArray::make(64, b'\x00')
    let n = soon(() => client.recv(buf))
    assert_eq(Bytes::makei(n, i => buf[i]), b"from one")
    client.send(short_header(issued_by(0, n => Bytes::make(n, 0x66))()))
    let (datagram, _) = soon(() => zero.recv_datagram())
    assert_eq(datagram[1], b'\x00')
    client.close()
    zero.close()
    one.close()
  })
}

///|
async test "relay: a link without the token is closed and takes no place" {
  @async.with_task_group(g => {
    let relay = test_relay(2)
    g.spawn_bg(no_wait=true, () => relay.run())
    let stranger = @socket.Tcp::connect(relay.listener.addr)
    stranger.write("not-the-token 0\n")
    let closed = @async.with_timeout_opt(2000, () => stranger.read_some())
    assert_true(closed is Some(None))
    assert_true(relay.links[0] is None)
    stranger.close()
  })
}

///|
async test "relay: a worker that comes back takes its place again" {
  @async.with_task_group(g => {
    let relay = test_relay(1)
    g.spawn_bg(no_wait=true, () => relay.run())
    let link = relay.listener.addr.to_string()
    let first = Endpoint::relay(link, relay.token, 0, relay.udp.addr)
    for _ in 0..<50 {
      if relay.links[0] is Some(_) {
        break
      }
      @async.sleep(10)
    }
    first.close()
    let second = Endpoint::relay(link, relay.token, 0, relay.udp.addr)
    for _ in 0..<50 {
      if relay.joined[0] == 2 && relay.links[0] is Some((_, 2)) {
        break
      }
      @async.sleep(10)
    }
    assert_true(relay.links[0] is Some((_, 2)))
    let client = @socket.UdpClient::UdpClient(relay.udp.addr)
    client.send(short_header(issued_by(0, n => Bytes::make(n, 0x77))()))
    let (datagram, _) = soon(() => second.recv_datagram())
    assert_eq(datagram[2], b'\x77')
    client.close()
    second.close()
  })
}
