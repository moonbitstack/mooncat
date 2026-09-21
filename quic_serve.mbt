// A QUIC server's connection table and event loop (RFC 9000 §5.2, §8.1, §10, §14.1). Every
// piece below this file is a pure function — the packet protection, the frame codec, the
// handshake, the recovery loop — and none of them talk to each other. This is the driver that
// makes them a server: it demultiplexes a received datagram onto a connection by its
// Destination Connection ID, drives that connection's state machine at the encryption level
// its installed keys allow, fires the idle, probe and closing timers, and hands back the
// datagrams to put on the wire — padded to the Initial minimum, and withheld once an
// unvalidated peer's amplification budget is spent. It holds no socket and no clock: the peer
// address is a type parameter and every entry point takes `now`, so the tests drive it with a
// fake sink on an injected clock and `quic_serve.native.mbt` drives it with a UDP socket.
//
// Version negotiation, stateless reset, connection migration, path validation and coalesced
// packets (more than one QUIC packet in a datagram) are not implemented here.

///|
/// Where a connection is in its lifecycle (RFC 9000 §10.2): exchanging packets, closing —
/// this endpoint sent a CONNECTION_CLOSE and answers anything further with it — or draining,
/// where the peer closed and nothing more goes out.
pub(all) enum QuicConnPhase {
  Active
  Closing
  Draining
} derive(Eq, Debug)

///|
/// The smallest a datagram carrying an ack-eliciting Initial packet may be (RFC 9000 §14.1).
pub let quic_min_initial_datagram : Int = 1200

///|
/// The anti-amplification factor (RFC 9000 §8.1): until it has validated a peer's address, a
/// server may send it at most this many times the bytes it has received from it.
pub let quic_amplification_factor : Int64 = 3L

///|
/// What a server gives each new connection: the QUIC version its long headers carry, the idle
/// timeout it advertises, how long a closing or draining connection lingers, and the datagram
/// size, timer tuning and flow-control credit the send loop starts from. Every duration is in
/// microseconds, the unit the recovery code measures in.
pub(all) struct QuicServeConfig {
  version : UInt
  idle_timeout : Int64
  close_period : Int64
  max_datagram : Int64
  max_ack_delay : Int64
  granularity : Int64
  initial_max_data : UInt64
  initial_max_stream_data : UInt64
  max_frame : UInt64
}

///|
/// QUIC version 1, a 30-second idle timeout, a 3-second closing period, 1200-byte datagrams,
/// a 25-millisecond ACK delay, and a mebibyte of flow-control credit on the connection and on
/// each stream.
pub fn QuicServeConfig::default() -> QuicServeConfig {
  {
    version: 1U,
    idle_timeout: 30_000_000L,
    close_period: 3_000_000L,
    max_datagram: 1200L,
    max_ack_delay: 25_000L,
    granularity: 1_000L,
    initial_max_data: 1_048_576UL,
    initial_max_stream_data: 1_048_576UL,
    max_frame: 1024UL,
  }
}

///|
/// The idle timeout in force on a connection (RFC 9000 §10.1): the smaller of the two
/// endpoints' advertised `max_idle_timeout`s, where zero on either side means that end asks
/// for no limit at all.
pub fn quic_effective_idle_timeout(ours : Int64, theirs : Int64) -> Int64 {
  if ours <= 0L {
    theirs
  } else if theirs <= 0L {
    ours
  } else if ours < theirs {
    ours
  } else {
    theirs
  }
}

///|
/// Build a datagram from `payload`, padding the payload with PADDING frames until the built
/// datagram reaches `min` bytes (RFC 9000 §14.1). The header's Length field is a varint, so
/// growing the payload can grow the header too; re-measure rather than guess the overhead.
fn quic_pad_datagram(
  payload : Bytes,
  build : (Bytes) -> Bytes,
  min : Int,
) -> Bytes {
  let mut body = payload
  let mut datagram = build(body)
  while datagram.length() < min {
    body = quic_pad_payload(body, body.length() + min - datagram.length())
    datagram = build(body)
  }
  datagram
}

///|
/// One server-side connection: the peer it answers, the connection ids the two ends address
/// each other by, the handshake and send state machines it drives, and the counters the
/// amplification limit, the idle timer and the closing period are read from. `A` is the
/// peer-address type the enclosing `QuicServer` was built with.
pub struct QuicServeConn[A] {
  peer : A
  cid : Bytes
  peer_cid : Bytes
  core : QuicServerConn
  sender : QuicSender
  cfg : QuicServeConfig
  out : Array[Bytes]
  received : Array[(QuicLevel, QuicFrame)]
  mut rx : Int64
  mut tx : Int64
  mut packets : Int
  mut validated : Bool
  mut last_rx : Int64
  mut idle_timeout : Int64
  mut phase : QuicConnPhase
  mut close_at : Int64
  mut close_frame : QuicFrame?
  mut close_level : QuicLevel
  mut hs_rx : QuicPacketKeys?
  mut hs_rx_secret : Bytes
  mut hs_tx : QuicPacketKeys?
  mut app_rx : QuicPacketKeys?
  mut app_tx : QuicPacketKeys?
}

///|
/// A connection for the peer at `peer` that addressed this server as `cid` and called itself
/// `peer_cid`. The server keeps the client's original Destination Connection ID as its own —
/// that is the id the Initial keys derive from (RFC 9001 §5.2), so reusing it keeps the
/// demultiplexing key and the key schedule talking about the same bytes.
fn[A] QuicServeConn::new(
  peer : A,
  cid : Bytes,
  peer_cid : Bytes,
  cfg : QuicServeConfig,
  now : Int64,
) -> QuicServeConn[A] {
  {
    peer,
    cid,
    peer_cid,
    core: QuicServerConn::new(cid),
    sender: QuicSender::new(
      cfg.initial_max_data,
      cfg.initial_max_stream_data,
      cfg.max_datagram,
      cfg.max_ack_delay,
      cfg.granularity,
      cfg.max_frame,
    ),
    cfg,
    out: [],
    received: [],
    rx: 0L,
    tx: 0L,
    packets: 0,
    validated: false,
    last_rx: now,
    idle_timeout: cfg.idle_timeout,
    phase: Active,
    close_at: 0L,
    close_frame: None,
    close_level: QuicLevel::Initial,
    hs_rx: None,
    hs_rx_secret: b"",
    hs_tx: None,
    app_rx: None,
    app_tx: None,
  }
}

///|
/// The peer this connection answers.
pub fn[A] QuicServeConn::peer(self : QuicServeConn[A]) -> A {
  self.peer
}

///|
/// The connection id the peer addresses this server by — the table's key.
pub fn[A] QuicServeConn::cid(self : QuicServeConn[A]) -> Bytes {
  self.cid
}

///|
/// Where this connection is in its lifecycle.
pub fn[A] QuicServeConn::phase(self : QuicServeConn[A]) -> QuicConnPhase {
  self.phase
}

///|
/// The handshake state machine underneath, for a caller driving the TLS flights.
pub fn[A] QuicServeConn::core(self : QuicServeConn[A]) -> QuicServerConn {
  self.core
}

///|
/// Bytes received from the peer, the numerator of the amplification limit.
pub fn[A] QuicServeConn::rx_bytes(self : QuicServeConn[A]) -> Int64 {
  self.rx
}

///|
/// Bytes sent to the peer, the quantity the amplification limit caps.
pub fn[A] QuicServeConn::tx_bytes(self : QuicServeConn[A]) -> Int64 {
  self.tx
}

///|
/// Datagrams received on this connection.
pub fn[A] QuicServeConn::packets_received(self : QuicServeConn[A]) -> Int {
  self.packets
}

///|
/// Whether the peer's address has been validated (RFC 9000 §8.1), which lifts the
/// amplification limit.
pub fn[A] QuicServeConn::validated(self : QuicServeConn[A]) -> Bool {
  self.validated
}

///|
/// The idle timeout in force, in microseconds; zero means none.
pub fn[A] QuicServeConn::idle_timeout(self : QuicServeConn[A]) -> Int64 {
  self.idle_timeout
}

///|
/// Datagrams built and waiting to go out — non-zero while the amplification limit or a closed
/// congestion window is holding them back.
pub fn[A] QuicServeConn::pending(self : QuicServeConn[A]) -> Int {
  self.out.length()
}

///|
/// The largest packet number the peer has acknowledged at `level`, or `None` before its first
/// ACK there.
pub fn[A] QuicServeConn::largest_acked(
  self : QuicServeConn[A],
  level : QuicLevel,
) -> Int64? {
  self.core.conn.space(level).largest_acked()
}

///|
/// Whether `n` more bytes may go to this peer: unrestricted once its address is validated,
/// otherwise at most three times what it has sent this server (RFC 9000 §8.1).
pub fn[A] QuicServeConn::can_send(self : QuicServeConn[A], n : Int) -> Bool {
  self.validated ||
  self.tx + n.to_int64() <= quic_amplification_factor * self.rx
}

///|
/// Install the Handshake-space keys, derived from the client's and this server's handshake
/// traffic secrets (RFC 9001 §5.1). Until they are installed, a Handshake packet cannot be
/// unprotected and is dropped; after, the connection reads and writes at that level. The
/// client's secret is kept so an arriving Finished can be verified against it.
pub fn[A] QuicServeConn::install_handshake_keys(
  self : QuicServeConn[A],
  client_secret : Bytes,
  server_secret : Bytes,
) -> Unit {
  self.hs_rx = Some(quic_packet_keys(client_secret))
  self.hs_rx_secret = client_secret
  self.hs_tx = Some(quic_packet_keys(server_secret))
}

///|
/// Install the Application-space (1-RTT) keys, derived from the two application traffic
/// secrets. Until they are installed, a short-header packet is dropped and the send loop has
/// nowhere to put stream data.
pub fn[A] QuicServeConn::install_app_keys(
  self : QuicServeConn[A],
  client_secret : Bytes,
  server_secret : Bytes,
) -> Unit {
  self.app_rx = Some(quic_packet_keys(client_secret))
  self.app_tx = Some(quic_packet_keys(server_secret))
}

///|
/// Apply the peer's transport parameters (RFC 9000 §18). `max_idle_timeout` (§18.2) is the one
/// that changes this connection: it settles the idle timer at the smaller of the two ends'
/// advertised values, converting the parameter's milliseconds to the timers' microseconds.
pub fn[A] QuicServeConn::apply_peer_params(
  self : QuicServeConn[A],
  params : Array[TransportParam],
) -> Unit {
  for p in params {
    if p.id == tp_max_idle_timeout {
      match transport_param_as_int(p) {
        Some(ms) =>
          self.idle_timeout = quic_effective_idle_timeout(
            self.cfg.idle_timeout,
            ms.reinterpret_as_int64() * 1000L,
          )
        None => ()
      }
    }
  }
}

///|
/// The highest encryption level this connection can send at — Application once its 1-RTT keys
/// are in, else Handshake, else Initial, which is always available.
pub fn[A] QuicServeConn::send_level(self : QuicServeConn[A]) -> QuicLevel {
  if self.app_tx is Some(_) {
    QuicLevel::Application
  } else if self.hs_tx is Some(_) {
    QuicLevel::Handshake
  } else {
    QuicLevel::Initial
  }
}

///|
/// Queue `frames` to go out at `level` on the next `poll_out`, numbered from that level's
/// packet-number space. An Initial packet carrying anything ack-eliciting takes its datagram
/// to the 1200-byte floor (RFC 9000 §14.1); a level whose keys are not installed drops the
/// frames, since there is nothing to protect them with.
pub fn[A] QuicServeConn::send(
  self : QuicServeConn[A],
  level : QuicLevel,
  frames : Array[QuicFrame],
) -> Unit {
  let pn = self.core.conn.next_packet_number(level)
  if level == QuicLevel::Application {
    // The recovery loop numbers this space too; keep the two counters from colliding.
    self.sender.advance_past(pn)
  }
  self.emit(level, frames, pn)
}

///|
fn[A] QuicServeConn::emit(
  self : QuicServeConn[A],
  level : QuicLevel,
  frames : Array[QuicFrame],
  pn : Int64,
) -> Unit {
  let keys = match level {
    Initial => Some(self.core.initial_keys)
    Handshake => self.hs_tx
    Application => self.app_tx
  }
  guard keys is Some(k) else { return }
  let payload = quic_encode_payload(frames)
  let datagram = match level {
    Initial => {
      let build = p => {
        quic_protect_initial(
          self.cfg.version,
          self.peer_cid,
          self.cid,
          b"",
          pn,
          4,
          p,
          k.key,
          k.iv,
          k.hp,
        )
      }
      if quic_payload_is_ack_eliciting(frames) {
        quic_pad_datagram(payload, build, quic_min_initial_datagram)
      } else {
        build(payload)
      }
    }
    Handshake =>
      quic_send_handshake(
        self.cfg.version,
        self.peer_cid,
        self.cid,
        pn,
        4,
        frames,
        k,
      )
    Application =>
      quic_send_short(false, false, self.peer_cid, pn, 4, frames, k)
  }
  self.out.push(datagram)
}

///|
/// Queue `bytes` to send on stream `id`; the send loop frames and paces them out through
/// `poll_out` once the Application keys are installed.
pub fn[A] QuicServeConn::queue_stream(
  self : QuicServeConn[A],
  id : UInt64,
  bytes : Bytes,
) -> Unit {
  self.sender.queue_stream(id, bytes)
}

///|
/// Take the frames received since the last call, each with the level it arrived at — where an
/// application layer reads its streams out of.
pub fn[A] QuicServeConn::take_received(
  self : QuicServeConn[A],
) -> Array[(QuicLevel, QuicFrame)] {
  let out = self.received.copy()
  self.received.clear()
  out
}

///|
/// Close the connection (RFC 9000 §10.2): put a CONNECTION_CLOSE carrying `error_code` and
/// `reason` on the wire at the highest level with keys, drop whatever else was queued, and
/// enter the closing period — during which every packet the peer sends is answered with the
/// same CONNECTION_CLOSE, and at the end of which `tick` forgets the connection. Closing a
/// connection that is already closing or draining does nothing.
pub fn[A] QuicServeConn::close(
  self : QuicServeConn[A],
  error_code : UInt64,
  reason : Bytes,
  now : Int64,
) -> Unit {
  guard self.phase == Active else { return }
  // frame_type 0 names no triggering frame, which is what a close not provoked by one says.
  let frame = ConnectionClose(error_code~, frame_type=Some(0UL), reason~)
  self.phase = Closing
  self.close_frame = Some(frame)
  self.close_level = self.send_level()
  self.close_at = now + self.cfg.close_period
  self.out.clear()
  self.send(self.close_level, [frame])
}

///|
/// The next datagram to put on the wire, or `None` when nothing is queued, the amplification
/// budget is spent, or the connection is draining. Pulls a fresh packet out of the send loop
/// when the queue has run dry.
fn[A] QuicServeConn::next_datagram(
  self : QuicServeConn[A],
  now : Int64,
) -> Bytes? raise {
  guard self.phase != Draining else { return None }
  if self.out.length() == 0 {
    self.fill(now)
  }
  guard self.out.length() > 0 else { return None }
  let datagram = self.out[0]
  guard self.can_send(datagram.length()) else { return None }
  let _ = self.out.remove(0)
  self.tx = self.tx + datagram.length().to_int64()
  Some(datagram)
}

///|
/// Pull the next packet the send loop has ready — a retransmission or freshly scheduled stream
/// data — into the outbound queue (RFC 9002 §7).
fn[A] QuicServeConn::fill(self : QuicServeConn[A], now : Int64) -> Unit raise {
  guard self.phase == Active else { return }
  guard self.app_tx is Some(_) else { return }
  match self.sender.poll_send(now) {
    Some((pn, frames)) => {
      // The recovery loop assigned the number; keep the space's own counter past it.
      self.core.conn.space(QuicLevel::Application).advance_past(pn)
      self.emit(QuicLevel::Application, frames, pn)
    }
    None => ()
  }
}

///|
/// Take a datagram from this connection's peer at `now`: count it against the amplification
/// budget and the idle timer, unprotect it at whichever level its header names, and drive the
/// state machine with the frames inside.
fn[A] QuicServeConn::on_datagram(
  self : QuicServeConn[A],
  datagram : Bytes,
  now : Int64,
) -> Unit raise {
  self.rx = self.rx + datagram.length().to_int64()
  self.last_rx = now
  self.packets = self.packets + 1
  guard self.phase != Draining else { return }
  match parse_long_header(datagram[:]) {
    Some((h, _)) =>
      match h.packet_type {
        QuicLongPacketType::Initial => self.on_initial(datagram, now)
        QuicLongPacketType::Handshake => self.on_handshake(datagram, now)
        // 0-RTT and Retry are not served.
        _ => ()
      }
    None => self.on_app(datagram, now)
  }
}

///|
fn[A] QuicServeConn::on_initial(
  self : QuicServeConn[A],
  datagram : Bytes,
  now : Int64,
) -> Unit raise {
  let opened = quic_recv_initial(datagram, self.core.initial_keys) catch {
    _ => None
  }
  // A datagram that does not authenticate is discarded, not an error: an endpoint cannot
  // tell a corrupted packet from an injected one (RFC 9000 §12.2).
  guard opened is Some((frames, pn)) else { return }
  let _ = self.core.on_frames(QuicLevel::Initial, frames, pn)
  self.adopt_peer_params()
  self.on_frames(QuicLevel::Initial, frames, now)
}

///|
fn[A] QuicServeConn::on_handshake(
  self : QuicServeConn[A],
  datagram : Bytes,
  now : Int64,
) -> Unit raise {
  guard self.hs_rx is Some(keys) else { return }
  let opened = quic_recv_handshake(datagram, keys) catch { _ => None }
  guard opened is Some((frames, pn)) else { return }
  // A Handshake packet the peer could only have sent from the address it claims proves that
  // address, which lifts the amplification limit (RFC 9000 §8.1).
  self.validated = true
  let _ = self.core.on_handshake_frames(frames, pn, self.hs_rx_secret)
  self.on_frames(QuicLevel::Handshake, frames, now)
}

///|
fn[A] QuicServeConn::on_app(
  self : QuicServeConn[A],
  datagram : Bytes,
  now : Int64,
) -> Unit raise {
  guard self.app_rx is Some(keys) else { return }
  let opened = quic_recv_short(datagram, self.cid.length(), keys) catch {
    _ => None
  }
  guard opened is Some((frames, pn)) else { return }
  self.core.conn.on_packet_received(
    QuicLevel::Application,
    pn,
    quic_payload_is_ack_eliciting(frames),
  )
  self.on_frames(QuicLevel::Application, frames, now)
}

///|
/// Act on the frames of a packet that arrived at `level`: feed acknowledgements to the
/// recovery loop, take a CONNECTION_CLOSE into the draining period, raise the send limit from
/// a MAX_DATA, and record the rest for the application layer. Then answer — an ACK if one is
/// owed (RFC 9000 §13.2.1), or this endpoint's CONNECTION_CLOSE again if it is closing
/// (§10.2.1).
fn[A] QuicServeConn::on_frames(
  self : QuicServeConn[A],
  level : QuicLevel,
  frames : Array[QuicFrame],
  now : Int64,
) -> Unit raise {
  for frame in frames {
    self.received.push((level, frame))
    match frame {
      Ack(largest~, ..) | AckEcn(largest~, ..) => {
        self.core.conn.on_ack_received(level, largest.reinterpret_as_int64())
        if level == QuicLevel::Application {
          self.sender.on_ack(frame, now)
        }
      }
      ConnectionClose(..) => {
        self.phase = Draining
        self.close_at = now + self.cfg.close_period
        self.out.clear()
        return
      }
      MaxData(v) => self.sender.on_max_data(v)
      _ => ()
    }
  }
  if self.phase == Closing {
    match self.close_frame {
      Some(frame) => self.send(self.close_level, [frame])
      None => ()
    }
    return
  }
  if self.core.conn.space(level).ack_pending() {
    match self.core.conn.build_ack(level, 0UL) {
      Some(ack) => self.send(level, [ack])
      None => ()
    }
  }
}

///|
/// Read the peer's transport parameters off the ClientHello the handshake has taken in, once
/// there is one to read (RFC 9001 §8.2). A hello that does not decode leaves the defaults
/// standing.
fn[A] QuicServeConn::adopt_peer_params(self : QuicServeConn[A]) -> Unit {
  let hello = self.core.client_hello()
  guard hello.length() > 0 else { return }
  guard tls_parse_handshake(hello[:]) is Some((_, body)) else { return }
  guard decode_client_hello(body[:]) is Some(ch) else { return }
  self.apply_peer_params(tls_hello_quic_transport_params(ch.extensions))
}

///|
/// A QUIC server: the connections it is holding, keyed by the connection id peers address
/// each by, and the settings a new one starts from. `A` is the peer-address type — a socket
/// address under the native event loop, whatever a test finds convenient under a fake sink.
pub struct QuicServer[A] {
  conns : Map[Bytes, QuicServeConn[A]]
  cfg : QuicServeConfig
}

///|
/// A server holding no connections, handing `cfg` to each one it opens.
pub fn[A] QuicServer::new(cfg : QuicServeConfig) -> QuicServer[A] {
  { conns: Map([]), cfg, }
}

///|
/// How many connections the server is holding.
pub fn[A] QuicServer::count(self : QuicServer[A]) -> Int {
  self.conns.length()
}

///|
/// The connection ids the server is holding.
pub fn[A] QuicServer::conn_ids(self : QuicServer[A]) -> Array[Bytes] {
  self.conns.keys().collect()
}

///|
/// The connection `cid` addresses, or `None` if the server is not holding one.
pub fn[A] QuicServer::conn(
  self : QuicServer[A],
  cid : Bytes,
) -> QuicServeConn[A]? {
  self.conns.get(cid)
}

///|
/// Take a datagram received at `now` from `from`: route it to the connection its Destination
/// Connection ID names, opening one when an Initial packet arrives for an id the server does
/// not hold, and drive that connection with it (RFC 9000 §5.2). A datagram naming no
/// connection is dropped — RFC 9000 §10.3's stateless reset is not implemented.
pub fn[A] QuicServer::recv(
  self : QuicServer[A],
  datagram : Bytes,
  from : A,
  now : Int64,
) -> Unit raise {
  guard datagram.length() > 0 else { return }
  match parse_long_header(datagram[:]) {
    Some((h, _)) => {
      let conn = match self.conns.get(h.dcid) {
        Some(c) => c
        None => {
          guard h.packet_type is QuicLongPacketType::Initial else { return }
          let c = QuicServeConn::new(from, h.dcid, h.scid, self.cfg, now)
          self.conns[h.dcid] = c
          c
        }
      }
      conn.on_datagram(datagram, now)
    }
    None => {
      guard self.lookup_short(datagram) is Some(conn) else { return }
      conn.on_datagram(datagram, now)
    }
  }
}

///|
/// The connection a short-header datagram belongs to. A short header carries no connection-id
/// length (RFC 9000 §17.3), so the only way back to the connection is to test the datagram
/// against the ids this server has issued.
fn[A] QuicServer::lookup_short(
  self : QuicServer[A],
  datagram : Bytes,
) -> QuicServeConn[A]? {
  for cid in self.conns.keys().collect() {
    let n = cid.length()
    if datagram.length() >= 1 + n && datagram[1:1 + n].to_owned() == cid {
      return self.conns.get(cid)
    }
  }
  None
}

///|
/// The next datagram to put on the wire and the peer to send it to, or `None` when no
/// connection has one ready.
pub fn[A] QuicServer::poll_out(
  self : QuicServer[A],
  now : Int64,
) -> (Bytes, A)? raise {
  for cid in self.conns.keys().collect() {
    guard self.conns.get(cid) is Some(conn) else { continue }
    match conn.next_datagram(now) {
      Some(datagram) => return Some((datagram, conn.peer))
      None => ()
    }
  }
  None
}

///|
/// Close the connection `cid` addresses with `error_code` and `reason`, if the server holds
/// one (RFC 9000 §10.2).
pub fn[A] QuicServer::close(
  self : QuicServer[A],
  cid : Bytes,
  error_code : UInt64,
  reason : Bytes,
  now : Int64,
) -> Unit {
  match self.conns.get(cid) {
    Some(conn) => conn.close(error_code, reason, now)
    None => ()
  }
}

///|
/// Run the timers at `now`. An idle connection is forgotten without a CONNECTION_CLOSE, which
/// is what RFC 9000 §10.1 asks for; a closing or draining one is forgotten when its period
/// ends (§10.2); an active one whose probe timeout has come re-queues its oldest outstanding
/// packet, to go out on the next `poll_out` (RFC 9002 §6.2.4).
pub fn[A] QuicServer::tick(self : QuicServer[A], now : Int64) -> Unit {
  let expired : Array[Bytes] = []
  for cid in self.conns.keys().collect() {
    guard self.conns.get(cid) is Some(conn) else { continue }
    match conn.phase {
      Active =>
        if conn.idle_timeout > 0L && now - conn.last_rx >= conn.idle_timeout {
          expired.push(cid)
        } else {
          let _ = conn.sender.on_pto_timeout(now)
        }
      Closing | Draining => if now >= conn.close_at { expired.push(cid) }
    }
  }
  for cid in expired {
    self.conns.remove(cid)
  }
}

///|
pub extend QuicConnPhase with Debug::{to_repr}

///|
pub extend QuicConnPhase with Eq::{not_equal, equal}
