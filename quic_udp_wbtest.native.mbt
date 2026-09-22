// The QUIC UDP datagram transport over a real async socket (RFC 9000 §5): a loopback
// round-trip proving an endpoint can bind, receive a datagram with its sender's address,
// and send one back.

///|
async test "quic udp: a datagram round-trips over a real async UDP socket (loopback)" {
  @async.with_task_group(g => {
    let server = QuicUdpEndpoint::bind("127.0.0.1:0")
    let server_addr = server.local_addr()
    // Server task: receive one datagram and echo it back to its sender.
    let _ = g.spawn(() => {
      let (data, from) = server.recv_datagram()
      server.send_datagram(data, from)
    })
    @async.sleep(100)
    let client = QuicUdpEndpoint::bind("127.0.0.1:0")
    let payload = b"quic-initial-packet-probe"
    client.send_datagram(payload, server_addr)
    let (echo, _from) = client.recv_datagram()
    assert_eq(echo, payload)
    client.close()
    server.close()
  })
}

///|
async test "quic over udp: a real Initial packet with a ClientHello drives the server handshake over the wire" {
  @async.with_task_group(g => {
    let dcid = @base16.decode_lossy("8394c8f03e515708")
    let server_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let server_addr = server_ep.local_addr()
    let server_conn = @conn.Server::new(dcid)
    let processed : Ref[Array[@msg.Kind]] = { val: [], }
    // Server task: receive one datagram and drive the handshake with it.
    let _ = g.spawn(() => {
      let (datagram, _from) = server_ep.recv_datagram()
      processed.val = server_conn.receive_initial(datagram) catch { _ => [] }
    })
    @async.sleep(100)
    // Client: build a real protected Initial packet carrying a ClientHello and send it.
    let client_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let keys = client_initial_keys(dcid)
    let ch = @msg.frame(ClientHello, b"clienthello-over-real-udp"[:])
    let initial = @conn.send_long(
      Initial,
      1U,
      dcid,
      b"",
      0,
      4,
      [@frame.Crypto(offset=0, data=ch)],
      keys,
    )
    client_ep.send_datagram(initial, server_addr)
    @async.sleep(200)
    // The server decrypted the Initial with keys derived from the DCID and advanced.
    assert_eq(processed.val, [@msg.Kind::ClientHello])
    assert_eq(server_conn.handshake_state(), RecvdClientHello)
    assert_eq(server_conn.initial_ack_pending(), true)
    client_ep.close()
    server_ep.close()
  })
}

///|
async test "quic over udp: client ClientHello and server ServerHello complete an Initial flight over the wire" {
  @async.with_task_group(g => {
    let dcid = @base16.decode_lossy("8394c8f03e515708")
    let server_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let server_addr = server_ep.local_addr()
    let server_conn = @conn.Server::new(dcid)
    // Server task: receive the ClientHello, then send back a protected ServerHello Initial
    // packet to the client's address.
    let _ = g.spawn(() => {
      let (datagram, client_addr) = server_ep.recv_datagram()
      let _ = server_conn.receive_initial(datagram) catch { _ => [] }
      let sh = @msg.Server::{
        random: Bytes::make(32, b'\xab'),
        session_id: b"",
        suite: 0x1301,
        extensions: [],
      }
      let sh_packet = server_conn.send_server_hello(
        sh, b"", b"\x01\x02\x03\x04", 0,
      )
      server_ep.send_datagram(sh_packet, client_addr)
    })
    @async.sleep(100)
    let client_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let keys = client_initial_keys(dcid)
    let initial = @conn.send_long(
      Initial,
      1U,
      dcid,
      b"",
      0,
      4,
      [@frame.Crypto(offset=0, data=@msg.frame(ClientHello, b"ch"[:]))],
      keys,
    )
    client_ep.send_datagram(initial, server_addr)
    // Receive the server's ServerHello Initial packet and decode it.
    let (sh_datagram, _) = client_ep.recv_datagram()
    let decoded = match @conn.recv_long(sh_datagram, keys) {
      Some((frames, _)) => {
        let mut result : @msg.Server? = None
        for frame in frames {
          match frame {
            @frame.Crypto(data~, ..) =>
              match @msg.unframe(data[:]) {
                Some((ServerHello, body)) =>
                  result = @msg.read_server_hello(body[:])
                _ => ()
              }
            _ => ()
          }
        }
        result
      }
      None => None
    }
    match decoded {
      Some(sh) => assert_eq(sh.suite, 0x1301)
      None =>
        abort("client did not receive a decodable ServerHello over the wire")
    }
    client_ep.close()
    server_ep.close()
  })
}

///|
/// Every CRYPTO frame's bytes from a decoded packet's frames, in order.
fn wire_crypto(frames : Array[@frame.Frame]) -> Bytes {
  let mut out = b""
  for frame in frames {
    match frame {
      @frame.Crypto(data~, ..) => out = bytes_concat(out, data)
      _ => ()
    }
  }
  out
}

///|
/// Split a CRYPTO byte stream into its handshake messages as `(type, body, raw)`, where
/// `raw` is the full message including its 4-byte header — the exact bytes the transcript
/// folds.
fn split_hs(crypto : Bytes) -> Array[(@msg.Kind, Bytes, Bytes)] {
  let out : Array[(@msg.Kind, Bytes, Bytes)] = []
  let view = crypto[:]
  let mut off = 0
  for ;; {
    match @msg.unframe(view[off:]) {
      Some((t, body)) => {
        let consumed = 4 + body.length()
        out.push((t, body, view[off:off + consumed].to_owned()))
        off = off + consumed
      }
      None => break
    }
  }
  out
}

///|
async test "quic over udp: a full TLS 1.3 ECDHE handshake reaches CONNECTED over a real UDP socket" {
  @async.with_task_group(g => {
    let dcid = @base16.decode_lossy("8394c8f03e515708")
    let client_priv = @base16.decode_lossy(
      "2333333333333333333333333333333333333333333333333333333333333333",
    )
    let server_priv = @base16.decode_lossy(
      "6666666666666666666666666666666666666666666666666666666666666666",
    )
    let client_pub = tls13_x25519_public(client_priv)
    let server_pub = tls13_x25519_public(server_priv)
    let initial_keys = client_initial_keys(dcid)
    let server_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let server_addr = server_ep.local_addr()
    let server_conn = @conn.Server::new(dcid)
    let connected : Ref[Bool] = { val: false, }
    // The server: receive the ClientHello, reply with a ServerHello then its Handshake flight
    // (protected with keys it derives from the wire ClientHello), then verify the client
    // Finished — every flight crossing a real UDP socket.
    let _ = g.spawn(() => {
      let (ch_dg, client_addr) = server_ep.recv_datagram()
      let _ = server_conn.receive_initial(ch_dg) catch { _ => [] }
      let sh = @msg.Server::{
        random: Bytes::make(32, b'\x66'),
        session_id: b"lfanke",
        suite: 0x1301,
        extensions: [
          @ext.Ext::{
            kind: KeyShare,
            data: @ext.selected_share(@ext.x25519, server_pub[:]),
          },
        ],
      }
      let sh_packet = server_conn.send_server_hello(
        sh, b"", b"\x0a\x0b\x0c\x0d", 0,
      )
      server_ep.send_datagram(sh_packet, client_addr)
      // Derive both handshake secrets from the ClientHello that arrived over the wire.
      let th = server_conn.transcript_hash()
      let (server_hs_secret, client_hs_secret) = match
        tls13_ecdhe_secrets_from_client_hello(
          server_conn.client_hello(),
          server_priv,
          th,
        ) {
        Some(v) => v
        None => abort("server could not derive its handshake secrets")
      }
      let flight = server_conn.send_handshake_flight(
        server_hs_secret,
        b"ee",
        b"cert",
        _ => b"cv",
        b"",
        b"\x0a\x0b\x0c\x0d",
        0,
      ) catch {
        _ => b""
      }
      server_ep.send_datagram(flight, client_addr)
      let (fin_dg, _) = server_ep.recv_datagram()
      connected.val = server_conn.receive_handshake(
        fin_dg,
        @crypto.Keys::of(client_hs_secret),
        client_hs_secret,
      ) catch {
        _ => false
      }
    })
    @async.sleep(100)
    // The client: send its ClientHello, take the server key_share and Handshake flight off the
    // wire, derive the same secrets, authenticate the server Finished, and send its own.
    let client_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let ch = @msg.Hello::{
      random: Bytes::make(32, b'\x23'),
      session_id: b"lfanke",
      suites: [0x1301],
      extensions: [
        {
          kind: @ext.Kind::KeyShare,
          data: @ext.shares([(@ext.x25519, client_pub)]),
        },
      ],
    }
    let ch_msg = @msg.hello(ch)
    client_ep.send_datagram(
      @conn.send_long(
        Initial,
        1U,
        dcid,
        b"",
        0,
        4,
        [@frame.Crypto(offset=0, data=ch_msg)],
        initial_keys,
      ),
      server_addr,
    )
    // ServerHello over the wire: the raw SH bytes for the transcript and the server key_share.
    let (sh_dg, _) = client_ep.recv_datagram()
    let sh_msg = match @conn.recv_long(sh_dg, initial_keys) {
      Some((frames, _)) => wire_crypto(frames)
      None => abort("client could not open the ServerHello Initial")
    }
    let server_hello = match @msg.unframe(sh_msg[:]) {
      Some((ServerHello, body)) =>
        match @msg.read_server_hello(body[:]) {
          Some(v) => v
          None => abort("client could not decode the ServerHello")
        }
      _ => abort("ServerHello CRYPTO frame was not a ServerHello")
    }
    let server_pub_wire = match tls_server_hello_key_share(server_hello) {
      Some(v) => v.1
      None => abort("ServerHello carried no key_share")
    }
    let th = @sha2.hash(bytes_concat(ch_msg, sh_msg)[:])
    let server_hs_secret = tls13_ecdhe_handshake_traffic_secret(
      client_priv, server_pub_wire, th, false,
    )
    let client_hs_secret = tls13_ecdhe_handshake_traffic_secret(
      client_priv, server_pub_wire, th, true,
    )
    // The Handshake flight over the wire: decrypt with the derived server keys, split it, and
    // reconstruct the transcript through the server Finished.
    let (flight_dg, _) = client_ep.recv_datagram()
    let msgs = match
      @conn.recv_long(flight_dg, @crypto.Keys::of(server_hs_secret)) {
      Some((frames, _)) => split_hs(wire_crypto(frames))
      None => abort("client could not decrypt the server Handshake flight")
    }
    assert_eq(msgs.length(), 4)
    assert_eq(msgs[0].0, @msg.Kind::EncryptedExtensions) // EncryptedExtensions
    assert_eq(msgs[1].0, @msg.Kind::Certificate) // Certificate
    assert_eq(msgs[2].0, @msg.Kind::CertificateVerify) // CertificateVerify
    assert_eq(msgs[3].0, @msg.Kind::Finished) // Finished
    let ee = msgs[0].2
    let cert = msgs[1].2
    let cv = msgs[2].2
    let server_fin = msgs[3].2
    let through_cv = bytes_concat(
      bytes_concat(bytes_concat(bytes_concat(ch_msg, sh_msg), ee), cert),
      cv,
    )
    // The client authenticates the server Finished before answering.
    assert_eq(
      @keys.finished_ok(
        server_hs_secret[:],
        @sha2.hash(through_cv[:])[:],
        msgs[3].1[:],
      ),
      true,
    )
    let through_server_fin = bytes_concat(through_cv, server_fin)
    let client_fin = @msg.frame(
      Finished,
      @keys.finished(
        client_hs_secret[:],
        @sha2.hash(through_server_fin[:][:][:]),
      ),
    )
    client_ep.send_datagram(
      @conn.send_long(
        Handshake,
        1U,
        b"",
        b"",
        0,
        4,
        [@frame.Crypto(offset=0, data=client_fin)],
        @crypto.Keys::of(client_hs_secret),
      ),
      server_addr,
    )
    @async.sleep(200)
    assert_eq(connected.val, true)
    assert_eq(server_conn.handshake_state(), Connected)
    client_ep.close()
    server_ep.close()
  })
}
