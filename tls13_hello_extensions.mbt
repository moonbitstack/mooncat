// The three extensions RFC 8446 §9.2 makes mandatory alongside key_share, and the negotiation
// they drive. supported_versions (§4.2.1) is what actually says "TLS 1.3": the ServerHello's
// legacy_version field is frozen at 0x0303 for middleboxes, and a client that does not find
// 0x0304 in this extension reads the message as TLS 1.2 and gives up. supported_groups (§4.2.7)
// and signature_algorithms (§4.2.3) say which key exchange and which certificate signature the
// client will accept, so a server that assumes x25519 and ES256 rather than reading them will
// sooner or later pick something the client cannot use. `tls13_negotiate` reads all four
// extensions off a ClientHello and either settles the handshake's parameters, asks for a
// HelloRetryRequest, or raises the alert §6 names for that failure.

///|
/// The supported_groups extension type (RFC 8446 §4.2.7).
pub let tls_ext_supported_groups : Int = 0x000a

///|
/// The signature_algorithms extension type (RFC 8446 §4.2.3).
pub let tls_ext_signature_algorithms : Int = 0x000d

///|
/// The supported_versions extension type (RFC 8446 §4.2.1).
pub let tls_ext_supported_versions : Int = 0x002b

///|
/// The version TLS 1.3 leaves in the legacy_version field of a ClientHello and ServerHello
/// (RFC 8446 §4.1.2, §4.1.3): TLS 1.2's number, kept so middleboxes pass the record through.
pub let tls_legacy_version : Int = 0x0303

///|
/// TLS 1.3's version number (RFC 8446 §4.2.1), which travels in supported_versions rather than
/// in legacy_version.
pub let tls_version_13 : Int = 0x0304

///|
/// The secp256r1 named group (RFC 8446 §4.2.7).
pub let tls_group_secp256r1 : Int = 0x0017

///|
/// The secp384r1 named group (RFC 8446 §4.2.7).
pub let tls_group_secp384r1 : Int = 0x0018

///|
/// The rsa_pss_rsae_sha256 SignatureScheme (RFC 8446 §4.2.3).
pub let tls_sig_rsa_pss_rsae_sha256 : Int = 0x0804

///|
/// Encode a two-byte-length-prefixed list of 16-bit codes — the body shape supported_groups
/// and signature_algorithms share.
fn tls_encode_u16_list(values : Array[Int]) -> Bytes {
  let inner = Buffer()
  for v in values {
    ks_write_u16(inner, v)
  }
  let body = inner.to_bytes()
  let buf = Buffer()
  ks_write_u16(buf, body.length())
  buf.write_bytes(body[:])
  buf.to_bytes()
}

///|
/// Decode a two-byte-length-prefixed list of 16-bit codes, stopping at the declared length or
/// a truncated entry.
fn tls_decode_u16_list(view : BytesView) -> Array[Int] {
  let values : Array[Int] = []
  if view.length() < 2 {
    return values
  }
  let declared = 2 + ks_read_u16(view, 0)
  let end = if declared < view.length() { declared } else { view.length() }
  let mut off = 2
  while off + 2 <= end {
    values.push(ks_read_u16(view, off))
    off = off + 2
  }
  values
}

///|
/// Encode a ClientHello's supported_versions body (RFC 8446 §4.2.1): a one-byte length, then
/// each version as two bytes, most preferred first.
pub fn tls_encode_supported_versions_client(versions : Array[Int]) -> Bytes {
  let inner = Buffer()
  for v in versions {
    ks_write_u16(inner, v)
  }
  let body = inner.to_bytes()
  let buf = Buffer()
  buf.write_byte((body.length() & 0xff).to_byte())
  buf.write_bytes(body[:])
  buf.to_bytes()
}

///|
/// Decode a ClientHello's supported_versions body into the versions it offers, in order.
pub fn tls_decode_supported_versions_client(view : BytesView) -> Array[Int] {
  let versions : Array[Int] = []
  if view.length() < 1 {
    return versions
  }
  let declared = 1 + view[0].to_int()
  let end = if declared < view.length() { declared } else { view.length() }
  let mut off = 1
  while off + 2 <= end {
    versions.push(ks_read_u16(view, off))
    off = off + 2
  }
  versions
}

///|
/// Encode a ServerHello's supported_versions body (RFC 8446 §4.2.1): the selected version
/// alone, with no list prefix.
pub fn tls_encode_supported_versions_server(version : Int) -> Bytes {
  let buf = Buffer()
  ks_write_u16(buf, version)
  buf.to_bytes()
}

///|
/// The version a ServerHello's supported_versions body selected, or `None` if it is not two
/// bytes.
pub fn tls_decode_supported_versions_server(view : BytesView) -> Int? {
  if view.length() != 2 {
    return None
  }
  Some(ks_read_u16(view, 0))
}

///|
/// A ClientHello supported_versions extension offering `versions`.
pub fn tls_supported_versions_extension(versions : Array[Int]) -> TlsExtension {
  {
    ext_type: tls_ext_supported_versions,
    data: tls_encode_supported_versions_client(versions),
  }
}

///|
/// A ServerHello or HelloRetryRequest supported_versions extension naming `version`.
pub fn tls_selected_version_extension(version : Int) -> TlsExtension {
  {
    ext_type: tls_ext_supported_versions,
    data: tls_encode_supported_versions_server(version),
  }
}

///|
/// The versions a ClientHello's supported_versions extension offers (empty if it has none).
pub fn tls_client_hello_versions(
  extensions : Array[TlsExtension],
) -> Array[Int] {
  match tls_find_extension(extensions, tls_ext_supported_versions) {
    Some(ext) => tls_decode_supported_versions_client(ext.data[:])
    None => []
  }
}

///|
/// The version a ServerHello selected (RFC 8446 §4.2.1) — the field a client must read
/// instead of legacy_version — or `None` if it carries no supported_versions.
pub fn tls_server_hello_version(sh : TlsServerHello) -> Int? {
  match tls_find_extension(sh.extensions, tls_ext_supported_versions) {
    Some(ext) => tls_decode_supported_versions_server(ext.data[:])
    None => None
  }
}

///|
/// Encode a supported_groups body (RFC 8446 §4.2.7): a two-byte list length, then each named
/// group as two bytes, most preferred first.
pub fn tls_encode_supported_groups(groups : Array[Int]) -> Bytes {
  tls_encode_u16_list(groups)
}

///|
/// Decode a supported_groups body into the named groups it offers, in order.
pub fn tls_decode_supported_groups(view : BytesView) -> Array[Int] {
  tls_decode_u16_list(view)
}

///|
/// A supported_groups extension offering `groups`.
pub fn tls_supported_groups_extension(groups : Array[Int]) -> TlsExtension {
  {
    ext_type: tls_ext_supported_groups,
    data: tls_encode_supported_groups(groups),
  }
}

///|
/// The named groups a ClientHello offers for key exchange (empty if it has no
/// supported_groups).
pub fn tls_client_hello_groups(extensions : Array[TlsExtension]) -> Array[Int] {
  match tls_find_extension(extensions, tls_ext_supported_groups) {
    Some(ext) => tls_decode_supported_groups(ext.data[:])
    None => []
  }
}

///|
/// Encode a signature_algorithms body (RFC 8446 §4.2.3): a two-byte list length, then each
/// SignatureScheme as two bytes, most preferred first.
pub fn tls_encode_signature_algorithms(schemes : Array[Int]) -> Bytes {
  tls_encode_u16_list(schemes)
}

///|
/// Decode a signature_algorithms body into the schemes it offers, in order.
pub fn tls_decode_signature_algorithms(view : BytesView) -> Array[Int] {
  tls_decode_u16_list(view)
}

///|
/// A signature_algorithms extension offering `schemes`.
pub fn tls_signature_algorithms_extension(schemes : Array[Int]) -> TlsExtension {
  {
    ext_type: tls_ext_signature_algorithms,
    data: tls_encode_signature_algorithms(schemes),
  }
}

///|
/// The signature schemes a ClientHello will accept on a certificate (empty if it has no
/// signature_algorithms).
pub fn tls_client_hello_signature_algorithms(
  extensions : Array[TlsExtension],
) -> Array[Int] {
  match tls_find_extension(extensions, tls_ext_signature_algorithms) {
    Some(ext) => tls_decode_signature_algorithms(ext.data[:])
    None => []
  }
}

///|
/// A ServerHello carrying the supported_versions RFC 8446 §9.2 requires, ahead of
/// `extensions`. The message's legacy_version stays 0x0303 — `encode_server_hello` writes it —
/// because §4.1.3 puts the negotiated version here instead.
pub fn tls13_server_hello(
  random : Bytes,
  session_id : Bytes,
  cipher_suite : Int,
  extensions : Array[TlsExtension],
) -> TlsServerHello {
  {
    random,
    session_id,
    cipher_suite,
    extensions: [tls_selected_version_extension(tls_version_13), ..extensions],
  }
}

///|
/// The named groups this build can run a key exchange for. `x25519.mbt` is the only group
/// implemented, so offering more would be a lie the handshake could not honour.
pub fn tls13_groups() -> Array[Int] {
  [tls_group_x25519]
}

///|
/// The signature schemes this build can sign a CertificateVerify with. `ecdsa.mbt` implements
/// P-256 with SHA-256 and nothing else.
pub fn tls13_signature_schemes() -> Array[Int] {
  [tls_sig_ecdsa_secp256r1_sha256]
}

///|
/// The x25519 public key length (RFC 7748 §5): a Montgomery-u coordinate.
let x25519_key_length : Int = 32

///|
/// What a server settled on after reading a ClientHello.
pub(all) enum TlsNegotiation {
  /// The client offered a group this build runs and a key share for it: the group, the
  /// client's public key, and the scheme the CertificateVerify will sign under.
  Negotiated(group~ : Int, client_key~ : Bytes, scheme~ : Int)
  /// The client offered a group this build runs but no key share for it, so it has to send
  /// the ClientHello again with one (RFC 8446 §4.1.4).
  Retry(Int)
} derive(Eq, Debug)

///|
/// The first of `offered` that also appears in `ours`, honouring the client's preference order
/// as RFC 8446 §4.2.7 allows a server to.
fn tls_first_common(offered : Array[Int], ours : Array[Int]) -> Int? {
  offered.iter().find_first(fn(v) { ours.contains(v) })
}

///|
/// Negotiate a decoded ClientHello (RFC 8446 §4.1.1): check it offers TLS 1.3, pick the first
/// group and signature scheme it lists that this build runs, and take its key share for the
/// chosen group. Raises the alert §6 names for each way that fails — a missing mandatory
/// extension, a client that does not speak 1.3, nothing in common, or a key share that
/// contradicts the rest of the message — and returns `Retry` when the chosen group is one the
/// client offered but sent no share for.
pub fn tls13_negotiate(ch : TlsClientHello) -> TlsNegotiation raise TlsAlert {
  // RFC 8446 §9.2: a ClientHello missing any of these cannot be a 1.3 handshake at all.
  guard tls_find_extension(ch.extensions, tls_ext_supported_versions) is Some(_) else {
    raise tls_fatal(tls_alert_missing_extension)
  }
  guard tls_find_extension(ch.extensions, tls_ext_supported_groups) is Some(_) else {
    raise tls_fatal(tls_alert_missing_extension)
  }
  guard tls_find_extension(ch.extensions, tls_ext_signature_algorithms)
    is Some(_) else {
    raise tls_fatal(tls_alert_missing_extension)
  }
  guard tls_find_extension(ch.extensions, tls_ext_key_share) is Some(_) else {
    raise tls_fatal(tls_alert_missing_extension)
  }
  if !tls_client_hello_versions(ch.extensions).contains(tls_version_13) {
    raise tls_fatal(tls_alert_protocol_version)
  }
  let offered_groups = tls_client_hello_groups(ch.extensions)
  guard tls_first_common(offered_groups, tls13_groups()) is Some(group) else {
    raise tls_fatal(tls_alert_handshake_failure)
  }
  guard tls_first_common(
      tls_client_hello_signature_algorithms(ch.extensions),
      tls13_signature_schemes(),
    )
    is Some(scheme) else {
    raise tls_fatal(tls_alert_handshake_failure)
  }
  let shares = tls_client_hello_key_shares(ch.extensions)
  // §4.2.8: a share for a group the client did not list in supported_groups contradicts its
  // own offer, and a server that notices must say so rather than use it.
  for s in shares {
    if !offered_groups.contains(s.0) {
      raise tls_fatal(tls_alert_illegal_parameter)
    }
  }
  match shares.iter().find_first(fn(s) { s.0 == group }) {
    Some((_, key)) => {
      if group == tls_group_x25519 && key.length() != x25519_key_length {
        raise tls_fatal(tls_alert_illegal_parameter)
      }
      Negotiated(group~, client_key=key, scheme~)
    }
    // §4.1.4: the group is usable, only the share is missing — worth one more round trip.
    None => Retry(group)
  }
}

///|
/// Negotiate a raw ClientHello handshake message: frame it, decode it, and run
/// `tls13_negotiate`. A message that is not a well-formed ClientHello raises decode_error
/// (RFC 8446 §6.2) rather than vanishing into a `None`.
pub fn tls13_negotiate_client_hello(
  message : Bytes,
) -> TlsNegotiation raise TlsAlert {
  guard tls_parse_handshake(message[:]) is Some((msg_type, body)) else {
    raise tls_fatal(tls_alert_decode_error)
  }
  if msg_type != tls_client_hello {
    raise tls_fatal(tls_alert_unexpected_message)
  }
  guard decode_client_hello(body[:]) is Some(ch) else {
    raise tls_fatal(tls_alert_decode_error)
  }
  tls13_negotiate(ch)
}

///|
pub extend TlsNegotiation with Debug::{to_repr}

///|
pub extend TlsNegotiation with Eq::{not_equal, equal}
