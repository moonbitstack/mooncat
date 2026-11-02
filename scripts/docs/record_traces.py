#!/usr/bin/env python3
"""Record what real clients see when they meet one mooncat port.

The playground page reads `docs/assets/negotiation.js`, which this script writes.
Nothing on that page is typed by hand: every trace below is the output of a
client that connected to a running example.

    moon run src/examples/07-http3 --target native &
    python scripts/docs/record_traces.py --host 127.0.0.1 --port 12000 --ws-port 9001

`curl` must have HTTP/2 for the h2 and h2c rows; a build without it is skipped
and the page keeps the row it already had, so a recording made where curl is
capable is not damaged by one made where it is not. The HTTP/3 row needs
`aioquic` (`pip install aioquic`), and is skipped the same way.

Dates in the traces are the dates of the recording, so re-running this changes
the file even when the server is unchanged. It is a recorder, not a test: the
diff is the point.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "docs" / "assets" / "negotiation.js"

H1_REQUEST = "GET / HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
WS_REQUEST = (
    "GET / HTTP/1.1\r\n"
    "Host: {authority}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n"
)


def run(cmd, timeout=25):
    """Run a command, returning its output whatever its exit status."""
    try:
        done = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        return None, str(err)
    out = (done.stdout or "") + (done.stderr or "")
    return out.strip("\n"), None


def curl_features():
    out, _ = run(["curl", "--version"])
    if not out:
        return "curl is not on PATH"
    for line in out.splitlines():
        if line.startswith("Features:"):
            return None if " HTTP2" in line else "curl was built without HTTP/2"
    return "curl did not list its features"


def curl_trace(args):
    out, err = run(["curl", "--noproxy", "*", "-sS", "-m", "10", "-D", "-"] + args)
    if err or out is None:
        return None
    return out


def openssl_alpn(host, port):
    out, _ = run(
        ["bash", "-c", "echo | openssl s_client -connect %s:%d -alpn h2,http/1.1 2>/dev/null"
         % (host, port)]
    )
    if not out:
        return None
    for line in out.splitlines():
        if line.startswith("ALPN protocol:"):
            return line.split(":", 1)[1].strip()
    return None


def h3_trace(host, port):
    """One HTTP/3 request through aioquic, printed the way the page shows it."""
    try:
        import asyncio
        import ssl

        from aioquic.asyncio.client import connect
        from aioquic.asyncio.protocol import QuicConnectionProtocol
        from aioquic.h3.connection import H3_ALPN, H3Connection
        from aioquic.h3.events import DataReceived, HeadersReceived
        from aioquic.quic.configuration import QuicConfiguration
    except ImportError:
        return None

    class Client(QuicConnectionProtocol):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.h3 = H3Connection(self._quic)
            self.waiting = {}

        def quic_event_received(self, event):
            for h3_event in self.h3.handle_event(event):
                waiter = self.waiting.get(getattr(h3_event, "stream_id", None))
                if waiter is None:
                    continue
                if isinstance(h3_event, HeadersReceived):
                    waiter["headers"] += h3_event.headers
                elif isinstance(h3_event, DataReceived):
                    waiter["body"] += h3_event.data
                if getattr(h3_event, "stream_ended", False) and not waiter["done"].done():
                    waiter["done"].set_result(None)

        async def get(self, path):
            stream = self._quic.get_next_available_stream_id()
            waiter = {"headers": [], "body": b"", "done": self._loop.create_future()}
            self.waiting[stream] = waiter
            self.h3.send_headers(
                stream,
                [(b":method", b"GET"), (b":scheme", b"https"),
                 (b":authority", b"%s:%d" % (host.encode(), port)), (b":path", path.encode())],
                end_stream=True,
            )
            self.transmit()
            await waiter["done"]
            return waiter

    async def one():
        config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
        config.verify_mode = ssl.CERT_NONE
        async with connect(host, port, configuration=config, create_protocol=Client) as client:
            return await client.get("/")

    try:
        waiter = asyncio.run(one())
    except Exception as err:  # a server that is not there, a lost handshake
        print("  http/3: %s" % err, file=sys.stderr)
        return None
    lines = [":status      %s" % waiter["headers"][0][1].decode() if waiter["headers"] else ""]
    for name, value in waiter["headers"][1:]:
        lines.append("%-11s %s" % (name.decode(), value.decode()))
    if waiter["body"]:
        lines.append("")
        lines.append(waiter["body"].decode("utf-8", "replace").rstrip("\n"))
    return "\n".join(lines)


def websocket_trace(host, port):
    """The 101 as it comes off the socket, read directly so any curl can do it."""
    import socket

    try:
        with socket.create_connection((host, port), timeout=5) as sock:
            sock.sendall(WS_REQUEST.format(authority="%s:%d" % (host, port)).encode())
            sock.settimeout(2)
            data = b""
            while b"\r\n\r\n" not in data:
                piece = sock.recv(4096)
                if not piece:
                    break
                data += piece
    except OSError as err:
        print("  websocket: %s" % err, file=sys.stderr)
        return None
    head = data.split(b"\r\n\r\n")[0].decode("latin-1")
    return "> " + WS_REQUEST.format(authority="%s:%d" % (host, port)).strip().replace("\r\n", "\n> ") + "\n<\n< " + head.replace("\r\n", "\n< ")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=12000, help="the HTTP/3 example: TCP and UDP")
    parser.add_argument("--ws-port", type=int, default=9001, help="the WebSocket echo example")
    parser.add_argument("--out", default=str(OUT))
    args = parser.parse_args()

    host, port = args.host, args.port
    authority = "%s:%d" % (host, port)
    plain = "http://" + authority + "/"
    secure = "https://" + authority + "/"

    rows = []

    def add(row_id, label, command, kind, trace, note, **extra):
        if trace is None:
            print("  %-10s skipped" % row_id, file=sys.stderr)
            return
        row = {"id": row_id, "label": label, "command": command, "kind": kind,
               "trace": trace, "note": note}
        row.update(extra)
        rows.append(row)
        print("  %-10s recorded" % row_id, file=sys.stderr)

    missing = curl_features()
    if missing:
        print("curl: %s" % missing, file=sys.stderr)

    clear = [] if missing else [
        ("h1", "curl", "curl -i %s" % plain, "clear",
         curl_trace(["--http1.1", plain]),
         "The first bytes are a request line, not a TLS record, so the connection is served as it is."),
        ("h2c", "curl --http2-prior-knowledge", "curl --http2-prior-knowledge -i %s" % plain, "h2c",
         curl_trace(["--http2-prior-knowledge", plain]),
         "The connection opens with the HTTP/2 preface. The listener reads only as far as the first byte that differs, so HTTP/1.1 is not held up behind it."),
    ]
    for row in clear:
        add(*row)

    alpn = openssl_alpn(host, port) if shutil.which("bash") else None
    tls_rows = [] if missing else [
        ("tls-h2", "curl -k --http2", "curl -k --http2 %s" % secure, "tls",
         curl_trace(["-k", "--http2", secure]),
         "The handshake offers h2 and http/1.1; the client takes h2 and every request after it is a stream.",
         alpn),
        ("tls-h1", "curl -k --http1.1", "curl -k --http1.1 %s" % secure, "tls",
         curl_trace(["-k", "--http1.1", secure]),
         "The same port, the same certificate, the same application: only the ALPN answer differs.",
         "http/1.1"),
    ]
    for row in tls_rows:
        add(row[0], row[1], row[2], row[3], row[4], row[5], alpn=row[6])

    add("ws", "curl ws://", "curl -i --http1.1 -H 'Upgrade: websocket' %s"
        % ("http://%s:%d/" % (host, args.ws_port)), "ws",
        websocket_trace(host, args.ws_port),
        "An upgrade is an ordinary request until the 101; after it the same connection carries frames.")

    add("h3", "an HTTP/3 client", "python scripts/docs/record_traces.py  (aioquic, ALPN h3)", "udp",
        h3_trace(host, port),
        "A datagram connection at the same port number. Nothing in the application changed.")

    if not rows:
        print("nothing recorded", file=sys.stderr)
        return 1

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    body = ("/* Recorded by scripts/docs/record_traces.py against a running example.\n"
            "   Regenerate rather than edit: the traces are client output, not prose. */\n"
            "window.TRACES = " + json.dumps(rows, indent=2, ensure_ascii=False) + ";\n")
    out.write_text(body, encoding="utf-8", newline="\n")
    print("wrote %s (%d traces)" % (out, len(rows)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
