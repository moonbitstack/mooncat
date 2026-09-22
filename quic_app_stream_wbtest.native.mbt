// An HTTP/3 request and response carried over QUIC STREAM frames in 1-RTT packets over a
// real async UDP socket (RFC 9114 §4.1 over RFC 9000 §19.8, protected per RFC 9001 §5.3).
// After the handshake reaches Connected, application data travels on QUIC streams: a request
// is a HEADERS+DATA byte run placed in a STREAM frame, sealed into a short (1-RTT) packet
// with the application keys, and sent as a datagram; the peer unprotects it, takes the run
// off the stream, and decodes the HTTP/3 message. This is the "流" layer meeting a real
// socket — the last transport seam above the handshake.

///|
async test "quic over udp: an HTTP/3 request and response round-trip over QUIC STREAM frames in 1-RTT packets over a real UDP socket" {
  @async.with_task_group(g => {
    // After the handshake both peers share the master secret and the ClientHello..server-
    // Finished transcript; each derives its own 1-RTT application keys from them. Key
    // agreement is proven by the handshake tests — this isolates the STREAM/HTTP3 mapping
    // over the wire, so the shared secret stands in for the handshake's output.
    let master_secret = qv_hexb(
      "2333333333333333333333333333333333333333333333333333333333333333",
    )
    let th = @sha2.hash(b"lfanke-connected-transcript"[:])
    let client_app_keys = @crypto.application(master_secret, th, client=true)
    let server_app_keys = @crypto.application(master_secret, th, client=false)
    let server_cid = qv_hexb("00112233aabbccdd")
    let client_cid = qv_hexb("66778899eeff0011")
    let server_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let server_addr = server_ep.local_addr()
    let request_ok : Ref[Bool] = { val: false, }
    // The server: receive the client's 1-RTT packet, unprotect it with the client application
    // keys, take the request off stream 0, decode it, and answer with its own 1-RTT packet
    // protected with the server application keys.
    let _ = g.spawn(() => {
      let (dg, client_addr) = server_ep.recv_datagram()
      let frames = match
        (@conn.recv_short(dg, server_cid.length(), client_app_keys) catch {
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
      let (headers, _body) = @http3.read_message(req) catch { _ => ([], b"") }
      request_ok.val = find_header(headers, ":method") == "GET" &&
        find_header(headers, ":path") == "/heke1228"
      let resp = @http3.response(
        "200",
        [@header.Header::of("content-type", "text/plain; charset=utf-8")],
        b"233 from mooncat over http3",
      )
      let resp_packet = @conn.send_short(
        client_cid,
        0,
        4,
        [@frame.Stream(id=0UL, offset=0UL, fin=true, data=resp)],
        server_app_keys,
      )
      server_ep.send_datagram(resp_packet, client_addr)
    })
    @async.sleep(100)
    // The client: send an HTTP/3 GET on stream 0 in a 1-RTT packet, then read the response.
    let client_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let req = @http3.request(
      "GET",
      "https",
      "lfanke.example",
      "/heke1228",
      [@header.Header::of("user-agent", "mooncat")],
      b"",
    )
    let req_packet = @conn.send_short(
      server_cid,
      0,
      4,
      [@frame.Stream(id=0UL, offset=0UL, fin=true, data=req)],
      client_app_keys,
    )
    client_ep.send_datagram(req_packet, server_addr)
    let (resp_dg, _) = client_ep.recv_datagram()
    let resp_frames = match
      @conn.recv_short(resp_dg, client_cid.length(), server_app_keys) {
      Some((fr, _)) => fr
      None => abort("client could not open the server's 1-RTT response")
    }
    let mut resp = b""
    for frame in resp_frames {
      match frame {
        @frame.Stream(id~, data~, ..) => if id == 0UL { resp = data }
        _ => ()
      }
    }
    let (headers, body) = @http3.read_message(resp)
    assert_eq(find_header(headers, ":status"), "200")
    assert_eq(body, b"233 from mooncat over http3")
    @async.sleep(150)
    assert_eq(request_ok.val, true)
    client_ep.close()
    server_ep.close()
  })
}
