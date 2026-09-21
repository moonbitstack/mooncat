// QUIC header protection (RFC 9001 §5.4). After the payload is AEAD-sealed, the
// first byte's low bits and the packet-number field are masked with keystream sampled
// from the ciphertext, so the packet number is not visible on the wire. For the
// AES AEADs the mask is an AES-128-ECB block over the sample (§5.4.3).

///|
/// The header-protection mask: the first five bytes of AES-128-ECB(hp_key, sample),
/// where `sample` is 16 bytes of packet ciphertext (RFC 9001 §5.4.2/§5.4.3).
pub fn quic_hp_mask(hp_key : Bytes, sample : Bytes) -> Bytes {
  let sched = aes_key(hp_key)
  aes_block(sched, sample)[0:5].to_owned()
}

///|
/// The masked-bit set for the first byte: the low 4 bits on a long header, the low 5
/// on a short header (RFC 9001 §5.4.1). The header form is bit 0x80 of the first byte,
/// which is never itself protected.
fn hp_first_byte_mask(first : Int) -> Int {
  if (first & 0x80) != 0 {
    0x0f
  } else {
    0x1f
  }
}

///|
/// Apply header protection in place-by-copy: XOR the first byte's form-appropriate low
/// bits and the `pn_length` packet-number bytes at `pn_offset` with the mask. The
/// 16-byte sample is taken at `pn_offset + 4` (RFC 9001 §5.4.2), the fixed position
/// that assumes the largest packet-number field.
pub fn quic_header_protect(
  packet : Bytes,
  pn_offset : Int,
  pn_length : Int,
  hp_key : Bytes,
) -> Bytes {
  let sample = packet[pn_offset + 4:pn_offset + 20].to_owned()
  let mask = quic_hp_mask(hp_key, sample)
  let out = Array::make(packet.length(), 0)
  for i = 0; i < packet.length(); i = i + 1 {
    out[i] = packet[i].to_int()
  }
  out[0] = out[0] ^ (mask[0].to_int() & hp_first_byte_mask(out[0]))
  for i = 0; i < pn_length; i = i + 1 {
    out[pn_offset + i] = out[pn_offset + i] ^ mask[1 + i].to_int()
  }
  let buf = Buffer()
  for i = 0; i < out.length(); i = i + 1 {
    buf.write_byte(out[i].to_byte())
  }
  buf.to_bytes()
}

///|
/// Remove header protection: recover the first byte, read the packet-number length
/// from its low two bits, unmask that many packet-number bytes, and return the
/// unprotected packet together with the recovered length (RFC 9001 §5.4.1).
pub fn quic_header_unprotect(
  packet : Bytes,
  pn_offset : Int,
  hp_key : Bytes,
) -> (Bytes, Int) {
  let sample = packet[pn_offset + 4:pn_offset + 20].to_owned()
  let mask = quic_hp_mask(hp_key, sample)
  let first = packet[0].to_int() ^
    (mask[0].to_int() & hp_first_byte_mask(packet[0].to_int()))
  let pn_length = (first & 0x03) + 1
  let out = Array::make(packet.length(), 0)
  for i = 0; i < packet.length(); i = i + 1 {
    out[i] = packet[i].to_int()
  }
  out[0] = first
  for i = 0; i < pn_length; i = i + 1 {
    out[pn_offset + i] = out[pn_offset + i] ^ mask[1 + i].to_int()
  }
  let buf = Buffer()
  for i = 0; i < out.length(); i = i + 1 {
    buf.write_byte(out[i].to_byte())
  }
  (buf.to_bytes(), pn_length)
}
