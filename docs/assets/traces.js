/* Recorded by scripts/docs/record_traces.py from src/examples/11-event-log.
   Regenerate rather than edit: every row is what a socket or the application saw. */
window.SIDES = [
 {
  "id": "h1",
  "words": {
   "en": {
    "label": "HTTP/1.1",
    "command": "GET /hello over a plain socket",
    "note": "One request line, one scope, one empty http.request: a GET has no body, and the application asks anyway."
   },
   "zh": {
    "label": "HTTP/1.1",
    "command": "在普通 socket 上 GET /hello",
    "note": "一行请求行，一个 scope，一次空的 http.request：GET 没有请求体，应用照样来取。"
   }
  },
  "rows": [
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "request · 87 B",
    "body": "GET /hello HTTP/1.1\nHost: 127.0.0.1:12000\nUser-Agent: recorder\nConnection: close"
   },
   {
    "t": 0.3,
    "side": "app",
    "dir": "scope",
    "title": "Http scope",
    "body": "http_version  \"1.1\"\nmethod        \"GET\"\nscheme        \"http\"\npath          \"/hello\"\nheaders       host, user-agent, connection"
   },
   {
    "t": 0.4,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"\", more_body=false)"
   },
   {
    "t": 0.5,
    "side": "app",
    "dir": "send",
    "title": "http.response.start",
    "body": "HttpResponseStart(status=200, headers=[(\"content-type\", \"text/plain\")], trailers=false)"
   },
   {
    "t": 0.6,
    "side": "app",
    "dir": "send",
    "title": "http.response.body",
    "body": "HttpResponseBody(body=b\"HTTP/1.1 GET /hello · 0 B\\n\", more_body=false)"
   },
   {
    "t": 0.9,
    "side": "wire",
    "dir": "in",
    "title": "response · 170 B",
    "body": "HTTP/1.1 200 OK\ncontent-type: text/plain\nserver: mooncat\nalt-svc: h3=\":12000\"; ma=86400\ndate: Mon, 02 Nov 2026 14:20:51 GMT\nconnection: close\ncontent-length: 27"
   },
   {
    "t": 0.9,
    "side": "wire",
    "dir": "in",
    "title": "response · 27 B",
    "body": "HTTP/1.1 GET /hello · 0 B"
   }
  ]
 },
 {
  "id": "chunked",
  "words": {
   "en": {
    "label": "a body in pieces",
    "command": "POST /upload, chunked, three pieces 150 ms apart",
    "note": "Each chunk becomes an http.request the moment it arrives, with more_body true until the last one."
   },
   "zh": {
    "label": "分块上传",
    "command": "POST /upload，分块编码，三块，每块隔 150 毫秒",
    "note": "每块一到就成为一次 http.request，more_body 一直是 true，直到最后一块。"
   }
  },
  "rows": [
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "request head · 95 B",
    "body": "POST /upload HTTP/1.1\nHost: 127.0.0.1:12000\nTransfer-Encoding: chunked\nConnection: close"
   },
   {
    "t": 0.3,
    "side": "app",
    "dir": "scope",
    "title": "Http scope",
    "body": "http_version  \"1.1\"\nmethod        \"POST\"\nscheme        \"http\"\npath          \"/upload\"\nheaders       host, transfer-encoding, connection"
   },
   {
    "t": 151.1,
    "side": "wire",
    "dir": "out",
    "title": "chunk · 3 B",
    "body": "3\\r\\none\\r\\n"
   },
   {
    "t": 151.3,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"one\", more_body=true)"
   },
   {
    "t": 301.8,
    "side": "wire",
    "dir": "out",
    "title": "chunk · 3 B",
    "body": "3\\r\\ntwo\\r\\n"
   },
   {
    "t": 301.9,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"two\", more_body=true)"
   },
   {
    "t": 452.9,
    "side": "wire",
    "dir": "out",
    "title": "chunk · 5 B",
    "body": "5\\r\\nthree\\r\\n"
   },
   {
    "t": 453.0,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"three\", more_body=true)"
   },
   {
    "t": 603.5,
    "side": "wire",
    "dir": "out",
    "title": "last chunk",
    "body": "0\\r\\n\\r\\n"
   },
   {
    "t": 603.7,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"\", more_body=false)"
   },
   {
    "t": 603.8,
    "side": "app",
    "dir": "send",
    "title": "http.response.start",
    "body": "HttpResponseStart(status=200, headers=[(\"content-type\", \"text/plain\")], trailers=false)"
   },
   {
    "t": 603.9,
    "side": "app",
    "dir": "send",
    "title": "http.response.body",
    "body": "HttpResponseBody(body=b\"HTTP/1.1 POST /upload · 11 B\\n\", more_body=false)"
   },
   {
    "t": 604.2,
    "side": "wire",
    "dir": "in",
    "title": "response · 170 B",
    "body": "HTTP/1.1 200 OK\ncontent-type: text/plain\nserver: mooncat\nalt-svc: h3=\":12000\"; ma=86400\ndate: Mon, 02 Nov 2026 14:20:52 GMT\nconnection: close\ncontent-length: 30"
   },
   {
    "t": 604.2,
    "side": "wire",
    "dir": "in",
    "title": "response · 30 B",
    "body": "HTTP/1.1 POST /upload · 11 B"
   }
  ]
 },
 {
  "id": "h2c",
  "words": {
   "en": {
    "label": "HTTP/2",
    "command": "two GETs at once on one cleartext connection",
    "note": "Two streams, two scopes, two calls of the application running side by side on one socket."
   },
   "zh": {
    "label": "HTTP/2",
    "command": "一条明文连接上同时发两个 GET",
    "note": "两条流，两个 scope，同一个 socket 上两次应用调用并行。"
   }
  },
  "rows": [
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "connection preface · 24 B",
    "body": "PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n"
   },
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "SETTINGS · stream 0",
    "body": "HEADER_TABLE_SIZE 4096\nENABLE_PUSH 1\nINITIAL_WINDOW_SIZE 65535\nMAX_FRAME_SIZE 16384\nENABLE_CONNECT_PROTOCOL 0\nMAX_CONCURRENT_STREAMS 100\nMAX_HEADER_LIST_SIZE 65536"
   },
   {
    "t": 0.4,
    "side": "wire",
    "dir": "out",
    "title": "HEADERS · stream 1 · END_STREAM END_HEADERS",
    "body": ":method GET\n:scheme http\n:authority 127.0.0.1:12000\n:path /left"
   },
   {
    "t": 0.4,
    "side": "wire",
    "dir": "out",
    "title": "HEADERS · stream 3 · END_STREAM END_HEADERS",
    "body": ":method GET\n:scheme http\n:authority 127.0.0.1:12000\n:path /right"
   },
   {
    "t": 0.4,
    "side": "app",
    "dir": "scope",
    "title": "Http scope",
    "body": "http_version  \"2\"\nmethod        \"GET\"\nscheme        \"http\"\npath          \"/left\"\nheaders       host"
   },
   {
    "t": 0.5,
    "side": "app",
    "dir": "scope",
    "title": "Http scope",
    "body": "http_version  \"2\"\nmethod        \"GET\"\nscheme        \"http\"\npath          \"/right\"\nheaders       host"
   },
   {
    "t": 0.6,
    "side": "wire",
    "dir": "in",
    "title": "SETTINGS · stream 0",
    "body": "MAX_CONCURRENT_STREAMS 100\nINITIAL_WINDOW_SIZE 1048576\nMAX_HEADER_LIST_SIZE 65536"
   },
   {
    "t": 0.6,
    "side": "wire",
    "dir": "in",
    "title": "WINDOW_UPDATE · stream 0",
    "body": "+983041"
   },
   {
    "t": 0.6,
    "side": "wire",
    "dir": "in",
    "title": "SETTINGS · stream 0 · ACK",
    "body": ""
   },
   {
    "t": 0.6,
    "side": "wire",
    "dir": "out",
    "title": "SETTINGS · stream 0 · ACK",
    "body": ""
   },
   {
    "t": 0.6,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"\", more_body=false)"
   },
   {
    "t": 0.7,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"\", more_body=false)"
   },
   {
    "t": 0.8,
    "side": "app",
    "dir": "send",
    "title": "http.response.start",
    "body": "HttpResponseStart(status=200, headers=[(\"content-type\", \"text/plain\")], trailers=false)"
   },
   {
    "t": 1.0,
    "side": "app",
    "dir": "send",
    "title": "http.response.start",
    "body": "HttpResponseStart(status=200, headers=[(\"content-type\", \"text/plain\")], trailers=false)"
   },
   {
    "t": 1.1,
    "side": "app",
    "dir": "send",
    "title": "http.response.body",
    "body": "HttpResponseBody(body=b\"HTTP/2 GET /left · 0 B\\n\", more_body=false)"
   },
   {
    "t": 1.3,
    "side": "app",
    "dir": "send",
    "title": "http.response.body",
    "body": "HttpResponseBody(body=b\"HTTP/2 GET /right · 0 B\\n\", more_body=false)"
   },
   {
    "t": 1.4,
    "side": "wire",
    "dir": "in",
    "title": "HEADERS · stream 1 · END_HEADERS",
    "body": ":status 200\ncontent-type text/plain\nserver mooncat\nalt-svc h3=\":12000\"; ma=86400\ndate Mon, 02 Nov 2026 14:20:53 GMT"
   },
   {
    "t": 1.5,
    "side": "wire",
    "dir": "in",
    "title": "HEADERS · stream 3 · END_HEADERS",
    "body": ":status 200\ncontent-type text/plain\nserver mooncat\nalt-svc h3=\":12000\"; ma=86400\ndate Mon, 02 Nov 2026 14:20:53 GMT"
   },
   {
    "t": 1.6,
    "side": "wire",
    "dir": "in",
    "title": "DATA · stream 1 · END_STREAM",
    "body": "HTTP/2 GET /left · 0 B"
   },
   {
    "t": 1.7,
    "side": "wire",
    "dir": "in",
    "title": "DATA · stream 3 · END_STREAM",
    "body": "HTTP/2 GET /right · 0 B"
   },
   {
    "t": 1.7,
    "side": "wire",
    "dir": "out",
    "title": "GOAWAY · stream 0",
    "body": "last stream 0 · code 0"
   }
  ]
 },
 {
  "id": "tls",
  "words": {
   "en": {
    "label": "TLS + ALPN",
    "command": "a TLS handshake that settles on h2, then a POST",
    "note": "The first byte was 0x16, so the port answered with TLS; ALPN chose HTTP/2, and the scope says https."
   },
   "zh": {
    "label": "TLS + ALPN",
    "command": "TLS 握手协商出 h2，再发一个 POST",
    "note": "首字节是 0x16，端口按 TLS 应答；ALPN 选了 HTTP/2，scope 的 scheme 是 https。"
   }
  },
  "rows": [
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "ClientHello",
    "body": "ALPN h2, http/1.1"
   },
   {
    "t": 90.3,
    "side": "wire",
    "dir": "in",
    "title": "handshake done",
    "body": "TLSv1.3 · TLS_CHACHA20_POLY1305_SHA256\nALPN h2"
   },
   {
    "t": 90.4,
    "side": "wire",
    "dir": "out",
    "title": "connection preface · 24 B",
    "body": "PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n"
   },
   {
    "t": 90.5,
    "side": "wire",
    "dir": "out",
    "title": "SETTINGS · stream 0",
    "body": "HEADER_TABLE_SIZE 4096\nENABLE_PUSH 1\nINITIAL_WINDOW_SIZE 65535\nMAX_FRAME_SIZE 16384\nENABLE_CONNECT_PROTOCOL 0\nMAX_CONCURRENT_STREAMS 100\nMAX_HEADER_LIST_SIZE 65536"
   },
   {
    "t": 90.7,
    "side": "wire",
    "dir": "out",
    "title": "HEADERS · stream 1 · END_HEADERS",
    "body": ":method POST\n:scheme https\n:authority 127.0.0.1:12000\n:path /secure"
   },
   {
    "t": 90.7,
    "side": "wire",
    "dir": "out",
    "title": "DATA · stream 1 · END_STREAM",
    "body": "over TLS"
   },
   {
    "t": 90.8,
    "side": "app",
    "dir": "scope",
    "title": "Http scope",
    "body": "http_version  \"2\"\nmethod        \"POST\"\nscheme        \"https\"\npath          \"/secure\"\nheaders       host"
   },
   {
    "t": 90.8,
    "side": "wire",
    "dir": "in",
    "title": "SETTINGS · stream 0",
    "body": "MAX_CONCURRENT_STREAMS 100\nINITIAL_WINDOW_SIZE 1048576\nMAX_HEADER_LIST_SIZE 65536"
   },
   {
    "t": 90.8,
    "side": "wire",
    "dir": "in",
    "title": "WINDOW_UPDATE · stream 0",
    "body": "+983041"
   },
   {
    "t": 90.9,
    "side": "wire",
    "dir": "out",
    "title": "SETTINGS · stream 0 · ACK",
    "body": ""
   },
   {
    "t": 90.9,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"over TLS\", more_body=false)"
   },
   {
    "t": 91.0,
    "side": "app",
    "dir": "send",
    "title": "http.response.start",
    "body": "HttpResponseStart(status=200, headers=[(\"content-type\", \"text/plain\")], trailers=false)"
   },
   {
    "t": 91.0,
    "side": "wire",
    "dir": "in",
    "title": "SETTINGS · stream 0 · ACK",
    "body": ""
   },
   {
    "t": 91.3,
    "side": "app",
    "dir": "send",
    "title": "http.response.body",
    "body": "HttpResponseBody(body=b\"HTTP/2 POST /secure · 8 B\\n\", more_body=false)"
   },
   {
    "t": 91.5,
    "side": "wire",
    "dir": "in",
    "title": "HEADERS · stream 1 · END_HEADERS",
    "body": ":status 200\ncontent-type text/plain\nserver mooncat\nalt-svc h3=\":12000\"; ma=86400\ndate Mon, 02 Nov 2026 14:20:54 GMT"
   },
   {
    "t": 91.6,
    "side": "wire",
    "dir": "in",
    "title": "DATA · stream 1 · END_STREAM",
    "body": "HTTP/2 POST /secure · 8 B"
   },
   {
    "t": 91.6,
    "side": "wire",
    "dir": "out",
    "title": "GOAWAY · stream 0",
    "body": "last stream 0 · code 0"
   }
  ]
 },
 {
  "id": "h3",
  "words": {
   "en": {
    "label": "HTTP/3",
    "command": "GET /over-udp over QUIC: the same port number, on UDP",
    "note": "A different transport and the same application: the scope says 3, nothing else changes."
   },
   "zh": {
    "label": "HTTP/3",
    "command": "经 QUIC 发 GET /over-udp：同一个端口号，走 UDP",
    "note": "传输换了，应用没换：scope 写着 3，其余一样。"
   }
  },
  "rows": [
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "QUIC Initial · UDP",
    "body": "ALPN h3"
   },
   {
    "t": 118.4,
    "side": "wire",
    "dir": "in",
    "title": "QUIC handshake done",
    "body": "TLSv1.3 inside QUIC · ALPN h3"
   },
   {
    "t": 118.7,
    "side": "wire",
    "dir": "out",
    "title": "HEADERS · stream 0 · END_STREAM",
    "body": ":method GET\n:scheme https\n:authority 127.0.0.1:12000\n:path /over-udp"
   },
   {
    "t": 119.3,
    "side": "app",
    "dir": "scope",
    "title": "Http scope",
    "body": "http_version  \"3\"\nmethod        \"GET\"\nscheme        \"https\"\npath          \"/over-udp\"\nheaders       host"
   },
   {
    "t": 119.9,
    "side": "app",
    "dir": "receive",
    "title": "http.request",
    "body": "HttpRequest(body=b\"\", more_body=false)"
   },
   {
    "t": 120.0,
    "side": "app",
    "dir": "send",
    "title": "http.response.start",
    "body": "HttpResponseStart(status=200, headers=[(\"content-type\", \"text/plain\")], trailers=false)"
   },
   {
    "t": 120.2,
    "side": "app",
    "dir": "send",
    "title": "http.response.body",
    "body": "HttpResponseBody(body=b\"HTTP/3 GET /over-udp · 0 B\\n\", more_body=false)"
   },
   {
    "t": 120.4,
    "side": "wire",
    "dir": "in",
    "title": "HEADERS · stream 0",
    "body": ":status 200\ncontent-type text/plain\nserver mooncat\nalt-svc h3=\":12000\"; ma=86400\ndate Mon, 02 Nov 2026 14:20:55 GMT"
   },
   {
    "t": 120.8,
    "side": "wire",
    "dir": "in",
    "title": "DATA · stream 0 · END_STREAM",
    "body": "HTTP/3 GET /over-udp · 0 B"
   }
  ]
 },
 {
  "id": "ws",
  "words": {
   "en": {
    "label": "WebSocket",
    "command": "upgrade, one message each way, close",
    "note": "Up to the 101 it is HTTP; after it the same connection carries frames, and each one is a message."
   },
   "zh": {
    "label": "WebSocket",
    "command": "升级，双向各一条消息，关闭",
    "note": "到 101 为止是 HTTP；之后同一条连接上走帧，每帧是一条消息。"
   }
  },
  "rows": [
   {
    "t": 0.0,
    "side": "wire",
    "dir": "out",
    "title": "upgrade request · 158 B",
    "body": "GET /chat HTTP/1.1\nHost: 127.0.0.1:12000\nUpgrade: websocket\nConnection: Upgrade\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\nSec-WebSocket-Version: 13"
   },
   {
    "t": 0.4,
    "side": "app",
    "dir": "scope",
    "title": "WebSocket scope",
    "body": "http_version  \"1.1\"\nscheme        \"ws\"\npath          \"/chat\"\nheaders       host, upgrade, connection, sec-websocket-key, sec-websocket-version"
   },
   {
    "t": 0.5,
    "side": "app",
    "dir": "receive",
    "title": "websocket.connect",
    "body": "WebSocketConnect"
   },
   {
    "t": 0.6,
    "side": "app",
    "dir": "send",
    "title": "websocket.accept",
    "body": "WebSocketAccept(subprotocol=None)"
   },
   {
    "t": 0.8,
    "side": "wire",
    "dir": "in",
    "title": "101 · 129 B",
    "body": "HTTP/1.1 101 Switching Protocols\nUpgrade: websocket\nConnection: Upgrade\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
   },
   {
    "t": 0.8,
    "side": "wire",
    "dir": "out",
    "title": "text frame · 5 B · masked",
    "body": "hello"
   },
   {
    "t": 0.9,
    "side": "app",
    "dir": "receive",
    "title": "websocket.receive",
    "body": "WebSocketReceive(text=Some(\"hello\"))"
   },
   {
    "t": 0.9,
    "side": "app",
    "dir": "send",
    "title": "websocket.send",
    "body": "WebSocketSendText(\"echo: hello\")"
   },
   {
    "t": 1.1,
    "side": "wire",
    "dir": "in",
    "title": "text frame · 11 B",
    "body": "echo: hello"
   },
   {
    "t": 1.1,
    "side": "wire",
    "dir": "out",
    "title": "close frame · 1000",
    "body": ""
   },
   {
    "t": 1.2,
    "side": "app",
    "dir": "receive",
    "title": "websocket.disconnect",
    "body": "WebSocketDisconnect(code=1000)"
   },
   {
    "t": 1.3,
    "side": "wire",
    "dir": "in",
    "title": "close frame · 1000",
    "body": ""
   }
  ]
 }
];
