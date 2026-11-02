#!/usr/bin/env python3
"""Record both sides of six requests to one mooncat port, for the playground.

The left side is what a client put on the socket and what came back, read at the
socket. The right side is what the application saw: `src/examples/11-event-log`
writes one JSON line per ASGI message, and this script reads them as they come.
The two are merged on time, and written to `docs/assets/traces.js`.

    moon build src/examples/11-event-log --target native
    python scripts/docs/record_traces.py

The HTTP/2 rows need `h2` and the HTTP/3 row `aioquic` (`pip install h2 aioquic`).
Times are the times of the recording, so re-running changes the file even when the
server has not: it is a recorder, not a test.
"""
import asyncio
import json
import pathlib
import queue
import socket
import ssl
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "docs" / "assets" / "traces.js"
EXE = ROOT / "_build" / "native" / "debug" / "build" / "examples" / "11-event-log" / "11-event-log"
HOST, PORT = "127.0.0.1", 12000
AUTHORITY = "%s:%d" % (HOST, PORT)


def now():
    return time.perf_counter() * 1000.0


class Wire:
    """The client's side of one scenario: what it sent and what it read, with times."""

    def __init__(self):
        self.rows = []

    def out(self, title, body="", handshake=False):
        row = {"t": now(), "side": "wire", "dir": "out", "title": title, "body": body}
        if handshake:
            row["handshake"] = True
        self.rows.append(row)

    def came(self, title, body=""):
        self.rows.append({"t": now(), "side": "wire", "dir": "in", "title": title, "body": body})


def printable(data):
    return data.decode("utf-8", "replace").replace("\r\n", "\n").rstrip("\n")


def read_until_closed(sock, wire, title):
    while True:
        piece = sock.recv(65536)
        if not piece:
            return
        wire.came(title % len(piece), printable(piece))


def h1(wire):
    request = ("GET /hello HTTP/1.1\r\nHost: %s\r\nUser-Agent: recorder\r\nConnection: close\r\n\r\n"
               % AUTHORITY).encode()
    with socket.create_connection((HOST, PORT)) as sock:
        wire.out("request · %d B" % len(request), printable(request))
        sock.sendall(request)
        read_until_closed(sock, wire, "response · %d B")


def chunked(wire):
    head = ("POST /upload HTTP/1.1\r\nHost: %s\r\nTransfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n" % AUTHORITY).encode()
    with socket.create_connection((HOST, PORT)) as sock:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        wire.out("request head · %d B" % len(head), printable(head))
        sock.sendall(head)
        for piece in (b"one", b"two", b"three"):
            time.sleep(0.15)
            chunk = b"%x\r\n%s\r\n" % (len(piece), piece)
            wire.out("chunk · %d B" % len(piece), repr(chunk)[2:-1])
            sock.sendall(chunk)
        time.sleep(0.15)
        wire.out("last chunk", "0\\r\\n\\r\\n")
        sock.sendall(b"0\r\n\r\n")
        read_until_closed(sock, wire, "response · %d B")


FRAMES = {0: "DATA", 1: "HEADERS", 2: "PRIORITY", 3: "RST_STREAM", 4: "SETTINGS", 5: "PUSH_PROMISE",
          6: "PING", 7: "GOAWAY", 8: "WINDOW_UPDATE", 9: "CONTINUATION"}
FLAGS = {"DATA": {1: "END_STREAM"}, "HEADERS": {1: "END_STREAM", 4: "END_HEADERS"},
         "SETTINGS": {1: "ACK"}, "PING": {1: "ACK"}}
SETTINGS = {1: "HEADER_TABLE_SIZE", 2: "ENABLE_PUSH", 3: "MAX_CONCURRENT_STREAMS",
            4: "INITIAL_WINDOW_SIZE", 5: "MAX_FRAME_SIZE", 6: "MAX_HEADER_LIST_SIZE",
            8: "ENABLE_CONNECT_PROTOCOL"}


def frames(data):
    """Split bytes that hold whole frames; the caller keeps what is left."""
    out, at = [], 0
    while len(data) - at >= 9:
        size = int.from_bytes(data[at:at + 3], "big")
        if len(data) - at < 9 + size:
            break
        kind = FRAMES.get(data[at + 3], "type %d" % data[at + 3])
        flags = data[at + 4]
        stream = int.from_bytes(data[at + 5:at + 9], "big") & 0x7FFFFFFF
        out.append((kind, flags, stream, data[at + 9:at + 9 + size]))
        at += 9 + size
    return out, data[at:]


def describe(kind, flags, stream, payload):
    names = [name for bit, name in FLAGS.get(kind, {}).items() if flags & bit]
    title = "%s · stream %d%s" % (kind, stream, (" · " + " ".join(names)) if names else "")
    if kind == "SETTINGS":
        pairs = [(int.from_bytes(payload[i:i + 2], "big"), int.from_bytes(payload[i + 2:i + 6], "big"))
                 for i in range(0, len(payload), 6)]
        body = "\n".join("%s %d" % (SETTINGS.get(k, str(k)), v) for k, v in pairs)
    elif kind == "WINDOW_UPDATE":
        body = "+%d" % int.from_bytes(payload[:4], "big")
    elif kind == "DATA":
        body = printable(payload)
    elif kind == "GOAWAY":
        body = "last stream %d · code %d" % (int.from_bytes(payload[:4], "big") & 0x7FFFFFFF,
                                             int.from_bytes(payload[4:8], "big"))
    else:
        body = ""
    return title, body


def h2_session(sock, wire, requests):
    """Drive an HTTP/2 connection: send `requests` at once, then read until every stream ends."""
    import h2.config
    import h2.connection
    import h2.events

    conn = h2.connection.H2Connection(h2.config.H2Configuration(client_side=True, header_encoding="utf-8"))
    conn.initiate_connection()
    headers = {}

    def flush(first=False):
        data = conn.data_to_send()
        if first:
            wire.out("connection preface · 24 B", "PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n")
        sent, _ = frames(data[24:] if first else data)
        for kind, flags, stream, payload in sent:
            title, body = describe(kind, flags, stream, payload)
            if kind == "HEADERS":
                body = "\n".join("%s %s" % pair for pair in headers.get(stream, []))
            wire.out(title, body)
        sock.sendall(data)

    flush(first=True)
    for method, path, body in requests:
        stream = conn.get_next_available_stream_id()
        sent = [(":method", method), (":scheme", "https" if isinstance(sock, ssl.SSLSocket) else "http"),
                (":authority", AUTHORITY), (":path", path)]
        headers[stream] = sent
        conn.send_headers(stream, sent, end_stream=body is None)
        if body is not None:
            conn.send_data(stream, body, end_stream=True)
    flush()
    open_streams, pending = len(requests), b""
    while open_streams:
        piece = sock.recv(65536)
        if not piece:
            break
        pending += piece
        got, pending_left = frames(pending)
        events = conn.receive_data(pending[:len(pending) - len(pending_left)])
        pending = pending_left
        answered = {e.stream_id: e.headers for e in events if isinstance(e, h2.events.ResponseReceived)}
        for kind, flags, stream, payload in got:
            title, body = describe(kind, flags, stream, payload)
            if kind == "HEADERS" and stream in answered:
                body = "\n".join("%s %s" % pair for pair in answered[stream])
            wire.came(title, body)
        open_streams -= sum(isinstance(e, h2.events.StreamEnded) for e in events)
        flush()
    conn.close_connection()
    flush()


def h2c(wire):
    with socket.create_connection((HOST, PORT)) as sock:
        h2_session(sock, wire, [("GET", "/left", None), ("GET", "/right", None)])


def tls(wire):
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2", "http/1.1"])
    with socket.create_connection((HOST, PORT)) as raw:
        wire.out("ClientHello", "ALPN h2, http/1.1", handshake=True)
        sock = context.wrap_socket(raw, server_hostname="localhost")
        version, cipher = sock.version(), sock.cipher()[0]
        wire.came("handshake done", "%s · %s\nALPN %s" % (version, cipher, sock.selected_alpn_protocol()))
        h2_session(sock, wire, [("POST", "/secure", b"over TLS")])
        sock.close()


def h3(wire):
    from aioquic.asyncio.client import connect
    from aioquic.asyncio.protocol import QuicConnectionProtocol
    from aioquic.h3.connection import H3_ALPN, H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.events import HandshakeCompleted

    class Client(QuicConnectionProtocol):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.h3 = H3Connection(self._quic)
            self.done = None

        def quic_event_received(self, event):
            if isinstance(event, HandshakeCompleted):
                wire.came("QUIC handshake done", "TLSv1.3 inside QUIC · ALPN %s" % event.alpn_protocol)
            for e in self.h3.handle_event(event):
                end = " · END_STREAM" if getattr(e, "stream_ended", False) else ""
                if isinstance(e, HeadersReceived):
                    wire.came("HEADERS · stream %d%s" % (e.stream_id, end),
                              "\n".join("%s %s" % (k.decode(), v.decode()) for k, v in e.headers))
                elif isinstance(e, DataReceived):
                    wire.came("DATA · stream %d%s" % (e.stream_id, end), printable(e.data))
                if getattr(e, "stream_ended", False) and self.done and not self.done.done():
                    self.done.set_result(None)

        async def get(self, path):
            stream = self._quic.get_next_available_stream_id()
            self.done = self._loop.create_future()
            sent = [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", AUTHORITY.encode()),
                    (b":path", path.encode())]
            wire.out("HEADERS · stream %d · END_STREAM" % stream,
                     "\n".join("%s %s" % (k.decode(), v.decode()) for k, v in sent))
            self.h3.send_headers(stream, sent, end_stream=True)
            self.transmit()
            await self.done

    async def one():
        from aioquic.quic.configuration import QuicConfiguration

        config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
        config.verify_mode = ssl.CERT_NONE
        wire.out("QUIC Initial · UDP", "ALPN h3", handshake=True)
        async with connect(HOST, PORT, configuration=config, create_protocol=Client) as client:
            await client.get("/over-udp")

    asyncio.run(one())


def ws(wire):
    request = ("GET /chat HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
               % AUTHORITY).encode()

    def frame(opcode, payload):
        mask = b"\x11\x22\x33\x44"
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked

    def read_frame(sock):
        head = sock.recv(2)
        size = head[1] & 0x7F
        payload = b""
        while len(payload) < size:
            payload += sock.recv(size - len(payload))
        return head[0] & 0x0F, payload

    with socket.create_connection((HOST, PORT)) as sock:
        wire.out("upgrade request · %d B" % len(request), printable(request))
        sock.sendall(request)
        data = b""
        while b"\r\n\r\n" not in data:
            data += sock.recv(4096)
        wire.came("101 · %d B" % len(data), printable(data))
        text = b"hello"
        wire.out("text frame · %d B · masked" % len(text), text.decode())
        sock.sendall(frame(1, text))
        opcode, payload = read_frame(sock)
        wire.came("text frame · %d B" % len(payload), payload.decode())
        wire.out("close frame · 1000", "")
        sock.sendall(frame(8, (1000).to_bytes(2, "big")))
        opcode, payload = read_frame(sock)
        wire.came("close frame · %d" % int.from_bytes(payload[:2], "big") if payload else "close frame", "")


SCENARIOS = [
    ("h1", h1, {
        "en": ("HTTP/1.1", "GET /hello over a plain socket",
               "One request line, one scope, one empty http.request: a GET has no body, and the application asks anyway."),
        "zh": ("HTTP/1.1", "在普通 socket 上 GET /hello",
               "一行请求行，一个 scope，一次空的 http.request：GET 没有请求体，应用照样来取。")}),
    ("chunked", chunked, {
        "en": ("a body in pieces", "POST /upload, chunked, three pieces 150 ms apart",
               "Each chunk becomes an http.request the moment it arrives, with more_body true until the last one."),
        "zh": ("分块上传", "POST /upload，分块编码，三块，每块隔 150 毫秒",
               "每块一到就成为一次 http.request，more_body 一直是 true，直到最后一块。")}),
    ("h2c", h2c, {
        "en": ("HTTP/2", "two GETs at once on one cleartext connection",
               "Two streams, two scopes, two calls of the application running side by side on one socket."),
        "zh": ("HTTP/2", "一条明文连接上同时发两个 GET",
               "两条流，两个 scope，同一个 socket 上两次应用调用并行。")}),
    ("tls", tls, {
        "en": ("TLS + ALPN", "a TLS handshake that settles on h2, then a POST",
               "The first byte was 0x16, so the port answered with TLS; ALPN chose HTTP/2, and the scope says https."),
        "zh": ("TLS + ALPN", "TLS 握手协商出 h2，再发一个 POST",
               "首字节是 0x16，端口按 TLS 应答；ALPN 选了 HTTP/2，scope 的 scheme 是 https。")}),
    ("h3", h3, {
        "en": ("HTTP/3", "GET /over-udp over QUIC: the same port number, on UDP",
               "A different transport and the same application: the scope says 3, nothing else changes."),
        "zh": ("HTTP/3", "经 QUIC 发 GET /over-udp：同一个端口号，走 UDP",
               "传输换了，应用没换：scope 写着 3，其余一样。")}),
    ("ws", ws, {
        "en": ("WebSocket", "upgrade, one message each way, close",
               "Up to the 101 it is HTTP; after it the same connection carries frames, and each one is a message."),
        "zh": ("WebSocket", "升级，双向各一条消息，关闭",
               "到 101 为止是 HTTP；之后同一条连接上走帧，每帧是一条消息。")}),
]


def asgi(message):
    """A JSON line from the event log, as the MoonBit value the application handled."""
    kind = message.get("type", "")
    quote = lambda s: json.dumps(s, ensure_ascii=False)
    if kind in ("http", "websocket"):
        names = ", ".join(name for name, _ in message.get("headers", []))
        lines = ["%-13s %s" % (k, quote(message[k])) for k in ("http_version", "method", "scheme", "path")
                 if k in message]
        lines.append("%-13s %s" % ("headers", names or "none"))
        return ("Http" if kind == "http" else "WebSocket") + " scope", "\n".join(lines)
    ctor = {"http.request": "HttpRequest", "http.response.start": "HttpResponseStart",
            "http.response.body": "HttpResponseBody", "http.disconnect": "HttpDisconnect",
            "websocket.connect": "WebSocketConnect", "websocket.accept": "WebSocketAccept",
            "websocket.receive": "WebSocketReceive", "websocket.send": "WebSocketSendText",
            "websocket.disconnect": "WebSocketDisconnect", "websocket.close": "WebSocketClose"}.get(kind, kind)
    args = []
    for key, value in message.items():
        if key == "type":
            continue
        if key == "body":
            args.append('body=b%s' % quote(value))
        elif key == "headers":
            args.append("headers=[%s]" % ", ".join("(%s, %s)" % (quote(k), quote(v)) for k, v in value))
        elif isinstance(value, bool):
            args.append("%s=%s" % (key, "true" if value else "false"))
        elif value is None:
            args.append("%s=None" % key)
        elif key == "text" and kind == "websocket.receive":
            args.append("text=Some(%s)" % quote(value))
        elif key == "text":
            args.append(quote(value))
        elif isinstance(value, float) and value.is_integer():
            args.append("%s=%d" % (key, value))
        else:
            args.append("%s=%s" % (key, quote(value)))
    return kind, ctor + ("(%s)" % ", ".join(args) if args else "")


def offset(wire_rows, app_rows):
    """The server's clock against the client's. Both are monotonic but start apart, and
    causality bounds the gap: the application saw nothing before the client's first byte
    left after the handshake, and sent nothing after the client's last byte arrived. The
    middle of that window is off by at most half of what the loopback took."""
    first_out = min(r["t"] for r in wire_rows if r["dir"] == "out" and not r.get("handshake"))
    last_in = max(r["t"] for r in wire_rows if r["dir"] == "in")
    low = first_out - min(r["t"] for r in app_rows)
    sends = [r["t"] for r in app_rows if r["dir"] == "send"]
    high = last_in - max(sends) if sends else low
    return (low + high) / 2 if high > low else low


def merge(wire_rows, app_rows):
    shift = offset(wire_rows, app_rows) if app_rows else 0
    for row in app_rows:
        row["t"] += shift
    out, i, j = [], 0, 0
    while i < len(wire_rows) or j < len(app_rows):
        if j == len(app_rows) or (i < len(wire_rows) and wire_rows[i]["t"] <= app_rows[j]["t"]):
            out.append(wire_rows[i])
            i += 1
        else:
            out.append(app_rows[j])
            j += 1
    start = out[0]["t"]
    for row in out:
        row["t"] = round(row["t"] - start, 1)
        row.pop("handshake", None)
    return out


def main():
    if not EXE.with_suffix(".exe").exists() and not EXE.exists():
        print("build the example first: moon build src/examples/11-event-log --target native", file=sys.stderr)
        return 1
    exe = EXE.with_suffix(".exe") if EXE.with_suffix(".exe").exists() else EXE
    server = subprocess.Popen([str(exe)], cwd=ROOT, stdout=subprocess.PIPE, text=True, encoding="utf-8")
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in server.stdout], daemon=True).start()
    try:
        for _ in range(100):
            try:
                socket.create_connection((HOST, PORT), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        time.sleep(0.5)
        while not lines.empty():
            lines.get()
        rows = []
        for key, run, words in SCENARIOS:
            wire = Wire()
            try:
                run(wire)
            except ImportError as err:
                print("  %-8s skipped: %s" % (key, err), file=sys.stderr)
                continue
            time.sleep(0.6)
            seen = []
            while not lines.empty():
                entry = json.loads(lines.get())
                if entry["peer"]:
                    title, body = asgi(entry["message"])
                    seen.append({"t": entry["t"], "side": "app", "dir": entry["call"],
                                 "title": title, "body": body})
            rows.append({"id": key, "words": {lang: dict(zip(("label", "command", "note"), text))
                                              for lang, text in words.items()},
                         "rows": merge(wire.rows, seen)})
            print("  %-8s %d on the wire, %d in the application" % (key, len(wire.rows), len(seen)),
                  file=sys.stderr)
    finally:
        server.kill()
        server.wait()
    OUT.write_text("/* Recorded by scripts/docs/record_traces.py from src/examples/11-event-log.\n"
                   "   Regenerate rather than edit: every row is what a socket or the application saw. */\n"
                   "window.SIDES = " + json.dumps(rows, indent=1, ensure_ascii=False) + ";\n",
                   encoding="utf-8", newline="\n")
    print("wrote %s (%d scenarios)" % (OUT.relative_to(ROOT), len(rows)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
