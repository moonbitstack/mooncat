// TLS 1.3 handshake messages (RFC 8446 §4). These are the messages the QUIC CRYPTO
// frames carry: the ClientHello and ServerHello negotiate the cipher suite and the
// key_share that x25519 turns into the ECDHE secret, which the key schedule extracts.
// Each message is framed as a one-byte type, a 24-bit length, then its body.

///|
/// A TLS extension: a two-byte type and its opaque data (RFC 8446 §4.2).
pub(all) struct TlsExtension {
  ext_type : Int
  data : Bytes
} derive(Eq, Debug)

///|
/// The handshake message types this layer models (RFC 8446 §4).
pub let tls_client_hello : Int = 1

///|
/// ServerHello (RFC 8446 §4.1.3): the server's half of the key exchange.
pub let tls_server_hello : Int = 2

///|
/// Frame a handshake body: message type, then a 24-bit big-endian length (RFC 8446 §4).
pub fn tls_encode_handshake(msg_type : Int, body : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_byte(msg_type.to_byte())
  buf.write_byte(((body.length() >> 16) & 0xff).to_byte())
  buf.write_byte(((body.length() >> 8) & 0xff).to_byte())
  buf.write_byte((body.length() & 0xff).to_byte())
  buf.write_bytes(body[:])
  buf.to_bytes()
}

///|
/// Parse one handshake message, returning its type and body, or `None` if truncated.
pub fn tls_parse_handshake(b : BytesView) -> (Int, Bytes)? {
  if b.length() < 4 {
    return None
  }
  let msg_type = b[0].to_int()
  let len = (b[1].to_int() << 16) | (b[2].to_int() << 8) | b[3].to_int()
  if b.length() < 4 + len {
    return None
  }
  Some((msg_type, b[4:4 + len].to_owned()))
}

///|
/// Encode an extension block: a two-byte total length, then each extension as a
/// two-byte type, a two-byte length, and its data.
fn tls_encode_extensions(exts : Array[TlsExtension]) -> Bytes {
  let inner = Buffer()
  for e in exts {
    inner.write_byte(((e.ext_type >> 8) & 0xff).to_byte())
    inner.write_byte((e.ext_type & 0xff).to_byte())
    inner.write_byte(((e.data.length() >> 8) & 0xff).to_byte())
    inner.write_byte((e.data.length() & 0xff).to_byte())
    inner.write_bytes(e.data[:])
  }
  let ib = inner.to_bytes()
  let out = Buffer()
  out.write_byte(((ib.length() >> 8) & 0xff).to_byte())
  out.write_byte((ib.length() & 0xff).to_byte())
  out.write_bytes(ib[:])
  out.to_bytes()
}

///|
/// Decode an extension block (a two-byte length prefix then the extensions).
fn tls_decode_extensions(b : BytesView) -> Array[TlsExtension]? {
  if b.length() < 2 {
    return None
  }
  let total = (b[0].to_int() << 8) | b[1].to_int()
  let end = 2 + total
  if b.length() < end {
    return None
  }
  let out : Array[TlsExtension] = []
  let mut off = 2
  while off < end {
    if off + 4 > end {
      return None
    }
    let et = (b[off].to_int() << 8) | b[off + 1].to_int()
    let dl = (b[off + 2].to_int() << 8) | b[off + 3].to_int()
    off = off + 4
    if off + dl > end {
      return None
    }
    out.push({ ext_type: et, data: b[off:off + dl].to_owned(), })
    off = off + dl
  }
  Some(out)
}

///|
/// Look up the first extension of a given type, or `None`.
pub fn tls_find_extension(
  exts : Array[TlsExtension],
  ext_type : Int,
) -> TlsExtension? {
  exts.iter().find_first(fn(e) { e.ext_type == ext_type })
}

///|
/// A ClientHello (RFC 8446 §4.1.2), less the fixed legacy fields.
pub(all) struct TlsClientHello {
  random : Bytes
  session_id : Bytes
  cipher_suites : Array[Int]
  extensions : Array[TlsExtension]
} derive(Eq, Debug)

///|
/// Encode a ClientHello as a full handshake message. legacy_version is 0x0303 and
/// legacy_compression_methods is the single null method, per RFC 8446 §4.1.2.
pub fn encode_client_hello(ch : TlsClientHello) -> Bytes {
  let body = Buffer()
  body.write_byte(b'\x03')
  body.write_byte(b'\x03')
  body.write_bytes(ch.random[:])
  body.write_byte(ch.session_id.length().to_byte())
  body.write_bytes(ch.session_id[:])
  let cs_bytes = ch.cipher_suites.length() * 2
  body.write_byte(((cs_bytes >> 8) & 0xff).to_byte())
  body.write_byte((cs_bytes & 0xff).to_byte())
  for cs in ch.cipher_suites {
    body.write_byte(((cs >> 8) & 0xff).to_byte())
    body.write_byte((cs & 0xff).to_byte())
  }
  body.write_byte(b'\x01')
  body.write_byte(b'\x00')
  body.write_bytes(tls_encode_extensions(ch.extensions)[:])
  tls_encode_handshake(tls_client_hello, body.to_bytes())
}

///|
/// Decode a ClientHello from a handshake body (RFC 8446 §4.1.2).
pub fn decode_client_hello(body : BytesView) -> TlsClientHello? {
  if body.length() < 35 {
    return None
  }
  let random = body[2:34].to_owned()
  let sid_len = body[34].to_int()
  let mut off = 35
  if body.length() < off + sid_len {
    return None
  }
  let session_id = body[off:off + sid_len].to_owned()
  off = off + sid_len
  if body.length() < off + 2 {
    return None
  }
  let cs_len = (body[off].to_int() << 8) | body[off + 1].to_int()
  off = off + 2
  if body.length() < off + cs_len {
    return None
  }
  let cipher_suites : Array[Int] = []
  for i = 0; i < cs_len; i = i + 2 {
    cipher_suites.push(
      (body[off + i].to_int() << 8) | body[off + i + 1].to_int(),
    )
  }
  off = off + cs_len
  if body.length() < off + 1 {
    return None
  }
  let comp_len = body[off].to_int()
  off = off + 1 + comp_len
  guard tls_decode_extensions(body[off:]) is Some(extensions) else {
    return None
  }
  Some({ random, session_id, cipher_suites, extensions, })
}

///|
/// A ServerHello (RFC 8446 §4.1.3): a single chosen cipher suite, no compression.
pub(all) struct TlsServerHello {
  random : Bytes
  session_id : Bytes
  cipher_suite : Int
  extensions : Array[TlsExtension]
} derive(Eq, Debug)

///|
/// Encode a ServerHello as a full handshake message.
pub fn encode_server_hello(sh : TlsServerHello) -> Bytes {
  let body = Buffer()
  body.write_byte(b'\x03')
  body.write_byte(b'\x03')
  body.write_bytes(sh.random[:])
  body.write_byte(sh.session_id.length().to_byte())
  body.write_bytes(sh.session_id[:])
  body.write_byte(((sh.cipher_suite >> 8) & 0xff).to_byte())
  body.write_byte((sh.cipher_suite & 0xff).to_byte())
  body.write_byte(b'\x00')
  body.write_bytes(tls_encode_extensions(sh.extensions)[:])
  tls_encode_handshake(tls_server_hello, body.to_bytes())
}

///|
/// Decode a ServerHello from a handshake body (RFC 8446 §4.1.3).
pub fn decode_server_hello(body : BytesView) -> TlsServerHello? {
  if body.length() < 35 {
    return None
  }
  let random = body[2:34].to_owned()
  let sid_len = body[34].to_int()
  let mut off = 35
  if body.length() < off + sid_len {
    return None
  }
  let session_id = body[off:off + sid_len].to_owned()
  off = off + sid_len
  if body.length() < off + 3 {
    return None
  }
  let cipher_suite = (body[off].to_int() << 8) | body[off + 1].to_int()
  // Skip the cipher suite (2) and the single legacy compression byte (1).
  off = off + 3
  guard tls_decode_extensions(body[off:]) is Some(extensions) else {
    return None
  }
  Some({ random, session_id, cipher_suite, extensions, })
}

///|
pub extend TlsClientHello with Debug::{to_repr}

///|
pub extend TlsClientHello with Eq::{not_equal, equal}

///|
pub extend TlsExtension with Debug::{to_repr}

///|
pub extend TlsExtension with Eq::{not_equal, equal}

///|
pub extend TlsServerHello with Debug::{to_repr}

///|
pub extend TlsServerHello with Eq::{not_equal, equal}
