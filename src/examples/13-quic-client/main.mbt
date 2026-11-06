// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn counting(seed : Int32) -> (Int32) -> Bytes {
  let state = Ref(seed)
  n => {
    Bytes::makei(n, i => {
      state.val = state.val * 31 + i + 7
      (state.val & 0xff).to_byte()
    })
  }
}

///|
/// A client that keeps its tickets in `store`. The certificate is not judged: this is a test peer.
fn client_of(
  store : @tls.Sessions,
  seed : Int32,
  early : Bool,
) -> @conn.Client raise {
  let scid = Bytes::makei(8, i => (seed + i).to_byte())
  let params = @conn.Limits::new(
    idle_timeout=30000UL,
    data=10_000_000UL,
    stream_data_bidi_local=2_000_000UL,
    stream_data_bidi_remote=1_000_000UL,
    stream_data_uni=1_000_000UL,
    streams_bidi=100UL,
    streams_uni=100UL,
  ).params()
  params.push({ kind: InitialScid, value: scid, })
  @conn.Client::new(
    @tls.Client::new(
      @x509.Roots::new(),
      alpn=["echo"],
      verify=Custom((_, _) => ()),
      sessions=store,
      early~,
    ),
    "localhost",
    @conn.encode(params[:]),
    counting(seed),
    Bytes::makei(8, i => (seed * 3 + i).to_byte()),
    scid,
    @quic.wall(),
  )
}

///|
/// Send and receive until `done`, or give up after four seconds.
async fn drive(
  udp : @socket.UdpServer,
  to : @socket.Addr,
  client : @conn.Client,
  done : () -> Bool,
) -> Bool {
  let buf = FixedArray::make(2048, b'\x00')
  for _ in 0..<200 {
    for datagram in client.poll_out(@quic.now()) {
      udp.sendto(datagram, to)
    }
    if done() {
      return true
    }
    let got = @async.with_timeout_opt(20, () => udp.recvfrom(buf)) catch {
      // Windows reports a port nobody is listening on as an error on the socket.
      @os_error.OSError(10054, ..) => None
      e => raise e
    }
    if got is Some((n, _)) {
      client.recv(Bytes::makei(n, i => buf[i]), @quic.now())
    }
  }
  false
}

///|
/// What arrived on stream `id` once there is any.
async fn reply(
  udp : @socket.UdpServer,
  to : @socket.Addr,
  client : @conn.Client,
  id : UInt64,
) -> String {
  let held = Ref(b"")
  let _ = drive(udp, to, client, () => {
    held.val = client.read(id)
    held.val.length() > 0
  })
  @utf8.decode_lossy(held.val[:])
}

///|
/// `13-quic-client [address]`: a handshake, a stream, a key update, then a resumption that writes
/// before the handshake finishes. Each step prints one line.
async fn main {
  let addr = @env.args().get(1).unwrap_or("127.0.0.1:12000")
  let to = @socket.Addr::parse(addr)
  let udp = @socket.UdpServer::UdpServer(@socket.Addr::parse("127.0.0.1:0"))
  let store = @tls.Sessions::new()
  let client = client_of(store, 11, false)
  println("connected \{drive(udp, to, client, () => client.is_connected())}")
  client.write(0UL, b"first", fin=true)
  println("stream \{reply(udp, to, client, 0UL)}")
  println("ticket \{drive(udp, to, client, () => store.length() > 0)}")
  // Until the server confirms the handshake and acknowledges this phase, no update may start.
  let updated = Ref(false)
  let _ = drive(udp, to, client, () => {
    updated.val = client.update_keys()
    updated.val
  })
  println("updated \{updated.val}")
  client.write(4UL, b"second", fin=true)
  println("stream after update \{reply(udp, to, client, 4UL)}")
  let again = client_of(store, 23, true)
  again.write(0UL, b"early", fin=true)
  println("early reply \{reply(udp, to, again, 0UL)}")
  println("early accepted \{again.early_accepted()}")
}
