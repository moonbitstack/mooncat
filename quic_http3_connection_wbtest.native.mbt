// One HTTP/3 connection end to end over a single UDP socket (RFC 9001, RFC 9114): the client and
// server complete the TLS 1.3 / QUIC handshake to Connected, each derives its 1-RTT application
// keys from that handshake (master secret + the ClientHello..server-Finished transcript), and
// then the client sends an HTTP/3 request the server routes through @http3.serve — the handshake
// and the request/response on the same connection, the shape a real HTTP/3 exchange takes.

///|
async test "quic http3 connection: handshake then serve a request on one connection over the wire" {
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
    let client_cid = @base16.decode_lossy("66778899eeff0011")
    let connected : Ref[Bool] = { val: false, }
    let handler = fn(r : @http3.Request) -> @http3.Response {
      if r.path == "/hello" {
        @http3.Response::{
          status: "200",
          headers: [],
          body: b"one connection",
        }
      } else {
        @http3.Response::{ status: "404", headers: [], body: b"", }
      }
    }
    // Server: run the handshake to Connected, derive the 1-RTT keys, then serve one request.
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
      server_ep.send_datagram(
        server_conn.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0),
        client_addr,
      )
      let th_ch_sh = server_conn.transcript_hash()
      let server_hs_secret = tls13_ecdhe_handshake_traffic_secret(
        server_priv, client_pub, th_ch_sh, false,
      )
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
      let th_app = server_conn.transcript_hash()
      let client_hs_secret = tls13_ecdhe_handshake_traffic_secret(
        server_priv, client_pub, th_ch_sh, true,
      )
      let (fin_dg, _) = server_ep.recv_datagram()
      connected.val = server_conn.receive_handshake(
        fin_dg,
        @crypto.Keys::of(client_hs_secret),
        client_hs_secret,
      ) catch {
        _ => false
      }
      // 1-RTT keys from the handshake: master secret over the CH..server-Finished transcript.
      let master = @keys.master(
        tls13_handshake_secret_from_ecdhe(server_priv, client_pub),
      )
      let client_app_keys = @crypto.application(master, th_app, client=true)
      let server_app_keys = @crypto.application(master, th_app, client=false)
      let (req_dg, from2) = server_ep.recv_datagram()
      let frames = match
        (@conn.recv_short(req_dg, dcid.length(), client_app_keys) catch {
          _ => None
        }) {
        Some((fr, _)) => fr
        None => []
      }
      let mut req = b""
      for frame in frames {
        match frame {
          @frame.Stream(id~, data~, ..) => if id == 0UL { req = data }
          _ => ()
        }
      }
      let resp = @http3.serve(req, handler) catch { _ => b"" }
      server_ep.send_datagram(
        @conn.send_short(
          client_cid,
          0,
          4,
          [@frame.Stream(id=0UL, offset=0UL, fin=true, data=resp)],
          server_app_keys,
        ),
        from2,
      )
    })
    @async.sleep(100)
    // Client: drive the handshake, derive the 1-RTT keys, then send the request and read the reply.
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
    let (sh_dg, _) = client_ep.recv_datagram()
    let sh_msg = match @conn.recv_long(sh_dg, initial_keys) {
      Some((frames, _)) => wire_crypto(frames)
      None => abort("client could not open the ServerHello")
    }
    let server_hello = match @msg.unframe(sh_msg[:]) {
      Some((ServerHello, body)) =>
        match @msg.read_server_hello(body[:]) {
          Some(v) => v
          None => abort("client could not decode the ServerHello")
        }
      _ => abort("ServerHello frame was not a ServerHello")
    }
    let server_pub_wire = match tls_server_hello_key_share(server_hello) {
      Some(v) => v.1
      None => abort("ServerHello carried no key_share")
    }
    let th_ch_sh = @sha2.hash(bytes_concat(ch_msg, sh_msg)[:])
    let server_hs_secret = tls13_ecdhe_handshake_traffic_secret(
      client_priv, server_pub_wire, th_ch_sh, false,
    )
    let (flight_dg, _) = client_ep.recv_datagram()
    let msgs = match
      @conn.recv_long(flight_dg, @crypto.Keys::of(server_hs_secret)) {
      Some((frames, _)) => split_hs(wire_crypto(frames))
      None => abort("client could not decrypt the flight")
    }
    let through_cv = bytes_concat(
      bytes_concat(
        bytes_concat(bytes_concat(ch_msg, sh_msg), msgs[0].2),
        msgs[1].2,
      ),
      msgs[2].2,
    )
    let through_server_fin = bytes_concat(through_cv, msgs[3].2)
    let th_app = @sha2.hash(through_server_fin[:])
    let client_hs_secret = tls13_ecdhe_handshake_traffic_secret(
      client_priv, server_pub_wire, th_ch_sh, true,
    )
    let client_fin = @msg.frame(
      Finished,
      @keys.finished(client_hs_secret[:], th_app[:][:]),
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
    // 1-RTT keys from the same handshake.
    let master = @keys.master(
      tls13_handshake_secret_from_ecdhe(client_priv, server_pub_wire),
    )
    let client_app_keys = @crypto.application(master, th_app, client=true)
    let server_app_keys = @crypto.application(master, th_app, client=false)
    client_ep.send_datagram(
      @conn.send_short(
        dcid,
        0,
        4,
        [
          @frame.Stream(
            id=0UL,
            offset=0UL,
            fin=true,
            data=@http3.request(
              "GET",
              "https",
              "lfanke.example",
              "/hello",
              [],
              b"",
            ),
          ),
        ],
        client_app_keys,
      ),
      server_addr,
    )
    let (resp_dg, _) = client_ep.recv_datagram()
    let resp_frames = match
      @conn.recv_short(resp_dg, client_cid.length(), server_app_keys) {
      Some((fr, _)) => fr
      None => abort("client could not open the response")
    }
    let mut resp = b""
    for frame in resp_frames {
      match frame {
        @frame.Stream(id~, data~, ..) => if id == 0UL { resp = data }
        _ => ()
      }
    }
    @async.sleep(50)
    assert_eq(connected.val, true)
    let (headers, body) = @http3.read_message(resp)
    assert_eq(find_header(headers, ":status"), "200")
    assert_eq(body, b"one connection")
    client_ep.close()
    server_ep.close()
  })
}

///|
/// A field's value out of a list, empty when it is not there.
fn find_header(headers : Array[@header.Header], name : String) -> String {
  for h in headers {
    let (n, v) = h.ascii()
    if n == name {
      return v
    }
  }
  ""
}
