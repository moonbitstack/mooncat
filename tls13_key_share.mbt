// The TLS 1.3 key_share extension (RFC 8446 §4.2.8): the ephemeral (EC)DHE public keys the
// two peers exchange so each can compute the shared secret the key schedule extracts into the
// Handshake Secret. A ClientHello carries a list of KeyShareEntry (a named group plus the
// public key); a ServerHello carries the single entry for the group the server picked. For
// TLS 1.3 over QUIC the group is x25519 (0x001d) and the key is a 32-byte Montgomery-u
// coordinate. This is the wire format that turns the crypto primitives (`x25519`, the key
// schedule) into a real key agreement between two endpoints — the piece a handshake needs
// before it can derive handshake-space keys.

///|
/// The x25519 named group (RFC 8446 §4.2.7).
pub let tls_group_x25519 : Int = 0x001d

///|
/// The key_share extension type (RFC 8446 §4.2.8).
pub let tls_ext_key_share : Int = 0x0033

///|
/// The `(group, key)` of a ServerHello's key_share extension, or `None` if it has none.
pub fn tls_server_hello_key_share(sh : TlsServerHello) -> (Int, Bytes)? {
  match tls_find_extension(sh.extensions, tls_ext_key_share) {
    Some(ext) => tls_decode_key_share_server(ext.data[:])
    None => None
  }
}

///|
/// The list of `(group, key)` shares a ClientHello's key_share extension offers.
pub fn tls_client_hello_key_shares(
  extensions : Array[TlsExtension],
) -> Array[(Int, Bytes)] {
  match tls_find_extension(extensions, tls_ext_key_share) {
    Some(ext) => tls_decode_key_share_client(ext.data[:])
    None => []
  }
}

///|
/// Build a ServerHello key_share extension carrying `key` for `group`.
pub fn tls_key_share_extension(group : Int, key : Bytes) -> TlsExtension {
  {
    ext_type: tls_ext_key_share,
    data: tls_encode_key_share_server(group, key),
  }
}

///|
fn ks_write_u16(buf : Buffer, v : Int) -> Unit {
  buf.write_byte(((v >> 8) & 0xff).to_byte())
  buf.write_byte((v & 0xff).to_byte())
}

///|
fn ks_read_u16(view : BytesView, off : Int) -> Int {
  (view[off].to_int() << 8) | view[off + 1].to_int()
}

///|
/// The ephemeral x25519 public key for a private scalar: `x25519(private, base_point)`.
pub fn tls13_x25519_public(private_key : Bytes) -> Bytes {
  x25519_raw(private_key, @x25519.base)
}

///|
/// Encode one KeyShareEntry: the named group, the key length, then the key (RFC 8446 §4.2.8).
pub fn tls_encode_key_share_entry(group : Int, key : Bytes) -> Bytes {
  let buf = Buffer()
  ks_write_u16(buf, group)
  ks_write_u16(buf, key.length())
  buf.write_bytes(key)
  buf.to_bytes()
}

///|
/// Encode the ServerHello key_share extension body: a single KeyShareEntry.
pub fn tls_encode_key_share_server(group : Int, key : Bytes) -> Bytes {
  tls_encode_key_share_entry(group, key)
}

///|
/// Encode the ClientHello key_share extension body: the client_shares length, then the
/// KeyShareEntry list.
pub fn tls_encode_key_share_client(entries : Array[(Int, Bytes)]) -> Bytes {
  let inner = Buffer()
  for e in entries {
    inner.write_bytes(tls_encode_key_share_entry(e.0, e.1))
  }
  let body = inner.to_bytes()
  let buf = Buffer()
  ks_write_u16(buf, body.length())
  buf.write_bytes(body)
  buf.to_bytes()
}

///|
/// Decode one KeyShareEntry from the front of `view`: returns `(group, key, bytes-consumed)`,
/// or `None` on a partial read.
pub fn tls_decode_key_share_entry(view : BytesView) -> (Int, Bytes, Int)? {
  if view.length() < 4 {
    return None
  }
  let group = ks_read_u16(view, 0)
  let len = ks_read_u16(view, 2)
  if view.length() < 4 + len {
    return None
  }
  Some((group, view[4:4 + len].to_owned(), 4 + len))
}

///|
/// Decode a ServerHello key_share extension body: its single KeyShareEntry as `(group, key)`.
pub fn tls_decode_key_share_server(view : BytesView) -> (Int, Bytes)? {
  match tls_decode_key_share_entry(view) {
    Some((group, key, _)) => Some((group, key))
    None => None
  }
}

///|
/// Decode a ClientHello key_share extension body: the list of `(group, key)` shares.
pub fn tls_decode_key_share_client(view : BytesView) -> Array[(Int, Bytes)] {
  let shares : Array[(Int, Bytes)] = []
  if view.length() < 2 {
    return shares
  }
  let total = ks_read_u16(view, 0)
  let end = 2 + total
  let mut off = 2
  while off < end && off < view.length() {
    match tls_decode_key_share_entry(view[off:]) {
      Some((group, key, consumed)) => {
        shares.push((group, key))
        off = off + consumed
      }
      None => break
    }
  }
  shares
}
