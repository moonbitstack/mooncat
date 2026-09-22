// The server's complete, real Handshake flight (RFC 8446 §4.3–§4.4, RFC 9001 §8): after a real
// ECDHE ServerHello, the server sends EncryptedExtensions carrying the negotiated ALPN and its
// transport parameters, a Certificate message with its DER chain, a CertificateVerify that is a
// real ES256 signature over the transcript, and Finished — all protected with the derived
// handshake keys. The client decrypts the flight and parses every message back: the shape a
// real HTTP/3 client (curl) receives. Only the DER blob is opaque (X.509 parsing is separate).

///|
test "full flight: the server's Handshake flight carries real EE, Certificate, and ES256 CertificateVerify the client parses" {
  let dcid = qv_hexb("8394c8f03e515708")
  let client_priv = qv_hexb(
    "2333333333333333333333333333333333333333333333333333333333333333",
  )
  let server_priv = qv_hexb(
    "6666666666666666666666666666666666666666666666666666666666666666",
  )
  let client_pub = tls13_x25519_public(client_priv)
  let server_pub = tls13_x25519_public(server_priv)
  let cert_key = ec_private(
    "233333333333333333333333333333333333333333333333333333333333eeff",
  )
  let cert_pub = cert_key.public()
  // ClientHello (with key_share) over an Initial packet; server receives it.
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
  // ServerHello with key_share; derive the handshake secret from the ECDHE.
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
  let _ = server.send_server_hello(sh, b"", b"\x0a\x0b\x0c\x0d", 0)
  let sh_msg = @msg.server_hello(sh)
  let th_ch_sh = server.transcript_hash()
  let server_hs_secret = tls13_ecdhe_handshake_traffic_secret(
    server_priv, client_pub, th_ch_sh, false,
  )
  // The real flight: EncryptedExtensions (ALPN + transport params) and a Certificate chain.
  let params = [
    transport_param_int(tp_initial_max_data, 66666),
    transport_param_int(tp_active_connection_id_limit, 8),
  ]
  let ee_body = tls13_quic_encrypted_extensions(@ext.h3, params)
  // A real self-signed X.509 certificate whose key is the one that signs the CertificateVerify,
  // so the certificate and the signature are consistent — the identity a client authenticates.
  let der = @x509.self_signed(
    cert_key, b"\x2a", "mooncat.example", "250101000000Z", "350101000000Z",
  )
  let cert_body = @msg.certificate([der][:])
  let flight = server.send_handshake_flight_signed(
    server_hs_secret, ee_body, cert_body, cert_key, b"", b"\x0a\x0b\x0c\x0d", 0,
  )
  // The client derives the same server handshake secret and splits the flight into messages.
  let server_hs_secret_client = tls13_ecdhe_handshake_traffic_secret(
    client_priv, server_pub, th_ch_sh, false,
  )
  let msgs : Array[(@msg.Kind, Bytes)] = match
    quic_recv_handshake(flight, quic_packet_keys(server_hs_secret_client)) {
    Some((frames, _)) => {
      let mut crypto = b""
      for frame in frames {
        match frame {
          Crypto(data~, ..) => crypto = bytes_concat(crypto, data)
          _ => ()
        }
      }
      let out : Array[(@msg.Kind, Bytes)] = []
      let view = crypto[:]
      let mut off = 0
      for ;; {
        match @msg.unframe(view[off:]) {
          Some((t, body)) => {
            out.push((t, body))
            off = off + 4 + body.length()
          }
          None => break
        }
      }
      out
    }
    None => abort("client could not decrypt the server flight")
  }
  // The flight is EncryptedExtensions, Certificate, CertificateVerify, Finished.
  assert_eq(msgs.map(m => m.0), [
    @msg.Kind::EncryptedExtensions,
    @msg.Kind::Certificate,
    @msg.Kind::CertificateVerify,
    @msg.Kind::Finished,
  ])
  // EncryptedExtensions: the negotiated ALPN and the server's transport parameters.
  let ee_exts = match @msg.read_encrypted_extensions(msgs[0].1[:]) {
    Some(v) => v
    None => abort("EncryptedExtensions did not decode")
  }
  assert_eq(tls_selected_alpn(ee_exts), Some("h3"))
  assert_eq(tls_hello_quic_transport_params(ee_exts), params)
  // Certificate: the DER chain the server sent.
  assert_eq(@msg.read_certificate(msgs[1].1[:]), Some((b"", [der])))
  // CertificateVerify: a real ES256 signature over the transcript through the Certificate.
  let ee = @msg.frame(EncryptedExtensions, ee_body[:])
  let cert = @msg.frame(Certificate, cert_body[:])
  let th_through_cert = @sha2.hash(
    bytes_concat(bytes_concat(bytes_concat(ch_msg, sh_msg), ee), cert)[:],
  )
  assert_eq(
    tls13_certificate_verify_check(
      cert_pub,
      @msg.server_context,
      th_through_cert,
      msgs[2].1,
    ),
    true,
  )
}
