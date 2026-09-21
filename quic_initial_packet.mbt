// QUIC Initial packet protection, end to end (RFC 9001 §5.3 + §5.4 over an RFC 9000
// §17.2.2 long header). This is where the crypto stack — HKDF key schedule,
// AES-128-GCM sealing, and header protection — becomes a packet on the wire.

///|
/// The AEAD nonce: the packet number, left-padded to the IV length, XORed with the IV
/// (RFC 9001 §5.3). The packet number occupies the low 8 bytes; higher IV bytes pass
/// through unchanged.
fn quic_nonce(iv : Bytes, packet_number : Int64) -> Bytes {
  let buf = Buffer()
  let n = iv.length()
  for i = 0; i < n; i = i + 1 {
    let bytepos = n - 1 - i
    let pn_byte = if bytepos >= 8 {
      0
    } else {
      ((packet_number >> (bytepos * 8)) & 0xffL).to_int()
    }
    buf.write_byte((iv[i].to_int() ^ pn_byte).to_byte())
  }
  buf.to_bytes()
}

///|
/// Build an Initial long header (RFC 9000 §17.2.2). The first byte carries the header
/// form, fixed bit, Initial type, and the two-bit packet-number length; `length` is
/// the varint-encoded size of the packet number plus the sealed payload (with tag).
fn quic_initial_header(
  version : UInt,
  dcid : Bytes,
  scid : Bytes,
  token : Bytes,
  packet_number : Int64,
  pn_length : Int,
  sealed_len : Int,
) -> Bytes {
  let h = Buffer()
  h.write_byte((0xc0 | ((pn_length - 1) & 0x03)).to_byte())
  for i = 3; i >= 0; i = i - 1 {
    h.write_byte(((version >> (i * 8)) & 0xffU).to_byte())
  }
  h.write_byte(dcid.length().to_byte())
  h.write_bytes(dcid[:])
  h.write_byte(scid.length().to_byte())
  h.write_bytes(scid[:])
  h.write_bytes(quic_varint_encode(token.length().to_uint64())[:])
  h.write_bytes(token[:])
  h.write_bytes(quic_varint_encode((pn_length + sealed_len).to_uint64())[:])
  for i = pn_length - 1; i >= 0; i = i - 1 {
    h.write_byte(((packet_number >> (i * 8)) & 0xffL).to_byte())
  }
  h.to_bytes()
}

///|
/// Protect a QUIC Initial packet: assemble the long header, AEAD-seal `payload` with
/// the unprotected header as associated data (RFC 9001 §5.3), then apply header
/// protection (§5.4). `sealed_len` in the length field accounts for the 16-byte tag.
pub fn quic_protect_initial(
  version : UInt,
  dcid : Bytes,
  scid : Bytes,
  token : Bytes,
  packet_number : Int64,
  pn_length : Int,
  payload : Bytes,
  key : Bytes,
  iv : Bytes,
  hp : Bytes,
) -> Bytes {
  let header = quic_initial_header(
    version,
    dcid,
    scid,
    token,
    packet_number,
    pn_length,
    payload.length() + 16,
  )
  let pn_offset = header.length() - pn_length
  let nonce = quic_nonce(iv, packet_number)
  let box = gcm_seal(key, nonce, payload, header)
  let packet = Buffer()
  packet.write_bytes(header[:])
  packet.write_bytes(box[:])
  quic_header_protect(packet.to_bytes(), pn_offset, pn_length, hp)
}

///|
/// Remove protection from a received Initial packet whose packet-number field starts
/// at `pn_offset`: strip header protection, reconstruct the packet number and nonce,
/// and AEAD-open the payload with the recovered header as associated data. Returns the
/// plaintext payload and packet number, or `None` if authentication fails.
pub fn quic_unprotect_initial(
  packet : Bytes,
  pn_offset : Int,
  key : Bytes,
  iv : Bytes,
  hp : Bytes,
) -> (Bytes, Int64)? {
  let (recovered, pn_length) = quic_header_unprotect(packet, pn_offset, hp)
  let mut pn = 0L
  for i = 0; i < pn_length; i = i + 1 {
    pn = (pn << 8) | recovered[pn_offset + i].to_int64()
  }
  let header_end = pn_offset + pn_length
  let aad = recovered[0:header_end].to_owned()
  let ciphertext = recovered[header_end:].to_owned()
  let nonce = quic_nonce(iv, pn)
  match gcm_open(key, nonce, ciphertext, aad) {
    Some(pt) => Some((pt, pn))
    None => None
  }
}
