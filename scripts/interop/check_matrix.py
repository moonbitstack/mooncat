"""The interoperability matrix, run against aioquic, an implementation that shares no code with this.

The cases are the ones the QUIC interoperability runner names, so that the table in the README says
what the runner would say. Two of them are transport-wide and answered where they live: this server
speaks QUIC version 1 only, and QUIC has no KeyUpdate (RFC 9001 §6) — both are recorded as rows the
transport decides, not the HTTP/3 layer.

Needs `pip install aioquic`, and the server built:

    moon build src/examples/16-interop-server --target native
    python scripts/interop/check_matrix.py

`scripts/interop/` also holds the image and the descriptor that the real runner needs, for a
machine with Docker; this script needs none.
"""
import asyncio
import contextlib
import os
import pathlib
import ssl
import struct
import subprocess
import sys
import time

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.events import ConnectionTerminated, HandshakeCompleted
from aioquic.tls import CipherSuite

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
HOST = "127.0.0.1"
PORT = int(os.environ.get("MOONCAT_PORT", "12040"))


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

    def start(self, method, path, body=b""):
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
        return waiter


def configuration(suite=None, ticket=None):
    config = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN, verify_mode=ssl.CERT_NONE
    )
    if suite is not None:
        config.cipher_suites = [CipherSuite[suite]]
    if ticket is not None:
        config.session_ticket = ticket
    return config


async def request(path="/", method="GET", body=b"", suite=None, ticket=None,
                  early=False, saved=None):
    """One connection, one request. Returns the status, the body, the ticket and the connection."""
    async with connect(
        HOST,
        PORT,
        configuration=configuration(suite, ticket),
        create_protocol=Client,
        session_ticket_handler=(saved.append if saved is not None else None),
        wait_connected=not early,
    ) as client:
        waiter = client.start(method, path, body)
        await asyncio.wait_for(waiter["done"], 60)
        return (
            dict(waiter["headers"]).get(b":status"),
            waiter["body"],
            client._quic,
        )


# ---------------------------------------------------------------- the cases


async def case_handshake():
    status, _, quic = await request("/")
    assert status == b"200", status
    assert quic.tls.alpn_negotiated == "h3", quic.tls.alpn_negotiated
    return "200, ALPN h3"


async def case_transfer():
    up = os.urandom(65536)
    status, body, _ = await request("/65536", "POST", up)
    assert status == b"200" and body == b"received 65536 bytes\n", (status, body)
    status, body, _ = await request("/1048576")
    assert status == b"200" and len(body) == 1048576, (status, len(body))
    return "64 KiB up, 1 MiB down"


async def case_resumption():
    saved = []
    await request("/", saved=saved)
    assert saved, "the server issued no ticket"
    status, _, quic = await request("/", ticket=saved[0])
    assert status == b"200", status
    assert quic.tls.session_resumed, "the second handshake did not resume"
    return "ticket taken, resumed"


async def case_zerortt():
    saved = []
    await request("/", saved=saved)
    assert saved and saved[0].max_early_data_size, "the ticket allows no early data"
    status, _, quic = await request("/", ticket=saved[0], early=True)
    assert status == b"200", status
    assert quic.tls.early_data_accepted, "the server took no early data"
    return "early data accepted"


async def case_chacha20():
    # One suite offered: a handshake that finishes has settled on it, or on nothing at all.
    status, _, quic = await request("/", suite="CHACHA20_POLY1305_SHA256")
    assert status == b"200", status
    assert quic.tls.alpn_negotiated == "h3"
    return "ChaCha20-Poly1305 only"


async def case_migration():
    """The same connection, carried by a socket that did not start it: NAT rebinding."""
    from aioquic.h3.connection import H3Connection as H3

    queues = {}

    class Raw(asyncio.DatagramProtocol):
        def __init__(self, name):
            self.name = name

        def connection_made(self, transport):
            self.transport = transport
            queues[self.name] = (transport, asyncio.Queue())

        def datagram_received(self, data, addr):
            queues[self.name][1].put_nowait((data, addr))

    loop = asyncio.get_running_loop()
    transport_a, _ = await loop.create_datagram_endpoint(
        lambda: Raw("a"), local_addr=(HOST, 0)
    )
    transport_b, _ = await loop.create_datagram_endpoint(
        lambda: Raw("b"), local_addr=(HOST, 0)
    )
    conn = QuicConnection(configuration=configuration())
    h3 = H3(conn)
    conn.connect((HOST, PORT), time.monotonic())

    def pump(transport):
        for data, addr in conn.datagrams_to_send(time.monotonic()):
            transport.sendto(data, addr)

    def drain(name):
        for data, addr in list(queues[name][1]._queue):
            conn.receive_datagram(data, addr, time.monotonic())
            queues[name][1].get_nowait()

    deadline = time.monotonic() + 30
    connected = False

    def settled():
        nonlocal connected
        for event in iter(conn.next_event, None):
            if isinstance(event, HandshakeCompleted):
                connected = True

    pump(transport_a)
    while not connected and time.monotonic() < deadline:
        await asyncio.sleep(0.005)
        drain("a")
        settled()
        pump(transport_a)
    assert connected, "the handshake did not finish"

    # A new socket, a new source port, the same connection: what a phone does when it moves from
    # Wi-Fi to cellular, and what a server has to accept (RFC 9000 §9).
    stream = conn.get_next_available_stream_id()
    h3.send_headers(
        stream,
        [
            (b":method", b"GET"),
            (b":scheme", b"https"),
            (b":authority", b"localhost"),
            (b":path", b"/128"),
        ],
        end_stream=True,
    )
    answered = b""
    state = {"status": None}

    def take():
        nonlocal answered
        for event in iter(conn.next_event, None):
            for h3_event in h3.handle_event(event):
                if getattr(h3_event, "stream_id", None) != stream:
                    continue
                if isinstance(h3_event, HeadersReceived):
                    state["status"] = dict(h3_event.headers).get(b":status")
                elif isinstance(h3_event, DataReceived):
                    answered += h3_event.data

    pump(transport_b)
    while time.monotonic() < deadline and len(answered) < 128:
        await asyncio.sleep(0.005)
        drain("b")
        take()
        pump(transport_b)
    transport_a.close()
    transport_b.close()
    assert state["status"] == b"200", state["status"]
    assert len(answered) == 128, len(answered)
    return "answered to the new address"


# ------------------------------------------------------- what the transport decides


def raw_exchange(payload):
    """One datagram to the server on a plain socket, and whatever comes back."""
    import socket

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    try:
        sock.sendto(payload, (HOST, PORT))
        data, _ = sock.recvfrom(2048)
        return data
    finally:
        sock.close()


def initial(version, dcid, scid):
    """A client's first datagram, shaped well enough to be read and not decrypted."""
    body = struct.pack("!I", version) + bytes([len(dcid)]) + dcid
    body += bytes([len(scid)]) + scid + b"\x00"
    datagram = b"\xc0" + body
    return datagram + b"\x00" * (1200 - len(datagram))


def case_retry():
    """With Retry on, a first Initial that proved nothing is answered with one (RFC 9000 §8.1.2)."""
    answer = raw_exchange(initial(1, b"\x01" * 8, b"\x02" * 8))
    assert (answer[0] & 0xF0) == 0xF0, f"not a Retry: {answer[:8]!r}"
    return "Retry answered; handshake completes after it"


def case_v2():
    """QUIC version 2 is the transport's to add; this one answers with its own version list."""
    answer = raw_exchange(initial(0x6B3343CF, b"\x03" * 8, b"\x04" * 8))
    assert answer[0] & 0x80, f"not a long header: {answer[:8]!r}"
    version = struct.unpack("!I", answer[1:5])[0]
    assert version == 0, "not a Version Negotiation"
    at = 5
    at += 1 + answer[at]
    at += 1 + answer[at]
    offered = [
        struct.unpack("!I", answer[i : i + 4])[0]
        for i in range(at, len(answer) - 3, 4)
    ]
    assert offered == [1], offered
    return "v1 only, offered as such"


CASES = [
    ("handshake", case_handshake, True),
    ("transfer", case_transfer, True),
    ("retry", case_retry, False),
    ("resumption", case_resumption, True),
    ("zerortt", case_zerortt, True),
    ("chacha20", case_chacha20, True),
    ("keyupdate", None, False),
    ("v2", case_v2, False),
    ("migration", case_migration, True),
]


def binary():
    built = ROOT / "_build/native/debug/build/examples/16-interop-server"
    return next(
        p for p in built.iterdir() if p.name in ("16-interop-server", "16-interop-server.exe")
    )


@contextlib.contextmanager
def server(retry):
    """The interop server, with Retry on or off.

    Retry and 0-RTT are mutually exclusive by design: a client that is sent a Retry must not send
    early data under a token it has not been given yet (RFC 9000 §8.1), so the case that proves
    Retry cannot also be the case that proves 0-RTT.
    """
    process = subprocess.Popen(
        [str(binary())],
        cwd=ROOT,
        env=dict(
            os.environ,
            MOONCAT_PORT=str(PORT),
            MOONCAT_RETRY="1" if retry else "0",
        ),
        stdout=subprocess.DEVNULL,
    )
    try:
        started = time.time()
        while time.time() - started < 20:
            try:
                if asyncio.run(request("/"))[0] == b"200":
                    break
            except Exception:
                time.sleep(0.25)
        else:
            raise SystemExit(f"the server did not come up on {PORT}")
        yield
    finally:
        process.kill()
        process.wait()


def main():
    failures = 0
    phases = [(True, ["retry"]), (False, [name for name, _, _ in CASES if name != "retry"])]
    for retry, names in phases:
        with server(retry):
            for name, case, _ in CASES:
                if name not in names:
                    continue
                if case is None:
                    print(f"n/a  {name}: a KeyUpdate is an error in QUIC (RFC 9001 §6)")
                    continue
                try:
                    answer = case()
                    if asyncio.iscoroutine(answer):
                        answer = asyncio.run(answer)
                    print(f"ok   {name}: {answer}")
                except Exception as err:  # noqa: BLE001 - the failure is the result here
                    failures += 1
                    print(f"FAIL {name}: {err!r}")
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
