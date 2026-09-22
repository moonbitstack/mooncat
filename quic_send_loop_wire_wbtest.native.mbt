// The assembled QUIC send loop driving a real UDP socket (RFC 9000 §13, RFC 9002): the sender
// polls @conn.Sender for packets, seals each into a 1-RTT packet and puts it on the wire; the
// receiver reassembles the stream and acknowledges; the sender feeds the ACK back to @conn.Sender,
// clearing the outstanding packets. This is the async glue over the deterministic send core.

///|
async test "quic send loop over udp: @conn.Sender streams data through 1-RTT packets and an ACK clears it" {
  @async.with_task_group(g => {
    let master_secret = qv_hexb(
      "2333333333333333333333333333333333333333333333333333333333333333",
    )
    let th = @sha2.hash(b"send-loop-wire-lfanke"[:])
    let sender_keys = @crypto.application(master_secret, th, client=true)
    let ack_keys = @crypto.application(master_secret, th, client=false)
    let server_cid = qv_hexb("00112233aabbccdd")
    let client_cid = qv_hexb("66778899eeff0011")
    let payload = b"hello-quic-send-loop!" // 21 bytes → three 8/8/5 frames at max_frame 8
    let receiver_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let receiver_addr = receiver_ep.local_addr()
    let reassembled : Ref[Bytes] = { val: b"", }
    // Receiver: take three data packets, reassemble the stream, and send one ACK back.
    let _ = g.spawn(() => {
      let reasm = @stream.Assembler::new()
      let acked = @frame.Seen::new()
      let (first, from) = receiver_ep.recv_datagram()
      let note = dg => {
        match
          (@conn.recv_short(dg, server_cid.length(), sender_keys) catch {
            _ => None
          }) {
          Some((frames, pn)) => {
            acked.add(pn.reinterpret_as_uint64())
            for frame in frames {
              match frame {
                @frame.Stream(offset~, data~, ..) =>
                  reasm.insert(offset, data, fin=false) catch {
                    _ => ()
                  }
                _ => ()
              }
            }
          }
          None => ()
        }
      }
      note(first)
      for _i = 1; _i < 3; _i = _i + 1 {
        let (dg, _) = receiver_ep.recv_datagram()
        note(dg)
      }
      reassembled.val = reasm.read()
      match acked.fields() {
        Some((largest, first_range, pairs)) => {
          let ack : @frame.Frame = @frame.Ack(
            largest~,
            delay=0UL,
            first_range~,
            ranges=pairs,
          )
          let pkt = @conn.send_short(client_cid, 0, 4, [ack], ack_keys)
          receiver_ep.send_datagram(pkt, from)
        }
        None => ()
      }
    })
    @async.sleep(100)
    // Sender: queue the stream and drive @conn.Sender, sealing each polled packet onto the wire.
    let sender_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let sender = @conn.Sender::new(
      100000UL, 100000UL, 1200L, 25000L, 1000L, 8UL,
    )
    sender.queue_stream(0UL, payload)
    let mut t = 0L
    for ;; {
      match sender.poll_send(t) {
        Some((pn, frames)) => {
          let pkt = @conn.send_short(server_cid, pn, 4, frames, sender_keys)
          sender_ep.send_datagram(pkt, receiver_addr)
          t = t + 1L
        }
        None => break
      }
    }
    // Open the ACK off the wire and clear the outstanding packets.
    let (ack_dg, _) = sender_ep.recv_datagram()
    match @conn.recv_short(ack_dg, client_cid.length(), ack_keys) {
      Some((frames, _)) =>
        for frame in frames {
          match frame {
            @frame.Ack(..) => sender.on_ack(frame, 100L)
            _ => ()
          }
        }
      None => abort("sender could not open the ACK over the wire")
    }
    @async.sleep(50)
    // The receiver reassembled exactly what was queued, and the sender has nothing outstanding.
    assert_eq(reassembled.val, payload)
    assert_eq(sender.outstanding(), [])
    sender_ep.close()
    receiver_ep.close()
  })
}

///|
async test "quic send loop over udp: a probe timeout retransmits over the wire and the receiver reassembles it" {
  @async.with_task_group(g => {
    let master_secret = qv_hexb(
      "2333333333333333333333333333333333333333333333333333333333333333",
    )
    let th = @sha2.hash(b"send-loop-pto-lfanke"[:])
    let sender_keys = @crypto.application(master_secret, th, client=true)
    let ack_keys = @crypto.application(master_secret, th, client=false)
    let server_cid = qv_hexb("00112233aabbccdd")
    let client_cid = qv_hexb("66778899eeff0011")
    let payload = b"probe!!" // 7 bytes → one STREAM frame at max_frame 8
    let receiver_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let receiver_addr = receiver_ep.local_addr()
    let reassembled : Ref[Bytes] = { val: b"", }
    // Receiver: the first packet's ACK is "lost" — it is received but never acknowledged. Only the
    // probe (second packet) is reassembled and acknowledged.
    let _ = g.spawn(() => {
      let reasm = @stream.Assembler::new()
      let acked = @frame.Seen::new()
      let (_first, _from) = receiver_ep.recv_datagram()
      let (probe, from) = receiver_ep.recv_datagram()
      match
        (@conn.recv_short(probe, server_cid.length(), sender_keys) catch {
          _ => None
        }) {
        Some((frames, pn)) => {
          acked.add(pn.reinterpret_as_uint64())
          for frame in frames {
            match frame {
              @frame.Stream(offset~, data~, ..) =>
                reasm.insert(offset, data, fin=false) catch {
                  _ => ()
                }
              _ => ()
            }
          }
        }
        None => ()
      }
      reassembled.val = reasm.read()
      match acked.fields() {
        Some((largest, first_range, pairs)) => {
          let ack : @frame.Frame = @frame.Ack(
            largest~,
            delay=0UL,
            first_range~,
            ranges=pairs,
          )
          let pkt = @conn.send_short(client_cid, 0, 4, [ack], ack_keys)
          receiver_ep.send_datagram(pkt, from)
        }
        None => ()
      }
    })
    @async.sleep(100)
    let sender_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let sender = @conn.Sender::new(
      100000UL, 100000UL, 1200L, 25000L, 1000L, 8UL,
    )
    sender.queue_stream(0UL, payload)
    // The original packet goes on the wire.
    match sender.poll_send(0L) {
      Some((pn, frames)) => {
        let pkt = @conn.send_short(server_cid, pn, 4, frames, sender_keys)
        sender_ep.send_datagram(pkt, receiver_addr)
      }
      None => abort("expected an initial packet")
    }
    // No ACK arrives; the probe timeout fires and re-queues the outstanding data.
    guard sender.recovery.pto_deadline() is Some(deadline) else {
      abort("expected the probe timer armed")
    }
    assert_eq(sender.on_pto_timeout(deadline), true)
    // The probe crosses the wire as a fresh packet carrying the same stream data.
    match sender.poll_send(deadline + 1L) {
      Some((pn, frames)) => {
        let pkt = @conn.send_short(server_cid, pn, 4, frames, sender_keys)
        sender_ep.send_datagram(pkt, receiver_addr)
      }
      None => abort("expected the probe packet")
    }
    let (ack_dg, _) = sender_ep.recv_datagram()
    match @conn.recv_short(ack_dg, client_cid.length(), ack_keys) {
      Some((frames, _)) =>
        for frame in frames {
          match frame {
            @frame.Ack(..) => sender.on_ack(frame, deadline + 100L)
            _ => ()
          }
        }
      None => abort("sender could not open the probe ACK over the wire")
    }
    @async.sleep(50)
    // The receiver reassembled the payload from the retransmitted probe. (The ACK for the probe
    // has reset the probe count, per RFC 9002 §6.2.1 — the deterministic test checks the backoff.)
    assert_eq(reassembled.val, payload)
    sender_ep.close()
    receiver_ep.close()
  })
}
