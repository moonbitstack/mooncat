// The server's Handshake flight carrying a real ES256 CertificateVerify (RFC 8446 §4.4.3):
// the server signs the transcript through its Certificate, and the client — holding the
// certificate's public key — authenticates the signature off the decrypted flight.

///|
test "server conn: the handshake flight carries a real ES256 CertificateVerify the client authenticates" {
  let dcid = qv_hexb("8394c8f03e515708")
  let client_priv = qv_hexb(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_priv = qv_hexb(
    "6666666666666666666666666666666666666666666666666666666666666666",
  )
  let client_pub = tls13_x25519_public(client_priv)
  let server_pub = tls13_x25519_public(server_priv)
  // The certificate's ES256 key pair (a P-256 scalar below the group order).
  let cert_key = ec_private(
    "233333333333333333333333333333333333333333333333333333333333eeff",
  )
  let cert_pub = cert_key.public()
  // Client ClientHello with its x25519 key_share, delivered over an Initial packet.
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
      client_initial_keys(dcid),
    ),
  )
  // Server ServerHello with its key_share; derive the handshake secret from the ECDHE.
  let sh = TlsServerHello::{
    random: Bytes::make(32, b'\x66'),
    session_id: b"lfanke",
    cipher_suite: 0x1301,
    extensions: [tls_key_share_extension(tls_group_x25519, server_pub)],
  }
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let sh_msg = encode_server_hello(sh)
  let th_ch_sh = server.transcript_hash()
  let server_hs_secret = tls13_ecdhe_handshake_traffic_secret(
    server_priv, client_pub, th_ch_sh, false,
  )
  // The server sends its Handshake flight, signing the CertificateVerify with the cert key.
  let ee_body = b"encrypted-extensions"
  let cert_body = b"the-server-certificate"
  let flight = server.send_handshake_flight_signed(
    server_hs_secret, ee_body, cert_body, cert_key, b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  // The server protects its flight with the server handshake traffic secret; the client
  // derives the same secret (is_client = false) and decrypts, pulling the CertificateVerify
  // message body (type 15) out of the CRYPTO stream.
  let server_hs_secret_client = tls13_ecdhe_handshake_traffic_secret(
    client_priv, server_pub, th_ch_sh, false,
  )
  assert_eq(server_hs_secret_client, server_hs_secret)
  let cv_body = match
    quic_recv_handshake(flight, quic_packet_keys(server_hs_secret_client)) {
    Some((frames, _)) => {
      let mut crypto = b""
      for frame in frames {
        match frame {
          Crypto(data~, ..) => crypto = bytes_concat(crypto, data)
          _ => ()
        }
      }
      let mut found = b""
      let view = crypto[:]
      let mut off = 0
      for ;; {
        match tls_parse_handshake(view[off:]) {
          Some((t, body)) => {
            if t == 15 {
              found = body
            }
            off = off + 4 + body.length()
          }
          None => break
        }
      }
      found
    }
    None => abort("client could not decrypt the signed handshake flight")
  }
  // The client reconstructs the transcript through the Certificate and verifies the signature.
  let ee = tls_encode_handshake(8, ee_body)
  let cert = tls_encode_handshake(11, cert_body)
  let th_through_cert = sha256(
    bytes_concat(bytes_concat(bytes_concat(ch_msg, sh_msg), ee), cert),
  )
  assert_eq(
    tls13_certificate_verify_check(
      cert_pub, tls13_cv_context_server, th_through_cert, cv_body,
    ),
    true,
  )
  // A different certificate key does not authenticate the signature.
  let other_pub = ec_private(
    "6666666666666666666666666666666666666666666666666666666666666666",
  ).public()
  assert_eq(
    tls13_certificate_verify_check(
      other_pub, tls13_cv_context_server, th_through_cert, cv_body,
    ),
    false,
  )
}
