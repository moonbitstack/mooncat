// The TLS 1.3 record layer (RFC 8446 §5): the envelope every other TLS message travels in.
// Without it the handshake this package builds can only be handed to QUIC as CRYPTO frames,
// because QUIC carries the messages itself and needs no record layer; over TCP there is
// nothing else to say where one message ends and the next begins. A record is a content
// type, a frozen legacy version, a length, and a fragment — until the keys arrive, after
// which the real type moves inside the encrypted body and the outer one lies and says
// application_data. This file is that framing, the AEAD that protects it, and the §5.3
// nonce that keeps every record under one key distinct.

///|
/// The change_cipher_spec content type (RFC 8446 §5). TLS 1.3 has no such message: the
/// record survives only so middleboxes watching for a TLS 1.2 handshake see one.
pub let tls_record_change_cipher_spec : Int = 20

///|
/// The alert content type (RFC 8446 §5).
pub let tls_record_alert : Int = 21

///|
/// The handshake content type (RFC 8446 §5).
pub let tls_record_handshake : Int = 22

///|
/// The application_data content type (RFC 8446 §5). Every TLSCiphertext carries it as the
/// outer `opaque_type` too, whatever the real type sealed inside turns out to be.
pub let tls_record_application_data : Int = 23

///|
/// The largest TLSPlaintext fragment (RFC 8446 §5.1): 2^14 octets.
pub let tls_record_max_fragment : Int = 16384

///|
/// The largest TLSCiphertext encrypted_record (RFC 8446 §5.2): 2^14 + 256 — the fragment
/// limit plus the room the inner content type, the padding and the AEAD tag need.
pub let tls_record_max_encrypted : Int = 16640

///|
/// The record header: content type, legacy_record_version, and a 16-bit length.
pub let tls_record_header_len : Int = 5

///|
/// One record's content type and fragment (RFC 8446 §5.1). For a TLSCiphertext the
/// `content_type` is the outer application_data and the `fragment` is still sealed.
pub(all) struct TlsRecord {
  content_type : Int
  fragment : Bytes
} derive(Eq, Debug)

///|
/// Whether `t` is a content type RFC 8446 §5 defines. Anything else on the wire is an
/// unexpected_message, not something to skip past.
fn tls_record_type_known(t : Int) -> Bool {
  t == tls_record_change_cipher_spec ||
  t == tls_record_alert ||
  t == tls_record_handshake ||
  t == tls_record_application_data
}

///|
/// Frame `fragment` as a TLSPlaintext record (RFC 8446 §5.1). legacy_record_version is
/// 0x0303 whatever the negotiated version is; a receiver ignores it.
pub fn tls_record_encode(
  content_type : Int,
  fragment : Bytes,
) -> Bytes raise TlsAlert {
  if fragment.length() > tls_record_max_fragment {
    raise tls_fatal(tls_alert_record_overflow)
  }
  let buf = Buffer()
  buf.write_byte((content_type & 0xff).to_byte())
  ks_write_u16(buf, tls_legacy_version)
  ks_write_u16(buf, fragment.length())
  buf.write_bytes(fragment[:])
  buf.to_bytes()
}

///|
/// Parse one record off the front of `view`, capping the fragment at `max`. `None` means
/// the view does not hold a whole record yet — the length is checked first, so an oversized
/// record fails immediately rather than waiting forever for bytes that may never come.
fn tls_record_read(
  view : BytesView,
  max : Int,
) -> (TlsRecord, Int)? raise TlsAlert {
  if view.length() < tls_record_header_len {
    return None
  }
  let content_type = view[0].to_int()
  if !tls_record_type_known(content_type) {
    raise tls_fatal(tls_alert_unexpected_message)
  }
  let len = ks_read_u16(view, 3)
  if len > max {
    raise tls_fatal(tls_alert_record_overflow)
  }
  // §5.1: only application_data may be sent zero-length, as a traffic-analysis
  // countermeasure. An empty handshake or alert record is a framing error.
  if len == 0 && content_type != tls_record_application_data {
    raise tls_fatal(tls_alert_unexpected_message)
  }
  let end = tls_record_header_len + len
  if view.length() < end {
    return None
  }
  Some(
    (
      { content_type, fragment: view[tls_record_header_len:end].to_owned(), },
      end,
    ),
  )
}

///|
/// Parse one TLSPlaintext record (RFC 8446 §5.1) and the number of bytes it consumed, or
/// `None` while the view is short of a whole record.
pub fn tls_record_parse(view : BytesView) -> (TlsRecord, Int)? raise TlsAlert {
  tls_record_read(view, tls_record_max_fragment)
}

///|
/// Parse one TLSCiphertext record (RFC 8446 §5.2) and the number of bytes it consumed. The
/// fragment is the still-sealed encrypted_record, so the ceiling is the larger §5.2 one.
pub fn tls_record_parse_encrypted(
  view : BytesView,
) -> (TlsRecord, Int)? raise TlsAlert {
  tls_record_read(view, tls_record_max_encrypted)
}

///|
/// A TLSInnerPlaintext (RFC 8446 §5.2): the content, then the content type the outer header
/// is hiding, then `padding` zero octets. The padding is the §5.4 length-hiding knob.
pub fn tls_record_inner(
  content_type : Int,
  content : Bytes,
  padding : Int,
) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(content[:])
  buf.write_byte((content_type & 0xff).to_byte())
  for _i = 0; _i < padding; _i = _i + 1 {
    buf.write_byte(b'\x00')
  }
  buf.to_bytes()
}

///|
/// Split a TLSInnerPlaintext back into its content type and content (RFC 8446 §5.2): scan
/// back over the zero padding to the last non-zero octet, which is the type. An inner
/// plaintext of nothing but zeros names no type at all, which §5.2 makes an
/// unexpected_message rather than an empty record.
pub fn tls_record_unpad(inner : BytesView) -> (Int, Bytes) raise TlsAlert {
  let mut i = inner.length() - 1
  while i >= 0 && inner[i] == b'\x00' {
    i = i - 1
  }
  if i < 0 {
    raise tls_fatal(tls_alert_unexpected_message)
  }
  (inner[i].to_int(), inner[0:i].to_owned())
}

///|
/// The AEAD key and IV one direction protects its records with (RFC 8446 §7.3), at the
/// TLS_AES_128_GCM_SHA256 lengths.
pub(all) struct TlsTrafficKeys {
  key : Bytes
  iv : Bytes
} derive(Eq, Debug)

///|
/// Derive a direction's record-protection key and IV from its traffic secret (RFC 8446
/// §7.3). QUIC expands the same secret under "quic key"/"quic iv" and adds a
/// header-protection key (RFC 9001 §5.1); over TCP the labels are bare and there is no
/// header to protect.
pub fn tls13_traffic_keys(secret : Bytes) -> TlsTrafficKeys {
  {
    key: hkdf_expand_label(secret, b"key", b"", 16),
    iv: hkdf_expand_label(secret, b"iv", b"", 12),
  }
}

///|
/// The per-record AEAD nonce (RFC 8446 §5.3): the 64-bit sequence number, big-endian and
/// left-padded with zeros to the IV's length, XORed with the static write IV. The IV never
/// changes, so the sequence number alone is what keeps two records under one key from ever
/// sharing a nonce.
pub fn tls_record_nonce(iv : Bytes, seq : UInt64) -> Bytes {
  let buf = Buffer()
  for i = 0; i < iv.length(); i = i + 1 {
    let from_end = iv.length() - 1 - i
    let s = if from_end < 8 {
      (seq >> (from_end * 8)).to_byte().to_int()
    } else {
      0
    }
    buf.write_byte((iv[i].to_int() ^ s).to_byte())
  }
  buf.to_bytes()
}

///|
/// One direction's record protection: its traffic keys, and the sequence number that keeps
/// their nonces apart. RFC 8446 §5.3 restarts the sequence at zero on every key change,
/// which is what `rekey` is for — the IV is reused across a generation, so a sequence that
/// carried over would reuse a nonce under the new key.
pub struct TlsRecordKeys {
  mut keys : TlsTrafficKeys
  mut seq : UInt64
}

///|
/// Record protection under the traffic `secret`, starting at sequence zero.
pub fn TlsRecordKeys::new(secret : Bytes) -> TlsRecordKeys {
  { keys: tls13_traffic_keys(secret), seq: 0UL, }
}

///|
/// Install a new traffic secret and restart the sequence number at zero (RFC 8446 §5.3).
pub fn TlsRecordKeys::rekey(self : TlsRecordKeys, secret : Bytes) -> Unit {
  self.keys = tls13_traffic_keys(secret)
  self.seq = 0UL
}

///|
/// The traffic keys in force.
pub fn TlsRecordKeys::keys(self : TlsRecordKeys) -> TlsTrafficKeys {
  self.keys
}

///|
/// The sequence number the next record will use.
pub fn TlsRecordKeys::seq(self : TlsRecordKeys) -> UInt64 {
  self.seq
}

///|
/// The nonce the next record will be sealed or opened under (RFC 8446 §5.3).
pub fn TlsRecordKeys::nonce(self : TlsRecordKeys) -> Bytes {
  tls_record_nonce(self.keys.iv, self.seq)
}

///|
/// The five header octets of a TLSCiphertext whose encrypted_record is `len` long. They are
/// also the AEAD's additional data (RFC 8446 §5.2), which is why the length has to be
/// settled before the seal rather than measured after it.
fn tls_record_ciphertext_header(len : Int) -> Bytes {
  let buf = Buffer()
  buf.write_byte((tls_record_application_data & 0xff).to_byte())
  ks_write_u16(buf, tls_legacy_version)
  ks_write_u16(buf, len)
  buf.to_bytes()
}

///|
/// Seal `content` as a TLSCiphertext record (RFC 8446 §5.2) with `padding` zero octets
/// after the inner content type, and advance the sequence number.
pub fn TlsRecordKeys::seal_padded(
  self : TlsRecordKeys,
  content_type : Int,
  content : Bytes,
  padding : Int,
) -> Bytes raise TlsAlert {
  if content.length() > tls_record_max_fragment {
    raise tls_fatal(tls_alert_record_overflow)
  }
  let inner = tls_record_inner(content_type, content, padding)
  let len = inner.length() + 16
  if len > tls_record_max_encrypted {
    raise tls_fatal(tls_alert_record_overflow)
  }
  let aad = tls_record_ciphertext_header(len)
  let body = gcm_seal(self.keys.key, self.nonce(), inner, aad)
  self.seq = self.seq + 1UL
  bytes_concat(aad, body)
}

///|
/// Seal `content` as a TLSCiphertext record with no padding.
pub fn TlsRecordKeys::seal(
  self : TlsRecordKeys,
  content_type : Int,
  content : Bytes,
) -> Bytes raise TlsAlert {
  self.seal_padded(content_type, content, 0)
}

///|
/// Open one whole TLSCiphertext record — header included, since RFC 8446 §5.2 makes that
/// header the AEAD's additional data — into the content type and content sealed inside,
/// advancing the sequence number. A tag that does not verify is a bad_record_mac and the
/// sequence does not move, because §5.2 ends the connection there.
pub fn TlsRecordKeys::open(
  self : TlsRecordKeys,
  record : BytesView,
) -> (Int, Bytes) raise TlsAlert {
  guard tls_record_read(record, tls_record_max_encrypted) is Some((rec, _)) else {
    raise tls_fatal(tls_alert_decode_error)
  }
  let aad = record[0:tls_record_header_len].to_owned()
  guard gcm_open(self.keys.key, self.nonce(), rec.fragment, aad) is Some(inner) else {
    raise tls_fatal(tls_alert_bad_record_mac)
  }
  self.seq = self.seq + 1UL
  let (content_type, content) = tls_record_unpad(inner[:])
  if content.length() > tls_record_max_fragment {
    raise tls_fatal(tls_alert_record_overflow)
  }
  (content_type, content)
}

///|
pub extend TlsRecord with Debug::{to_repr}

///|
pub extend TlsRecord with Eq::{not_equal, equal}

///|
pub extend TlsTrafficKeys with Debug::{to_repr}

///|
pub extend TlsTrafficKeys with Eq::{not_equal, equal}
