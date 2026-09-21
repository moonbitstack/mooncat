// The record-layer driver a transport pumps (RFC 8446 §5): bytes in, handshake messages and
// application data out, and the reverse. It owns the two things a caller should not have to
// re-derive at every call site — the read and write sequence numbers, and the reassembly
// buffer that lets one handshake message span several records while several messages share
// one. Records arrive in the clear until a traffic secret is installed and as TLSCiphertext
// after; change_cipher_spec is the one exception, staying unencrypted for as long as §5
// tolerates it at all. Nothing here touches a socket: a malformed record raises the §5
// alert and the caller decides how the connection dies.

///|
/// What a record turned into. A `HandshakeMsg` carries the whole message, header included,
/// so it can go straight into the transcript hash as well as be parsed.
pub(all) enum TlsRecordEvent {
  HandshakeMsg(msg_type~ : Int, message~ : Bytes)
  AppData(Bytes)
  PeerAlert(TlsAlert)
} derive(Eq, Debug)

///|
/// A record layer in progress: what has arrived but not yet parsed, the handshake bytes
/// still short of a whole message, and each direction's keys once they exist.
pub struct TlsRecordLayer {
  mut inbox : Bytes
  mut partial : Bytes
  mut read : TlsRecordKeys?
  mut write : TlsRecordKeys?
  mut compat : Bool
}

///|
/// A record layer with no keys yet: everything is TLSPlaintext, as it is for the
/// ClientHello and ServerHello.
pub fn TlsRecordLayer::new() -> TlsRecordLayer {
  { inbox: b"", partial: b"", read: None, write: None, compat: true, }
}

///|
/// Install the read traffic secret: records from the peer are TLSCiphertext from here on
/// and the receive sequence restarts at zero (RFC 8446 §5.3).
pub fn TlsRecordLayer::set_read_secret(
  self : TlsRecordLayer,
  secret : Bytes,
) -> Unit {
  match self.read {
    Some(keys) => keys.rekey(secret)
    None => self.read = Some(TlsRecordKeys::new(secret))
  }
}

///|
/// Install the write traffic secret: records this endpoint sends are TLSCiphertext from
/// here on and the send sequence restarts at zero (RFC 8446 §5.3).
pub fn TlsRecordLayer::set_write_secret(
  self : TlsRecordLayer,
  secret : Bytes,
) -> Unit {
  match self.write {
    Some(keys) => keys.rekey(secret)
    None => self.write = Some(TlsRecordKeys::new(secret))
  }
}

///|
/// The sequence number the next record read will use, zero while no read keys are in.
pub fn TlsRecordLayer::read_seq(self : TlsRecordLayer) -> UInt64 {
  match self.read {
    Some(keys) => keys.seq()
    None => 0UL
  }
}

///|
/// The sequence number the next record written will use, zero while no write keys are in.
pub fn TlsRecordLayer::write_seq(self : TlsRecordLayer) -> UInt64 {
  match self.write {
    Some(keys) => keys.seq()
    None => 0UL
  }
}

///|
/// Close the middlebox-compatibility window (RFC 8446 §5): once the handshake is finished a
/// change_cipher_spec has nothing left to pretend to be, and the next one is an
/// unexpected_message.
pub fn TlsRecordLayer::handshake_done(self : TlsRecordLayer) -> Unit {
  self.compat = false
}

///|
/// Whether a handshake message has arrived in part and is waiting on the rest of itself.
pub fn TlsRecordLayer::has_partial(self : TlsRecordLayer) -> Bool {
  self.partial.length() > 0
}

///|
/// Turn one record's content into events. Handshake content is appended to the reassembly
/// buffer and every whole message now in it comes out, which is what makes a message split
/// across records and several messages in one record the same code path.
fn TlsRecordLayer::deliver(
  self : TlsRecordLayer,
  content_type : Int,
  content : Bytes,
  events : Array[TlsRecordEvent],
) -> Unit raise TlsAlert {
  if content_type == tls_record_handshake {
    self.partial = bytes_concat(self.partial, content)
    let view = self.partial[:]
    let mut off = 0
    for ;; {
      match tls_parse_handshake(view[off:]) {
        Some((msg_type, body)) => {
          let used = 4 + body.length()
          events.push(
            HandshakeMsg(msg_type~, message=view[off:off + used].to_owned()),
          )
          off = off + used
        }
        None => break
      }
    }
    self.partial = view[off:view.length()].to_owned()
    return
  }
  // §5.1: handshake messages must not be interleaved with records of another type, so
  // anything arriving mid-message is a framing error rather than the next thing to handle.
  if self.partial.length() > 0 {
    raise tls_fatal(tls_alert_unexpected_message)
  }
  if content_type == tls_record_application_data {
    events.push(AppData(content))
  } else if content_type == tls_record_alert {
    // §6: an alert is two octets, never split across records and never sharing one.
    if content.length() != 2 {
      raise tls_fatal(tls_alert_decode_error)
    }
    guard tls_decode_alert(content[:]) is Some(alert) else {
      raise tls_fatal(tls_alert_decode_error)
    }
    events.push(PeerAlert(alert))
  } else {
    // A change_cipher_spec that reached this far came out of a TLSCiphertext, and §5 makes
    // a protected one an unexpected_message.
    raise tls_fatal(tls_alert_unexpected_message)
  }
}

///|
/// Feed received bytes and take out everything now complete, in wire order. Bytes short of
/// a whole record are held for the next call. A record that breaks §5 — an undefined
/// content type, a length past the limit, a change_cipher_spec outside its window, a tag
/// that does not verify — raises the alert §5 names for it, and the connection is over.
pub fn TlsRecordLayer::feed(
  self : TlsRecordLayer,
  bytes : Bytes,
) -> Array[TlsRecordEvent] raise TlsAlert {
  self.inbox = bytes_concat(self.inbox, bytes)
  let events : Array[TlsRecordEvent] = []
  let view = self.inbox[:]
  let mut off = 0
  for ;; {
    let rest = view[off:]
    if rest.length() < tls_record_header_len {
      break
    }
    let outer = rest[0].to_int()
    // A change_cipher_spec stays in the clear even after the keys are in (§5), so it is the
    // outer content type, not just the presence of keys, that decides how to read a record.
    let protect = self.read is Some(_) && outer != tls_record_change_cipher_spec
    let limit = if protect {
      tls_record_max_encrypted
    } else {
      tls_record_max_fragment
    }
    guard tls_record_read(rest, limit) is Some((rec, used)) else { break }
    if protect {
      // Once the read keys are in, the only outer type left is application_data: a
      // handshake or alert record still in the clear is an unexpected_message.
      if outer != tls_record_application_data {
        raise tls_fatal(tls_alert_unexpected_message)
      }
      guard self.read is Some(keys) else {
        raise tls_fatal(tls_alert_internal_error)
      }
      let (content_type, content) = keys.open(rest[0:used])
      self.deliver(content_type, content, events)
    } else if rec.content_type == tls_record_change_cipher_spec {
      // §5: tolerated between the first ClientHello and the peer's Finished, and only as
      // the single octet 0x01. It means nothing in TLS 1.3, so it is dropped rather than
      // delivered — but a late one, or one carrying anything else, ends the connection.
      if !self.compat || rec.fragment != b"\x01" {
        raise tls_fatal(tls_alert_unexpected_message)
      }
    } else if rec.content_type == tls_record_application_data {
      // Application data is never sent in the clear: with no read keys installed there is
      // nothing the peer could legitimately be saying under this content type.
      raise tls_fatal(tls_alert_unexpected_message)
    } else {
      self.deliver(rec.content_type, rec.fragment, events)
    }
    off = off + used
  }
  self.inbox = view[off:view.length()].to_owned()
  events
}

///|
/// One record's worth of `content`, sealed if the write keys are in and TLSPlaintext if not.
fn TlsRecordLayer::write_record(
  self : TlsRecordLayer,
  content_type : Int,
  content : Bytes,
) -> Bytes raise TlsAlert {
  match self.write {
    Some(keys) => keys.seal(content_type, content)
    None => tls_record_encode(content_type, content)
  }
}

///|
/// `content` as however many records it takes, splitting at the §5.1 fragment limit.
fn TlsRecordLayer::write_fragmented(
  self : TlsRecordLayer,
  content_type : Int,
  content : Bytes,
) -> Bytes raise TlsAlert {
  if content.length() <= tls_record_max_fragment {
    return self.write_record(content_type, content)
  }
  let out = Buffer()
  let mut off = 0
  while off < content.length() {
    let left = content.length() - off
    let n = if left < tls_record_max_fragment {
      left
    } else {
      tls_record_max_fragment
    }
    out.write_bytes(
      self.write_record(content_type, content[off:off + n].to_owned())[:],
    )
    off = off + n
  }
  out.to_bytes()
}

///|
/// The wire bytes for one or more handshake messages. Pass a whole flight to coalesce it
/// into one record; a message past the fragment limit is split across records by itself
/// (RFC 8446 §5.1), which handshake content is the only content allowed to do.
pub fn TlsRecordLayer::write_handshake(
  self : TlsRecordLayer,
  messages : Bytes,
) -> Bytes raise TlsAlert {
  self.write_fragmented(tls_record_handshake, messages)
}

///|
/// The wire bytes for application data, split across records at the fragment limit.
pub fn TlsRecordLayer::write_app(
  self : TlsRecordLayer,
  data : Bytes,
) -> Bytes raise TlsAlert {
  self.write_fragmented(tls_record_application_data, data)
}

///|
/// The wire bytes for an alert (RFC 8446 §6): one record, two octets, never fragmented.
pub fn TlsRecordLayer::write_alert(
  self : TlsRecordLayer,
  alert : TlsAlert,
) -> Bytes raise TlsAlert {
  self.write_record(tls_record_alert, tls_encode_alert(alert))
}

///|
/// The middlebox-compatibility change_cipher_spec record (RFC 8446 §5): always these six
/// octets — the content type, the frozen version, a length of one, and the single octet
/// 0x01 — always unencrypted, and never meaning anything.
pub let tls_record_ccs : Bytes = b"\x14\x03\x03\x00\x01\x01"

///|
pub extend TlsRecordEvent with Debug::{to_repr}

///|
pub extend TlsRecordEvent with Eq::{not_equal, equal}
