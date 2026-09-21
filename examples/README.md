# Examples

Runnable tours of the public `@mooncat` API — the ASGI server surface and every
codec, state machine, and crypto primitive it is built on. Each folder is a
`main` package you run on the native target:

```bash
moon run examples/03-hash --target native
```

Most examples drive a codec or state machine **in-process** over byte buffers and
print the actual result (hashes, wire bytes, decoded headers, round-trip
equality), so running one proves the feature works. The `serve*` entry points
(`00-hello` over HTTP/1.1, `33-http2-h2c` over HTTP/2 cleartext) bind a real
socket instead and block in the accept loop until cancelled.

## Server

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`hello`](00-hello/) | Serve the smallest moonasgi app over native HTTP/1.1 | `serve`, `@moonasgi.AsgiApp`, `Event::HttpResponseStart` / `HttpResponseBody` |
| 01 | [`lifespan`](01-lifespan/) | The ASGI lifespan protocol driven in-process over async queues | `Lifespan::new` / `spawn` / `startup` / `shutdown` |
| 02 | [`config`](02-config/) | The `Config` transport knobs and the `TlsCert` bundle | `Config::new` / `bind`, `TlsCert` |

## HTTP/2

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 33 | [`http2-h2c`](33-http2-h2c/) | Serve a moonasgi app over prior-knowledge HTTP/2 cleartext (h2c, RFC 7540 §3.4) on moonrpc's self-built HTTP/2 + HPACK transport | `serve_h2c_config`, `serve_h2c`, `Config::bind` |

## Crypto primitives

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |

## TLS 1.3

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 13 | [`tls-keyschedule`](13-tls-keyschedule/) | The RFC 8446 key schedule and Finished verify_data (RFC 8448 vectors) | `tls13_early_secret` / `tls13_handshake_secret` / `tls13_master_secret` / `tls13_finished_verify` |
| 14 | [`tls-hello`](14-tls-hello/) | ClientHello/ServerHello encode/decode with key_share and ALPN | `encode_client_hello` / `decode_client_hello`, `tls_encode_key_share_client`, `tls_alpn_extension` |
| 15 | [`tls-ecdhe`](15-tls-ecdhe/) | The x25519 ECDHE that turns the hello key_shares into handshake keys | `tls13_x25519_public`, `tls13_ecdhe_shared`, `tls13_ecdhe_handshake_traffic_secret` |
| 16 | [`tls-certificate`](16-tls-certificate/) | The Certificate message and a real ES256 CertificateVerify | `tls13_encode_certificate` / `_decode_certificate`, `tls13_certificate_verify_sign` / `_check` |
| 17 | [`tls-handshake`](17-tls-handshake/) | The transcript hash and the server/client handshake state machines | `TranscriptHash`, `TlsServerHandshake`, `tls_client_next` |

## WebSocket

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 11 | [`ws-handshake`](11-ws-handshake/) | The 101 upgrade: accept key and subprotocol negotiation | `websocket_accept_key`, `websocket_select_subprotocol`, `websocket_handshake_response` |

> 03 至 10 原本演示的是密码学与编码的基元。那些基元 2026-09-21 迁去了 [`mooncrypt`](https://github.com/moonbitstack/mooncrypt)、[`mooncred`](https://github.com/moonbitstack/mooncred) 与 [`moonbase`](https://github.com/moonbitstack/moonbase)，示例随之搬走：跑 `moon run examples/tour` 看它们。编号留空不补，免得旧链接失效。
| 12 | [`ws-frame`](12-ws-frame/) | The frame codec: masked/unmasked frames, close payloads, opcodes | `ws_encode_frame`, `ws_decode_frame`, `ws_close_payload`, `WsOpcode` |

## QUIC (HTTP/3 transport)

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 18 | [`quic-varint`](18-quic-varint/) | Variable-length integers and truncated packet numbers | `quic_varint_encode` / `_decode`, `quic_pn_encode` / `_decode` / `_len` |
| 19 | [`quic-frames`](19-quic-frames/) | The frame codec and long/short packet headers | `encode_frame` / `parse_frame`, `encode_long_header`, `encode_short_header` |
| 20 | [`quic-transport-params`](20-quic-transport-params/) | The transport-parameter block (id, length, value) | `transport_param_int`, `encode_transport_params`, `transport_param_as_int` |
| 21 | [`quic-crypto`](21-quic-crypto/) | RFC 9001 Initial keys, packet protect/recover, header protection, key update | `quic_packet_keys`, `quic_send_initial` / `_recv_initial`, `quic_hp_mask`, `quic_key_update` |
| 22 | [`quic-ack`](22-quic-ack/) | ACK-range accounting and packet-number-space bookkeeping | `AckRangeSet`, `PacketNumberSpace`, `ack_fields_to_ranges` |
| 23 | [`quic-flow`](23-quic-flow/) | Send/receive flow control and connection-wide windows | `SendFlow`, `RecvFlow`, `QuicSendFlow` |
| 24 | [`quic-recovery`](24-quic-recovery/) | NewReno congestion control, RTT estimation, the recovery loop | `NewReno`, `RttEstimator`, `QuicRecovery` |
| 25 | [`quic-streams`](25-quic-streams/) | Stream-id classification, the send/recv state machines, reassembly | `stream_id_of`, `send_stream_next` / `recv_stream_next`, `StreamReassembler` |
| 26 | [`quic-sender`](26-quic-sender/) | Receive-side manager, send scheduler, sender, and the connection | `StreamManager`, `QuicStreamScheduler`, `QuicSender`, `QuicConnection` |

## QPACK (HTTP/3 header compression)

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 27 | [`qpack-primitives`](27-qpack-primitives/) | The static table, prefixed integers, and string literals | `qpack_static_get` / `_find`, `qpack_int_encode`, `qpack_encode_string` |
| 28 | [`qpack-field`](28-qpack-field/) | Field-section coding raw and Huffman, plus the section prefix | `qpack_encode_field_section` / `_decode_field_section`, `qpack_encode_section_prefix` |
| 29 | [`qpack-dynamic`](29-qpack-dynamic/) | The dynamic table, encoder instructions, and a dynamic round-trip | `QpackDynamicTable`, `qpack_encode_encoder_inst`, `qpack_encode_dynamic` |

## HTTP/3

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 30 | [`http3-frames`](30-http3-frames/) | The frame codec, `decode_all`, and per-stream frame gating | `http3_frame_encode` / `_decode` / `_decode_all`, `http3_frame_allowed` |
| 31 | [`http3-message`](31-http3-message/) | Requests/responses over HEADERS + DATA, and a handler serve | `http3_request` / `http3_response`, `http3_decode_message`, `http3_serve` |
| 32 | [`http3-conn`](32-http3-conn/) | SETTINGS on the control stream and the uni-stream demultiplexer | `Http3Settings`, `http3_encode_control_stream`, `Http3Conn` |

## Notes

**Native only.** `mooncat` rides `moonbitlang/async` (a native-only HTTP/TLS
transport), so the whole library — and every example — builds and runs on the
`native` target. Each example package declares `supported_targets = "+native"`,
so `moon check --target all` skips them on the other backends and they stay
green there.

`serve` (00-hello) blocks in a keep-alive accept loop until its task is
cancelled — leave it running and hit it from another shell:

```bash
curl http://127.0.0.1:23333
# hello from mooncat, heke1228
```
