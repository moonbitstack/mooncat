// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Random bytes for connection ids and handshakes. A fixed sequence, since nothing here is secret:
/// this is a test peer, and the point of it is the wire.
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
/// Echo every stream back in upper case.
fn serve_streams(server : @conn.Endpoint[@socket.Addr]) -> Unit {
  for session in server.take_busy() {
    for event in session.take_events() {
      guard event is Readable(id) else { continue }
      let data = session.read(id)
      if data.length() > 0 {
        let upper = Bytes::makei(data.length(), i => {
          let b = data[i]
          if b >= b'a' && b <= b'z' {
            (b.to_int() - 32).to_byte()
          } else {
            b
          }
        })
        session.write(id, upper, fin=session.finished(id))
      }
    }
  }
}

///|
async fn run(cert : String, key : String, addr : String) -> Unit {
  let ep = @quic.Endpoint::bind(addr)
  let server : @conn.Endpoint[@socket.Addr] = @conn.Endpoint::server(
    @conn.Config::default(),
    @tls.Server::new(
      @x509.pems(@fs.read_file(cert).text()),
      @x509.PrivateKey::pem(@fs.read_file(key).text()),
      alpn=["echo"],
      tickets=@tls.Tickets::new([Bytes::make(32, b'\x07')][:], early=1024),
    ),
    rand=counting(1234),
  )
  let pump = () => {
    for ;; {
      guard server.poll_out(@quic.now()) is Some((datagram, to)) else { break }
      ep.send_datagram(datagram, to)
    }
  }
  println("listening on \{addr}")
  @async.with_task_group(g => {
    let _ : @async.Task[Unit] = g.spawn(() => {
      for ;; {
        let (datagram, from) = ep.recv_datagram()
        server.recv(datagram, from, @quic.now(), wall=@quic.wall()) catch {
          _ => ()
        }
        serve_streams(server)
        pump()
      }
    })
    for ;; {
      @async.sleep(20)
      server.tick(@quic.now())
      serve_streams(server)
      pump()
    }
  })
}

///|
/// `12-quic-echo <cert> <key> [address]`
async fn main {
  let args = @env.args()
  guard args.length() >= 3 else {
    println("usage: 12-quic-echo <cert> <key> [address]")
    return
  }
  run(args[1], args[2], args.get(3).unwrap_or("127.0.0.1:12000"))
}
