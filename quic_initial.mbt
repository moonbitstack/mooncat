// QUIC Initial secrets and packet-protection keys (RFC 9001 §5.2). The Initial
// packets are encrypted under keys derived from the client's Destination Connection
// ID and a version-fixed salt — the one part of the QUIC handshake that needs no TLS
// exchange, so it is the first thing a client or server can compute.

///|
/// The version-1 Initial salt (RFC 9001 §5.2).
let quic_v1_initial_salt : Bytes = b"\x38\x76\x2c\xf7\xf5\x59\x34\xb3\x4d\x17\x9a\xe6\xa4\xc8\x0c\xad\xcc\xbb\x7f\x0a"

///|
/// The AEAD packet-protection material for one direction: the 16-byte AES-128 key,
/// the 12-byte IV, and the 16-byte header-protection key (RFC 9001 §5.1, §5.4).
pub(all) struct QuicPacketKeys {
  key : Bytes
  iv : Bytes
  hp : Bytes
} derive(Eq, Debug)

///|
/// The Initial secret shared by both endpoints: HKDF-Extract(initial_salt, DCID),
/// where DCID is the Destination Connection ID from the client's first packet.
pub fn quic_initial_secret(dcid : Bytes) -> Bytes {
  hkdf_extract(quic_v1_initial_salt, dcid)
}

///|
/// The client's Initial secret, `HKDF-Expand-Label(initial, "client in", "", 32)`.
pub fn quic_client_initial_secret(dcid : Bytes) -> Bytes {
  hkdf_expand_label(quic_initial_secret(dcid), b"client in", b"", 32)
}

///|
/// The server's Initial secret, `HKDF-Expand-Label(initial, "server in", "", 32)`.
pub fn quic_server_initial_secret(dcid : Bytes) -> Bytes {
  hkdf_expand_label(quic_initial_secret(dcid), b"server in", b"", 32)
}

///|
/// Derive the key/iv/hp triple from a direction's secret (RFC 9001 §5.1): the labels
/// are "quic key", "quic iv", and "quic hp", at the AEAD_AES_128_GCM lengths.
pub fn quic_packet_keys(secret : Bytes) -> QuicPacketKeys {
  {
    key: hkdf_expand_label(secret, b"quic key", b"", 16),
    iv: hkdf_expand_label(secret, b"quic iv", b"", 12),
    hp: hkdf_expand_label(secret, b"quic hp", b"", 16),
  }
}

///|
pub extend QuicPacketKeys with Debug::{to_repr}

///|
pub extend QuicPacketKeys with Eq::{not_equal, equal}
