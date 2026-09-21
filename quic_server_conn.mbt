// A QUIC server connection's Initial-flight processing (RFC 9000 §7, RFC 9001 §5): it
// ties the Initial packet protection, the per-level CRYPTO reassembly, and the TLS 1.3
// handshake runner together. Receiving an Initial packet unprotects it with the keys
// derived from the client's connection id, records the packet number for acknowledgement,
// reassembles the CRYPTO stream, and drives the handshake with the contiguous handshake
// bytes. This is the pure connection core the async UDP transport wraps; feeding it a
// client's Initial packet advances the server handshake to RECVD_CH.

///|
/// A QUIC server connection mid-handshake: the Initial keys, the packet-number/CRYPTO
/// bookkeeping, and the TLS handshake it is driving.
pub struct QuicServerConn {
  initial_keys : QuicPacketKeys
  handshake : TlsServerHandshake
  conn : QuicConnection
}

///|
/// A server connection for a client whose Destination Connection ID is `dcid` (the
/// Initial secret and keys derive from it, RFC 9001 §5.2).
pub fn QuicServerConn::new(dcid : Bytes) -> QuicServerConn {
  {
    initial_keys: quic_packet_keys(quic_client_initial_secret(dcid)),
    handshake: TlsServerHandshake::new(),
    conn: QuicConnection::new(true),
  }
}

///|
/// The current TLS handshake state.
pub fn QuicServerConn::handshake_state(self : QuicServerConn) -> TlsServerState {
  self.handshake.state()
}

///|
/// The transcript hash over the handshake messages processed so far.
pub fn QuicServerConn::transcript_hash(self : QuicServerConn) -> Bytes {
  self.handshake.transcript_hash()
}

///|
/// The raw ClientHello the connection received (empty before one arrives): the source a
/// server runs the ECDHE key_share from to derive its handshake secrets.
pub fn QuicServerConn::client_hello(self : QuicServerConn) -> Bytes {
  self.handshake.client_hello()
}

///|
/// Negotiate the ClientHello this connection received (RFC 8446 §4.1.1): the group and key
/// share to run the ECDHE with, and the signature scheme to sign the CertificateVerify under,
/// read off what the client offered. Raises the §6 alert for a ClientHello this build cannot
/// serve, and returns `Retry` when the answer is a HelloRetryRequest.
pub fn QuicServerConn::negotiate(
  self : QuicServerConn,
) -> TlsNegotiation raise TlsAlert {
  self.handshake.negotiate()
}

///|
/// Whether an ACK is owed in the Initial space.
pub fn QuicServerConn::initial_ack_pending(self : QuicServerConn) -> Bool {
  self.conn.space(QuicLevel::Initial).ack_pending()
}

///|
/// Build the server's ServerHello response: encode it, fold it into the transcript, and
/// protect it into an Initial packet addressed to `out_dcid` (the client's source
/// connection id) from `out_scid`, at Initial packet number `pn` (RFC 9001 §5.3). The
/// state stays at RECVD_CH — the server flight is not complete until the Handshake-space
/// messages (EncryptedExtensions, Certificate, CertificateVerify, Finished) are sent by
/// `send_handshake_flight`, which advances it to WAIT_FINISHED.
pub fn QuicServerConn::send_server_hello(
  self : QuicServerConn,
  server_hello : TlsServerHello,
  out_dcid : Bytes,
  out_scid : Bytes,
  pn : Int64,
) -> Bytes {
  let sh_msg = encode_server_hello(server_hello)
  self.handshake.record_sent(sh_msg)
  quic_send_initial(
    1U,
    out_dcid,
    out_scid,
    b"",
    pn,
    4,
    [Crypto(offset=0, data=sh_msg)],
    self.initial_keys,
  )
}

///|
/// Send the server's Handshake-space flight (RFC 8446 §4, RFC 9001 §5): encode
/// EncryptedExtensions, Certificate, and CertificateVerify, fold them into the transcript
/// in order, compute the server Finished as `HMAC(finished_key, transcript hash through
/// CertificateVerify)` over `server_hs_secret`, fold the Finished too, and advance the
/// state past the whole flight (RECVD_CH → WAIT_FINISHED). The four messages form one
/// contiguous CRYPTO stream, protected into a Handshake packet with the handshake-space
/// keys `quic_packet_keys(server_hs_secret)`, addressed to `out_dcid` from `out_scid` at
/// Handshake packet number `pn`. `server_hs_secret` is the server handshake traffic secret
/// the key schedule derives once ECDHE completes.
pub fn QuicServerConn::send_handshake_flight(
  self : QuicServerConn,
  server_hs_secret : Bytes,
  encrypted_extensions : Bytes,
  certificate : Bytes,
  certificate_verify : Bytes,
  out_dcid : Bytes,
  out_scid : Bytes,
  pn : Int64,
) -> Bytes raise {
  let ee = tls_encode_handshake(8, encrypted_extensions)
  let cert = tls_encode_handshake(11, certificate)
  let cv = tls_encode_handshake(15, certificate_verify)
  self.handshake.record_sent(ee)
  self.handshake.record_sent(cert)
  self.handshake.record_sent(cv)
  let verify_data = tls13_finished_verify_data(
    server_hs_secret,
    self.handshake.transcript_hash(),
  )
  let fin = tls_encode_handshake(20, verify_data)
  self.handshake.record_sent(fin)
  self.handshake.sent_flight(false)
  let crypto = bytes_concat(bytes_concat(bytes_concat(ee, cert), cv), fin)
  quic_send_handshake(
    1U,
    out_dcid,
    out_scid,
    pn,
    4,
    [Crypto(offset=0, data=crypto)],
    quic_packet_keys(server_hs_secret),
  )
}

///|
/// Send the server's Handshake-space flight with a real CertificateVerify (RFC 8446 §4.4.3):
/// like `send_handshake_flight`, but instead of taking the CertificateVerify body it signs the
/// transcript through the Certificate with the certificate's ES256 key. Encode
/// EncryptedExtensions and Certificate, fold them, sign the transcript hash then standing (the
/// hash through the Certificate) into the CertificateVerify body, fold it, then the server
/// Finished. A peer holding the certificate's public key can verify the signature and
/// authenticate the server — the real handshake flight, no placeholder CertificateVerify.
pub fn QuicServerConn::send_handshake_flight_signed(
  self : QuicServerConn,
  server_hs_secret : Bytes,
  encrypted_extensions : Bytes,
  certificate : Bytes,
  signing_key : @ecdsa.PrivateKey,
  out_dcid : Bytes,
  out_scid : Bytes,
  pn : Int64,
) -> Bytes raise {
  let ee = tls_encode_handshake(8, encrypted_extensions)
  let cert = tls_encode_handshake(11, certificate)
  self.handshake.record_sent(ee)
  self.handshake.record_sent(cert)
  let cv_body = tls13_certificate_verify_sign(
    signing_key,
    tls13_cv_context_server,
    self.handshake.transcript_hash(),
  )
  let cv = tls_encode_handshake(15, cv_body)
  self.handshake.record_sent(cv)
  let verify_data = tls13_finished_verify_data(
    server_hs_secret,
    self.handshake.transcript_hash(),
  )
  let fin = tls_encode_handshake(20, verify_data)
  self.handshake.record_sent(fin)
  self.handshake.sent_flight(false)
  let crypto = bytes_concat(bytes_concat(bytes_concat(ee, cert), cv), fin)
  quic_send_handshake(
    1U,
    out_dcid,
    out_scid,
    pn,
    4,
    [Crypto(offset=0, data=crypto)],
    quic_packet_keys(server_hs_secret),
  )
}

///|
/// Drive an already-unprotected packet's `frames` at `level`, numbered `pn`: record the
/// packet for acknowledgement and feed its CRYPTO frames into that level's reassembler,
/// driving the handshake with whatever handshake bytes become contiguous. Returns the
/// handshake message types processed. A driver that unprotected the packet itself — because
/// it also wants the ACK and CONNECTION_CLOSE frames beside the CRYPTO — enters here rather
/// than through `receive_initial`.
pub fn QuicServerConn::on_frames(
  self : QuicServerConn,
  level : QuicLevel,
  frames : Array[QuicFrame],
  pn : Int64,
) -> Array[Int] raise {
  self.conn.on_packet_received(level, pn, quic_payload_is_ack_eliciting(frames))
  let processed : Array[Int] = []
  for frame in frames {
    match frame {
      Crypto(offset~, data~) => {
        let contiguous = self.conn.on_crypto_frame(level, offset, data)
        if contiguous.length() > 0 {
          for msg_type in self.handshake.feed(contiguous) {
            processed.push(msg_type)
          }
        }
      }
      _ => ()
    }
  }
  processed
}

///|
/// Receive a client Initial packet: unprotect it, record its number for acknowledgement,
/// reassemble its CRYPTO frames, and drive the handshake with the contiguous handshake
/// bytes. Returns the handshake message types processed. Raises if the packet fails to
/// authenticate.
pub fn QuicServerConn::receive_initial(
  self : QuicServerConn,
  packet : Bytes,
) -> Array[Int] raise {
  let (frames, pn) = match quic_recv_initial(packet, self.initial_keys) {
    Some(v) => v
    None => raise QuicPayloadError("Initial packet failed to authenticate")
  }
  self.on_frames(QuicLevel::Initial, frames, pn)
}

///|
/// Receive the client's Handshake-space flight — in this no-client-authentication path,
/// the client Finished (RFC 8446 §4.4.4): unprotect the Handshake packet with the client
/// handshake keys, reassemble its CRYPTO stream, verify the Finished `verify_data` against
/// `client_hs_secret` over the transcript through the server Finished, then fold it in to
/// advance the handshake to CONNECTED. Returns whether the handshake is now connected with
/// a Finished that authenticated. Raises if the packet fails to authenticate.
pub fn QuicServerConn::receive_handshake(
  self : QuicServerConn,
  packet : Bytes,
  client_hs_keys : QuicPacketKeys,
  client_hs_secret : Bytes,
) -> Bool raise {
  let (frames, pn) = match quic_recv_handshake(packet, client_hs_keys) {
    Some(v) => v
    None => raise QuicPayloadError("Handshake packet failed to authenticate")
  }
  self.on_handshake_frames(frames, pn, client_hs_secret)
}

///|
/// Drive the client's Handshake-space `frames`, numbered `pn`, already unprotected: record
/// the packet, reassemble its CRYPTO stream, verify any Finished in it against
/// `client_hs_secret` over the transcript as it stands, then fold the messages in. Returns
/// whether the handshake is now connected with a Finished that authenticated — the frame-level
/// half of `receive_handshake`, for a driver holding the decrypted packet.
pub fn QuicServerConn::on_handshake_frames(
  self : QuicServerConn,
  frames : Array[QuicFrame],
  pn : Int64,
  client_hs_secret : Bytes,
) -> Bool raise {
  self.conn.on_packet_received(
    QuicLevel::Handshake,
    pn,
    quic_payload_is_ack_eliciting(frames),
  )
  let mut finished_ok = false
  for frame in frames {
    match frame {
      Crypto(offset~, data~) => {
        let contiguous = self.conn.on_crypto_frame(
          QuicLevel::Handshake,
          offset,
          data,
        )
        if contiguous.length() > 0 {
          // The Finished MACs the transcript as it stands now (through the server Finished),
          // so verify against the current hash before folding the client Finished in.
          let th = self.handshake.transcript_hash()
          let view = contiguous[:]
          let mut off = 0
          for ;; {
            match tls_parse_handshake(view[off:]) {
              Some((t, body)) => {
                if t == tls_hs_finished {
                  finished_ok = tls13_finished_verify(
                    client_hs_secret, th, body,
                  )
                }
                off = off + 4 + body.length()
              }
              None => break
            }
          }
          let _ = self.handshake.feed(contiguous)
        }
      }
      _ => ()
    }
  }
  self.handshake.is_connected() && finished_ok
}
