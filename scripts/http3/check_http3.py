"""HTTP/3 against aioquic, an implementation that shares no code with this one.

Starts the HTTP/3 example, then for each cipher suite runs the same requests straight at it and
through a UDP relay that drops a share of the datagrams each way, so that the handshake and the
streams have to recover. Needs `pip install aioquic`, and the example built:

    moon build src/examples/07-http3 --target native
    python scripts/http3/check_http3.py
"""
import asyncio
import os
import pathlib
import random
import ssl
import subprocess
import sys

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated
from aioquic.tls import CipherSuite

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
PORT = 12000
RELAY = 12100
LOSS = float(os.environ.get("HTTP3_LOSS", "0.05"))
SUITES = ["AES_128_GCM_SHA256", "AES_256_GCM_SHA384", "CHACHA20_POLY1305_SHA256"]


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = H3Connection(self._quic)
        self.waiting = {}

    def quic_event_received(self, event):
        if isinstance(event, ConnectionTerminated):
            for waiter in self.waiting.values():
                if not waiter["done"].done():
                    waiter["done"].set_exception(ConnectionError(event.reason_phrase))
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

    async def request(self, method, path, body=b""):
        stream = self._quic.get_next_available_stream_id()
        waiter = {"headers": [], "body": b"", "done": self._loop.create_future()}
        self.waiting[stream] = waiter
        self.h3.send_headers(
            stream,
            [
                (b":method", method.encode()),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", path.encode()),
            ],
            end_stream=not body,
        )
        if body:
            self.h3.send_data(stream, body, end_stream=True)
        self.transmit()
        await asyncio.wait_for(waiter["done"], 60)
        return dict(waiter["headers"]), waiter["body"]


class Relay(asyncio.DatagramProtocol):
    """Datagrams from the client to the server and back, a share of them lost."""

    def __init__(self, target, loss):
        self.target = target
        self.loss = loss
        self.client = None
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if random.random() < self.loss:
            return
        if addr == self.target:
            if self.client:
                self.transport.sendto(data, self.client)
        else:
            self.client = addr
            self.transport.sendto(data, self.target)


async def exercise(port, cipher):
    config = QuicConfiguration(
        is_client=True,
        alpn_protocols=H3_ALPN,
        verify_mode=ssl.CERT_NONE,
        cipher_suites=[CipherSuite[cipher]],
    )
    async with connect("127.0.0.1", port, configuration=config, create_protocol=Client) as client:
        headers, body = await client.request("GET", "/")
        assert headers[b":status"] == b"200" and body == b"3 GET / 0\n", body
        headers, body = await client.request("POST", "/count", b"y" * 100000)
        assert body == b"3 POST /count 100000\n", body
        headers, body = await client.request("HEAD", "/")
        assert headers[b":status"] == b"200" and body == b""
        headers, body = await client.request("GET", "/big")
        assert len(body) == 1048576, len(body)
        replies = await asyncio.gather(*[client.request("GET", f"/n{i}") for i in range(20)])
        paths = sorted(int(r[1].split()[2][2:]) for r in replies)
        assert paths == list(range(20)), paths


async def main():
    loop = asyncio.get_running_loop()
    relay, _ = await loop.create_datagram_endpoint(
        lambda: Relay(("127.0.0.1", PORT), LOSS),
        local_addr=("127.0.0.1", RELAY),
    )
    failed = 0
    try:
        for cipher in SUITES:
            for name, port in (("direct", PORT), (f"{LOSS:.0%} loss", RELAY)):
                try:
                    await asyncio.wait_for(exercise(port, cipher), 120)
                    print(f"ok   {cipher} {name}")
                except Exception as err:
                    failed += 1
                    print(f"FAIL {cipher} {name}: {err!r}")
    finally:
        relay.close()
    return failed


def binary():
    built = ROOT / "_build/native/debug/build/examples/07-http3"
    return next(p for p in built.iterdir() if p.name in ("37-http3", "37-http3.exe"))


server = subprocess.Popen([str(binary())], cwd=ROOT, stdout=subprocess.DEVNULL)
try:
    subprocess.run(
        [sys.executable, "-c", "import time; time.sleep(1)"],
        check=True,
    )
    sys.exit(1 if asyncio.run(main()) else 0)
finally:
    server.kill()
