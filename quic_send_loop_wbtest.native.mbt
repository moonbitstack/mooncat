// The QUIC send loop over a real UDP socket (RFC 9000 §13, RFC 9002): a sender puts ack-
// eliciting 1-RTT packets on the wire and tracks them in QuicRecovery; the receiver acknowledges
// the subset it "received" (here a hole at 0 and 1 stands in for loss); the sender opens the ACK
// off the wire, and QuicRecovery samples the RTT, grows then halves the window, and lists the
// packet numbers to retransmit. This closes the recovery loop over a real datagram round trip.

///|
async test "quic send loop: a real ACK over UDP drives QuicRecovery to detect loss and list retransmissions" {
  @async.with_task_group(g => {
    let master_secret = qv_hexb(
      "6666666666666666666666666666666666666666666666666666666666666666",
    )
    let th = @sha2.hash(b"send-loop-connected-lfanke"[:])
    let sender_keys = quic_application_keys(master_secret, th, true)
    let ack_keys = quic_application_keys(master_secret, th, false)
    let server_cid = qv_hexb("00112233aabbccdd")
    let client_cid = qv_hexb("66778899eeff0011")
    let receiver_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let receiver_addr = receiver_ep.local_addr()
    // Receiver: take five data packets, acknowledge only those numbered 2 and up (0 and 1 stand
    // in for lost packets), then send one ACK back to the sender.
    let _ = g.spawn(() => {
      let acked = AckRangeSet::new()
      let (first, from) = receiver_ep.recv_datagram()
      let note = dg => {
        match
          (quic_recv_short(dg, server_cid.length(), sender_keys) catch {
            _ => None
          }) {
          Some((_frames, pn)) =>
            if pn >= 2L {
              acked.add(pn.reinterpret_as_uint64())
            }
          None => ()
        }
      }
      note(first)
      for _i = 1; _i < 5; _i = _i + 1 {
        let (dg, _) = receiver_ep.recv_datagram()
        note(dg)
      }
      match acked.to_ack_fields() {
        Some((largest, first_range, pairs)) => {
          let ack : QuicFrame = Ack(
            largest~,
            delay=0UL,
            first_range~,
            ranges=pairs,
          )
          let pkt = quic_send_short(
            false,
            false,
            client_cid,
            0,
            4,
            [ack],
            ack_keys,
          )
          receiver_ep.send_datagram(pkt, from)
        }
        None => ()
      }
    })
    @async.sleep(100)
    // Sender: five ack-eliciting 1-RTT packets, each recorded in the recovery state.
    let sender_ep = QuicUdpEndpoint::bind("127.0.0.1:0")
    let rec = QuicRecovery::new(1200L, 25000L, 1000L)
    for pn = 0L; pn < 5L; pn = pn + 1L {
      let pkt = quic_send_short(
        false,
        false,
        server_cid,
        pn,
        4,
        [Ping],
        sender_keys,
      )
      sender_ep.send_datagram(pkt, receiver_addr)
      rec.on_packet_sent(pn, pn, 1200L)
    }
    // Open the ACK off the wire and drive the recovery state.
    let (ack_dg, _) = sender_ep.recv_datagram()
    let lost = match quic_recv_short(ack_dg, client_cid.length(), ack_keys) {
      Some((frames, _)) => {
        let mut result : Array[Int64] = []
        for frame in frames {
          match frame {
            Ack(..) => result = rec.on_ack_received(frame, 10L, 0L)
            _ => ()
          }
        }
        result
      }
      None => abort("sender could not open the ACK over the wire")
    }
    @async.sleep(50)
    // Packets 0 and 1 are three-plus before the largest acknowledged (4): declared lost.
    assert_eq(lost, [0L, 1L])
    assert_eq(rec.outstanding(), [])
    // on_ack grew the window by the three acknowledged packets (12000+3600=15600), then the
    // congestion signal halved it to 7800.
    assert_eq(rec.window(), 7800L)
    assert_eq(rec.in_flight(), 0L)
    sender_ep.close()
    receiver_ep.close()
  })
}
