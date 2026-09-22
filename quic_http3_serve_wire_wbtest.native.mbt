// An HTTP/3 server routing a real request over a UDP socket (RFC 9114 §4.1 over RFC 9000): the
// client sends a request on a stream in a 1-RTT packet; the server opens it off the wire, runs
// @http3.serve against a handler, and writes the response stream back — the request/response path
// a mooncat HTTP/3 server drives after the handshake, exercised end to end over the socket.

///|
async test "quic http3 serve over udp: the server routes a request through a handler and replies over the wire" {
  @async.with_task_group(g => {
    let master_secret = qv_hexb(
      "6666666666666666666666666666666666666666666666666666666666666666",
    )
    let th = @sha2.hash(b"http3-serve-wire-lfanke"[:])
    let client_app_keys = @crypto.application(master_secret, th, client=true)
    let server_app_keys = @crypto.application(master_secret, th, client=false)
    let server_cid = qv_hexb("00112233aabbccdd")
    let client_cid = qv_hexb("66778899eeff0011")
    let server_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let server_addr = server_ep.local_addr()
    let handler = fn(r : @http3.Request) -> @http3.Response {
      if r.meth == "GET" && r.path == "/hello" {
        @http3.Response::{
          status: "200",
          headers: [@header.Header::of("content-type", "text/plain")],
          body: b"served by mooncat h3",
        }
      } else {
        @http3.Response::{ status: "404", headers: [], body: b"", }
      }
    }
    // Server: take the request off stream 0, route it, and send the response stream back.
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
      let resp = @http3.serve(req, handler) catch { _ => b"" }
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
    // Client: send an HTTP/3 GET /hello and read the routed response.
    let client_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let req = @http3.request(
      "GET",
      "https",
      "lfanke.example",
      "/hello",
      [],
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
      None => abort("client could not open the response over the wire")
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
    assert_eq(body, b"served by mooncat h3")
    client_ep.close()
    server_ep.close()
  })
}
