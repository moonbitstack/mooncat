// A QUIC server processing a client's Initial flight end to end (RFC 9001 §5): a real
// protected Initial packet carrying a ClientHello in a CRYPTO frame advances the server
// handshake to RECVD_CH; a ClientHello split across two packets reassembles first.

///|
/// The Initial packet keys a client uses toward a server, both derived from `dcid`.
fn client_initial_keys(dcid : Bytes) -> QuicPacketKeys {
  quic_packet_keys(quic_client_initial_secret(dcid))
}

///|
test "server conn: a ClientHello in one Initial packet reaches RECVD_CH" {
  let dcid = qv_hexb("8394c8f03e515708")
  let keys = client_initial_keys(dcid)
  let ch = tls_encode_handshake(1, b"clienthello-body")
  let packet = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=ch)],
    keys,
  )
  let server = QuicServerConn::new(dcid)
  assert_eq(server.receive_initial(packet), [1])
  assert_eq(server.handshake_state(), RecvdClientHello)
  // The ack-eliciting Initial owes an ACK.
  assert_eq(server.initial_ack_pending(), true)
}

///|
test "server conn: a ClientHello split across two Initial packets reassembles" {
  let dcid = qv_hexb("0001020304050607")
  let keys = client_initial_keys(dcid)
  let ch = tls_encode_handshake(1, b"a-longer-clienthello-body")
  let first = ch[0:15].to_owned()
  let rest = ch[15:ch.length()].to_owned()
  let packet1 = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=first)],
    keys,
  )
  let packet2 = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    1,
    4,
    [Crypto(offset=15, data=rest)],
    keys,
  )
  let server = QuicServerConn::new(dcid)
  // The first packet delivers only a partial handshake message: nothing processed yet.
  assert_eq(server.receive_initial(packet1), [])
  assert_eq(server.handshake_state(), Start)
  // The second packet completes it.
  assert_eq(server.receive_initial(packet2), [1])
  assert_eq(server.handshake_state(), RecvdClientHello)
}

///|
test "server conn: send_server_hello produces a ServerHello the client can decode" {
  let dcid = qv_hexb("8394c8f03e515708")
  let keys = client_initial_keys(dcid)
  // The client sends its ClientHello; the server receives it.
  let ch_packet = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=tls_encode_handshake(1, b"ch"))],
    keys,
  )
  let server = QuicServerConn::new(dcid)
  let _ = server.receive_initial(ch_packet)
  assert_eq(server.handshake_state(), RecvdClientHello)
  // The server builds and protects its ServerHello.
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\xab'),
    session_id: b"",
    cipher_suite: 0x1301,
    extensions: [],
  }
  let sh_packet = server.send_server_hello(sh, b"", b"\x01\x02\x03\x04", 0)
  // ServerHello alone does not complete the flight; the state stays at RECVD_CH until the
  // Handshake-space messages are sent.
  assert_eq(server.handshake_state(), RecvdClientHello)
  // The client (sharing the Initial keys) receives it and decodes the ServerHello.
  let decoded = match quic_recv_initial(sh_packet, keys) {
    Some((frames, _)) => {
      let mut result : TlsServerHello? = None
      for frame in frames {
        match frame {
          Crypto(data~, ..) =>
            match tls_parse_handshake(data[:]) {
              Some((2, body)) => result = decode_server_hello(body[:])
              _ => ()
            }
          _ => ()
        }
      }
      result
    }
    None => abort("ServerHello Initial packet failed to authenticate")
  }
  match decoded {
    Some(d) => assert_eq(d, sh)
    None => abort("expected a ServerHello CRYPTO frame")
  }
}

///|
test "server conn: send_handshake_flight emits EE/Cert/CertVerify/Finished the client authenticates" {
  let dcid = qv_hexb("8394c8f03e515708")
  let initial_keys = client_initial_keys(dcid)
  let server = QuicServerConn::new(dcid)
  // Client sends its ClientHello; the server receives it, then sends its ServerHello.
  let ch = tls_encode_handshake(1, b"ch")
  let ch_packet = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=ch)],
    initial_keys,
  )
  let _ = server.receive_initial(ch_packet)
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\xcd'),
    session_id: b"",
    cipher_suite: 0x1301,
    extensions: [],
  }
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let sh_msg = encode_server_hello(sh)
  // The server sends its Handshake-space flight (a real 32-byte server handshake secret).
  let secret = qv_hexb(
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
  )
  let ee_body = b"encrypted-extensions"
  let cert_body = b"the-server-certificate"
  let cv_body = b"the-certificate-verify-signature"
  let hs_packet = server.send_handshake_flight(
    secret, ee_body, cert_body, cv_body, b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  // With the whole flight sent, the server now waits for the client's Finished.
  assert_eq(server.handshake_state(), WaitFinished)
  // The client opens the Handshake packet with the same handshake-space keys and splits the
  // CRYPTO stream back into the four handshake messages.
  let hs_keys = quic_packet_keys(secret)
  let msgs = match quic_recv_handshake(hs_packet, hs_keys) {
    Some((frames, _)) => {
      let mut crypto = b""
      for frame in frames {
        match frame {
          Crypto(data~, ..) => crypto = bytes_concat(crypto, data)
          _ => ()
        }
      }
      let out : Array[(Int, Bytes)] = []
      let view = crypto[:]
      let mut off = 0
      for ;; {
        match tls_parse_handshake(view[off:]) {
          Some((t, body)) => {
            out.push((t, body))
            off = off + 4 + body.length()
          }
          None => break
        }
      }
      out
    }
    None => abort("Handshake flight failed to authenticate")
  }
  // The four handshake messages, in order.
  assert_eq(msgs.length(), 4)
  assert_eq(msgs[0].0, 8) // EncryptedExtensions
  assert_eq(msgs[1].0, 11) // Certificate
  assert_eq(msgs[2].0, 15) // CertificateVerify
  assert_eq(msgs[3].0, 20) // Finished
  // The Finished verify_data is the MAC over the transcript CH..SH..EE..Cert..CertVerify.
  let ee = tls_encode_handshake(8, ee_body)
  let cert = tls_encode_handshake(11, cert_body)
  let cv = tls_encode_handshake(15, cv_body)
  let transcript = bytes_concat(
    bytes_concat(bytes_concat(bytes_concat(ch, sh_msg), ee), cert),
    cv,
  )
  let expected = tls13_finished_verify_data(secret, @sha2.hash(transcript[:]))
  assert_eq(msgs[3].1, expected)
}

///|
test "server conn: receive_handshake verifies the client Finished and reaches CONNECTED" {
  let dcid = qv_hexb("8394c8f03e515708")
  let initial_keys = client_initial_keys(dcid)
  let server = QuicServerConn::new(dcid)
  // Drive the server through ClientHello, ServerHello, and its Handshake flight.
  let ch = tls_encode_handshake(1, b"ch")
  let ch_packet = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=ch)],
    initial_keys,
  )
  let _ = server.receive_initial(ch_packet)
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\xcd'),
    session_id: b"",
    cipher_suite: 0x1301,
    extensions: [],
  }
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let sh_msg = encode_server_hello(sh)
  let server_secret = qv_hexb(
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
  )
  let ee_body = b"encrypted-extensions"
  let cert_body = b"the-server-certificate"
  let cv_body = b"the-certificate-verify-signature"
  let _ = server.send_handshake_flight(
    server_secret, ee_body, cert_body, cv_body, b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  assert_eq(server.handshake_state(), WaitFinished)
  // Reconstruct the transcript the server holds, through its own Finished, so the client
  // can compute its Finished over the same bytes.
  let ee = tls_encode_handshake(8, ee_body)
  let cert = tls_encode_handshake(11, cert_body)
  let cv = tls_encode_handshake(15, cv_body)
  let through_cv = bytes_concat(
    bytes_concat(bytes_concat(bytes_concat(ch, sh_msg), ee), cert),
    cv,
  )
  let server_fin = tls_encode_handshake(
    20,
    tls13_finished_verify_data(server_secret, @sha2.hash(through_cv[:])),
  )
  let through_server_fin = bytes_concat(through_cv, server_fin)
  // The client Finished MACs the transcript through the server Finished with the client
  // handshake secret; it travels in a Handshake packet protected with the client keys.
  let client_secret = qv_hexb(
    "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21",
  )
  let client_fin = tls_encode_handshake(
    20,
    tls13_finished_verify_data(client_secret, @sha2.hash(through_server_fin[:])),
  )
  let client_keys = quic_packet_keys(client_secret)
  let fin_packet = quic_send_handshake(
    1U,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=client_fin)],
    client_keys,
  )
  assert_eq(
    server.receive_handshake(fin_packet, client_keys, client_secret),
    true,
  )
  assert_eq(server.handshake_state(), Connected)
}

///|
test "server conn: receive_handshake rejects a Finished with the wrong verify_data" {
  let dcid = qv_hexb("8394c8f03e515708")
  let initial_keys = client_initial_keys(dcid)
  let server = QuicServerConn::new(dcid)
  let ch = tls_encode_handshake(1, b"ch")
  let ch_packet = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=ch)],
    initial_keys,
  )
  let _ = server.receive_initial(ch_packet)
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\xcd'),
    session_id: b"",
    cipher_suite: 0x1301,
    extensions: [],
  }
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let server_secret = qv_hexb(
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
  )
  let _ = server.send_handshake_flight(
    server_secret, b"ee", b"cert", b"cv", b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  // A Finished whose verify_data is garbage does not authenticate: receive_handshake
  // returns false even though the message advances the state.
  let client_secret = qv_hexb(
    "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21",
  )
  let bad_fin = tls_encode_handshake(20, Bytes::make(32, b'\x00'))
  let client_keys = quic_packet_keys(client_secret)
  let fin_packet = quic_send_handshake(
    1U,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=bad_fin)],
    client_keys,
  )
  assert_eq(
    server.receive_handshake(fin_packet, client_keys, client_secret),
    false,
  )
}

///|
test "server conn: the handshake flight is protected with ECDHE-derived keys the client can decrypt" {
  let dcid = qv_hexb("8394c8f03e515708")
  let client_priv = qv_hexb(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_priv = qv_hexb(
    "6666666666666666666666666666666666666666666666666666666666666666",
  )
  let client_pub = tls13_x25519_public(client_priv)
  let server_pub = tls13_x25519_public(server_priv)
  // The client sends a real ClientHello carrying its x25519 key_share.
  let ch = TlsClientHello::{
    random: Bytes::make(32, b'\x23'),
    session_id: b"heke1228",
    cipher_suites: [0x1301],
    extensions: [
      {
        ext_type: tls_ext_key_share,
        data: tls_encode_key_share_client([(tls_group_x25519, client_pub)]),
      },
    ],
  }
  let ch_msg = encode_client_hello(ch)
  let initial_keys = client_initial_keys(dcid)
  let ch_initial = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=ch_msg)],
    initial_keys,
  )
  let server = QuicServerConn::new(dcid)
  let _ = server.receive_initial(ch_initial)
  // The server replies with a ServerHello carrying its key_share, then derives its handshake
  // secret from the ECDHE over the CH..SH transcript.
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\x66'),
    session_id: b"heke1228",
    cipher_suite: 0x1301,
    extensions: [tls_key_share_extension(tls_group_x25519, server_pub)],
  }
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let th = server.transcript_hash()
  let server_hs_secret = match
    tls13_server_hs_secret_from_client_hello(ch_msg, server_priv, th) {
    Some(v) => v
    None => abort("server could not derive its handshake secret")
  }
  // The server protects its Handshake flight with the derived keys.
  let flight = server.send_handshake_flight(
    server_hs_secret, b"ee", b"cert", b"cv", b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  // The client independently derives the same server handshake secret and decrypts the flight.
  let client_hs_secret = tls13_ecdhe_handshake_traffic_secret(
    client_priv, server_pub, th, false,
  )
  assert_eq(client_hs_secret, server_hs_secret)
  let types = match
    quic_recv_handshake(flight, quic_packet_keys(client_hs_secret)) {
    Some((frames, _)) => {
      let out : Array[Int] = []
      for frame in frames {
        match frame {
          Crypto(data~, ..) => {
            let view = data[:]
            let mut off = 0
            for ;; {
              match tls_parse_handshake(view[off:]) {
                Some((t, body)) => {
                  out.push(t)
                  off = off + 4 + body.length()
                }
                None => break
              }
            }
          }
          _ => ()
        }
      }
      out
    }
    None =>
      abort("client could not decrypt the ECDHE-protected handshake flight")
  }
  assert_eq(types, [8, 11, 15, 20]) // EE, Certificate, CertificateVerify, Finished
}

///|
test "server conn: a full ECDHE handshake reaches CONNECTED" {
  let dcid = qv_hexb("8394c8f03e515708")
  let client_priv = qv_hexb(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_priv = qv_hexb(
    "6666666666666666666666666666666666666666666666666666666666666666",
  )
  let client_pub = tls13_x25519_public(client_priv)
  let server_pub = tls13_x25519_public(server_priv)
  // Client ClientHello with key_share, delivered over an Initial packet.
  let ch = TlsClientHello::{
    random: Bytes::make(32, b'\x23'),
    session_id: b"lfanke",
    cipher_suites: [0x1301],
    extensions: [
      {
        ext_type: tls_ext_key_share,
        data: tls_encode_key_share_client([(tls_group_x25519, client_pub)]),
      },
    ],
  }
  let ch_msg = encode_client_hello(ch)
  let initial_keys = client_initial_keys(dcid)
  let server = QuicServerConn::new(dcid)
  let _ = server.receive_initial(
    quic_send_initial(
      1U,
      dcid,
      b"",
      b"",
      0,
      4,
      [Crypto(offset=0, data=ch_msg)],
      initial_keys,
    ),
  )
  // Server ServerHello with key_share; derive the handshake secret from the ECDHE.
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\x66'),
    session_id: b"lfanke",
    cipher_suite: 0x1301,
    extensions: [tls_key_share_extension(tls_group_x25519, server_pub)],
  }
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let th_ch_sh = server.transcript_hash()
  let server_hs_secret = tls13_ecdhe_handshake_traffic_secret(
    server_priv, client_pub, th_ch_sh, false,
  )
  // Server sends its Handshake flight with the derived keys.
  let ee_body = b"ee"
  let cert_body = b"cert"
  let cv_body = b"cv"
  let _ = server.send_handshake_flight(
    server_hs_secret, ee_body, cert_body, cv_body, b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  assert_eq(server.handshake_state(), WaitFinished)
  // Client derives the same handshake secrets and reconstructs the transcript through the
  // server Finished, exactly as the server holds it.
  let client_hs_secret = tls13_ecdhe_handshake_traffic_secret(
    client_priv, server_pub, th_ch_sh, true,
  )
  let sh_msg = encode_server_hello(sh)
  let ee = tls_encode_handshake(8, ee_body)
  let cert = tls_encode_handshake(11, cert_body)
  let cv = tls_encode_handshake(15, cv_body)
  let through_cv = bytes_concat(
    bytes_concat(bytes_concat(bytes_concat(ch_msg, sh_msg), ee), cert),
    cv,
  )
  let server_fin = tls_encode_handshake(
    20,
    tls13_finished_verify_data(server_hs_secret, @sha2.hash(through_cv[:])),
  )
  let through_server_fin = bytes_concat(through_cv, server_fin)
  // Client sends its Finished over the shared transcript in a Handshake packet.
  let client_fin = tls_encode_handshake(
    20,
    tls13_finished_verify_data(
      client_hs_secret,
      @sha2.hash(through_server_fin[:]),
    ),
  )
  let client_keys = quic_packet_keys(client_hs_secret)
  let fin_packet = quic_send_handshake(
    1U,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=client_fin)],
    client_keys,
  )
  // The server verifies the client Finished and the handshake completes.
  assert_eq(
    server.receive_handshake(fin_packet, client_keys, client_hs_secret),
    true,
  )
  assert_eq(server.handshake_state(), Connected)
}

///|
test "server conn: a tampered Initial packet is rejected" {
  let dcid = qv_hexb("8394c8f03e515708")
  let keys = client_initial_keys(dcid)
  let packet = quic_send_initial(
    1U,
    dcid,
    b"",
    b"",
    0,
    4,
    [Crypto(offset=0, data=tls_encode_handshake(1, b"ch"))],
    keys,
  )
  let buf = Buffer()
  for i = 0; i < packet.length(); i = i + 1 {
    if i == packet.length() - 1 {
      buf.write_byte((packet[i].to_int() ^ 0xff).to_byte())
    } else {
      buf.write_byte(packet[i])
    }
  }
  let server = QuicServerConn::new(dcid)
  let rejected = try {
    let _ = server.receive_initial(buf.to_bytes())
    false
  } catch {
    _ => true
  }
  assert_eq(rejected, true)
}
