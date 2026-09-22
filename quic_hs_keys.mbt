// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The QUIC packet keys derived from TLS 1.3's traffic secrets (RFC 9001 §5.2).
//
// The secrets themselves are `moontls`' key schedule — QUIC reuses it verbatim.
// What is here is the QUIC wiring on top: which secret keys which packet space,
// and the key/iv/hp each one expands to.

///|
/// The QUIC Handshake-space AEAD key/iv/hp for this endpoint, from the handshake
/// traffic secret over the ClientHello..ServerHello transcript (RFC 9001 §5.2).
pub fn quic_handshake_keys(
  handshake_secret : Bytes,
  transcript_hash : Bytes,
  is_client : Bool,
) -> QuicPacketKeys {
  let secret = if is_client {
    @keys.client_handshake(handshake_secret[:], transcript_hash[:])
  } else {
    @keys.server_handshake(handshake_secret[:], transcript_hash[:])
  }
  quic_packet_keys(secret)
}

///|
/// The QUIC Application (1-RTT) AEAD key/iv/hp for this endpoint, from the
/// application traffic secret over the ClientHello..server Finished transcript.
pub fn quic_application_keys(
  master_secret : Bytes,
  transcript_hash : Bytes,
  is_client : Bool,
) -> QuicPacketKeys {
  let secret = if is_client {
    @keys.client_application(master_secret[:], transcript_hash[:])
  } else {
    @keys.server_application(master_secret[:], transcript_hash[:])
  }
  quic_packet_keys(secret)
}
