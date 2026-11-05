// Binding the QUIC datagram transport to moonbitlang/async (RFC 9000 §5): a QUIC endpoint receives
// and sends whole datagrams, each carrying one or more QUIC packets. An endpoint is either a UDP
// socket of its own or, in a worker, a link to the supervisor that holds the socket; the
// connection loop sees the same two operations either way.

///|
/// A QUIC endpoint: where datagrams come from and go to.
pub struct Endpoint {
  priv link : Link
  priv serving : @socket.Addr
  // One writer at a time: the receive loop and the timer loop both flush, and a descriptor takes
  // one write at a time.
  priv writing : @async.Mutex
}

///|
priv enum Link {
  Socket(@socket.UdpServer)
  Relay(@socket.Tcp)
}

///|
/// Bind an endpoint to `addr` (e.g. `"0.0.0.0:443"`, or `"127.0.0.1:0"` for an OS-assigned
/// port). The bound address is available from `local_addr`.
pub async fn Endpoint::bind(addr : String) -> Endpoint {
  let server = @socket.UdpServer::UdpServer(@socket.Addr::parse(addr))
  { link: Socket(server), serving: server.addr, writing: @async.Mutex(), }
}

///|
/// A worker's endpoint: datagrams for `serving` arrive over the supervisor's link at `relay`, which
/// this opens with `token` and the worker's number.
pub async fn Endpoint::relay(
  relay : String,
  token : String,
  index : Int32,
  serving : @socket.Addr,
) -> Endpoint {
  let conn = @socket.Tcp::connect(@socket.Addr::parse(relay))
  conn.write(relay_hello(token, index))
  { link: Relay(conn), serving, writing: @async.Mutex(), }
}

///|
/// The address the endpoint serves (the concrete port when bound to port 0).
pub fn Endpoint::local_addr(self : Endpoint) -> @socket.Addr {
  self.serving
}

///|
/// Receive the next datagram and its sender's address, copying up to `max` bytes.
pub async fn Endpoint::recv_datagram(
  self : Endpoint,
  max~ : Int32 = 2048,
) -> (Bytes, @socket.Addr) {
  match self.link {
    Socket(server) => {
      let buf = FixedArray::make(max, b'\x00')
      for ;; {
        // Windows reports the ICMP "port unreachable" an earlier send drew as an error on this
        // socket, WSAECONNRESET. That peer is gone; every other one is still here.
        let (n, from) = server.recvfrom(buf) catch {
          @os_error.OSError(10054, ..) => continue
          e => raise e
        }
        break (Bytes::makei(n, i => buf[i]), from)
      }
    }
    Relay(conn) => {
      let (peer, datagram) = read_relayed(conn)
      (datagram, @socket.Addr::parse(peer))
    }
  }
}

///|
/// Send `data` as a single datagram to `to`.
pub async fn Endpoint::send_datagram(
  self : Endpoint,
  data : Bytes,
  to : @socket.Addr,
) -> Unit {
  self.writing.acquire()
  defer self.writing.release()
  match self.link {
    Socket(server) => server.sendto(data, to)
    Relay(conn) => conn.write(relay_frame(to.to_string(), data[:]))
  }
}

///|
/// Close the endpoint's socket or link.
pub fn Endpoint::close(self : Endpoint) -> Unit {
  match self.link {
    Socket(server) => server.close()
    Relay(conn) => conn.close()
  }
}

///|
/// The next frame on a relay link: the peer's address and the datagram.
async fn read_relayed(conn : @socket.Tcp) -> (String, Bytes) {
  let size = conn.read_exactly(1)[0].to_int()
  let peer = @utf8.decode_lossy(conn.read_exactly(size)[:])
  let length = conn.read_exactly(2)
  let n = (length[0].to_int() << 8) | length[1].to_int()
  (peer, conn.read_exactly(n))
}
