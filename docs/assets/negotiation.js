/* Recorded by scripts/docs/record_traces.py against a running example.
   Regenerate rather than edit: the traces are client output, not prose. */
window.TRACES = [
  {
    "id": "h1",
    "label": "curl",
    "command": "curl -i http://127.0.0.1:12000/",
    "kind": "clear",
    "trace": "HTTP/1.1 200 OK\ncontent-type: text/plain\nserver: mooncat\nalt-svc: h3=\":12000\"; ma=86400\ndate: Mon, 02 Nov 2026 09:36:57 GMT\ncontent-length: 12\n\n1.1 GET / 0",
    "note": "The first bytes are a request line, not a TLS record, so the connection is served as it is."
  },
  {
    "id": "h2c",
    "label": "curl --http2-prior-knowledge",
    "command": "curl --http2-prior-knowledge -i http://127.0.0.1:12000/",
    "kind": "h2c",
    "trace": "HTTP/2 200 \ncontent-type: text/plain\nserver: mooncat\nalt-svc: h3=\":12000\"; ma=86400\ndate: Mon, 02 Nov 2026 09:36:57 GMT\n\n2 GET / 0",
    "note": "The connection opens with the HTTP/2 preface. The listener reads only as far as the first byte that differs, so HTTP/1.1 is not held up behind it."
  },
  {
    "id": "tls-h2",
    "label": "curl -k --http2",
    "command": "curl -k --http2 https://127.0.0.1:12000/",
    "kind": "tls",
    "trace": "HTTP/2 200 \ncontent-type: text/plain\nserver: mooncat\nalt-svc: h3=\":12000\"; ma=86400\ndate: Mon, 02 Nov 2026 09:36:58 GMT\n\n2 GET / 0",
    "note": "The handshake offers h2 and http/1.1; the client takes h2 and every request after it is a stream.",
    "alpn": "h2"
  },
  {
    "id": "tls-h1",
    "label": "curl -k --http1.1",
    "command": "curl -k --http1.1 https://127.0.0.1:12000/",
    "kind": "tls",
    "trace": "HTTP/1.1 200 OK\ncontent-type: text/plain\nserver: mooncat\nalt-svc: h3=\":12000\"; ma=86400\ndate: Mon, 02 Nov 2026 09:36:58 GMT\ncontent-length: 12\n\n1.1 GET / 0",
    "note": "The same port, the same certificate, the same application: only the ALPN answer differs.",
    "alpn": "http/1.1"
  },
  {
    "id": "ws",
    "label": "curl ws://",
    "command": "curl -i --http1.1 -H 'Upgrade: websocket' http://127.0.0.1:9001/",
    "kind": "ws",
    "trace": "> GET / HTTP/1.1\n> Host: 127.0.0.1:9001\n> Upgrade: websocket\n> Connection: Upgrade\n> Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\n> Sec-WebSocket-Version: 13\n<\n< HTTP/1.1 101 Switching Protocols\n< Upgrade: websocket\n< Connection: Upgrade\n< Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    "note": "An upgrade is an ordinary request until the 101; after it the same connection carries frames."
  },
  {
    "id": "h3",
    "label": "an HTTP/3 client",
    "command": "python scripts/docs/record_traces.py  (aioquic, ALPN h3)",
    "kind": "udp",
    "trace": ":status      200\ncontent-type text/plain\nserver      mooncat\nalt-svc     h3=\":12000\"; ma=86400\ndate        Mon, 02 Nov 2026 09:36:58 GMT\n\n3 GET / 0",
    "note": "A datagram connection at the same port number. Nothing in the application changed."
  }
];
