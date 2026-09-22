// The QUIC server event loop over a real UDP socket (RFC 9000 §5). `@conn.Endpoint` is the whole
// state machine but holds neither socket nor clock; this file gives it both. One task pulls
// datagrams off the endpoint and demultiplexes them onto connections, another fires the timers
// on a fixed tick, and both flush whatever the connection table has to send afterwards — which
// is where `@conn.Sender::poll_send` finally meets a socket. Native-only, because the socket is.

///|
/// The event loop's clock, in the microseconds the recovery and idle timers are measured in.
/// `@async.now()` counts milliseconds since the epoch.
pub fn quic_now() -> Int64 {
  @async.now() * 1000L
}

///|
/// Push every datagram the server has ready onto `ep`, until its queues are empty or the
/// anti-amplification limit stops it.
async fn quic_pump(
  ep : QuicUdpEndpoint,
  server : @conn.Endpoint[@socket.Addr],
) -> Unit {
  for ;; {
    match server.poll_out(quic_now()) {
      Some((datagram, to)) => ep.send_datagram(datagram, to)
      None => break
    }
  }
}

///|
/// Serve QUIC on `ep` until the enclosing task group is cancelled: one task reads datagrams
/// and demultiplexes them onto connections, the other runs the idle, probe and closing-period
/// timers every `tick_ms` milliseconds, and both push out whatever that left ready to send.
/// A datagram that names no connection or fails to authenticate is dropped rather than
/// killing the loop — an endpoint cannot tell a stray packet from an attack.
pub async fn quic_serve_endpoint(
  ep : QuicUdpEndpoint,
  server : @conn.Endpoint[@socket.Addr],
  tick_ms? : Int = 20,
) -> Unit {
  @async.with_task_group(g => {
    let _ : @async.Task[Unit] = g.spawn(() => {
      for ;; {
        let (datagram, from) = ep.recv_datagram()
        server.recv(datagram, from, quic_now()) catch {
          _ => ()
        }
        quic_pump(ep, server) catch {
          _ => ()
        }
      }
    })
    for ;; {
      @async.sleep(tick_ms)
      server.tick(quic_now())
      quic_pump(ep, server) catch {
        _ => ()
      }
    }
  })
}

///|
/// Bind a UDP socket at `addr` (e.g. `"0.0.0.0:443"`) and serve `server` on it. The socket
/// outlives the loop deliberately: closing one a task is parked in `recvfrom` on wedges it
/// rather than waking it, so shutdown is cancellation of the task group, not a close.
pub async fn quic_serve(
  addr : String,
  server : @conn.Endpoint[@socket.Addr],
  tick_ms? : Int = 20,
) -> Unit {
  quic_serve_endpoint(QuicUdpEndpoint::bind(addr), server, tick_ms~)
}
