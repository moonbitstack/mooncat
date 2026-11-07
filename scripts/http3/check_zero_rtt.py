"""HTTP over 0-RTT against aioquic, an implementation that shares no code with this one.

RFC 8470 in three runs of the same question: a request sent with the handshake is answered with the
application told it arrived early; a server that refuses it answers `425 Too Early` and the client
sends it again; a server that offers no early data has a client that waits for the handshake.

Needs `pip install aioquic`, and the example built:

    moon build src/examples/15-early-data --target native
    python scripts/http3/check_zero_rtt.py
"""
import asyncio
import contextlib
import os
import pathlib
import ssl
import subprocess
import sys
import time

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
HOST = "127.0.0.1"
PORT = int(os.environ.get("MOONCAT_PORT", "12030"))


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

    def start(self, path="/"):
        stream = self._quic.get_next_available_stream_id()
        waiter = {"headers": [], "body": b"", "done": self._loop.create_future()}
        self.waiting[stream] = waiter
        self.h3.send_headers(
            stream,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", path.encode()),
            ],
            end_stream=True,
        )
        self.transmit()
        return waiter


async def fetch(port, path="/", ticket=None, early=False):
    """One connection, one request: in 0-RTT when `early`, after the handshake otherwise."""
    saved = []
    config = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN, verify_mode=ssl.CERT_NONE
    )
    if ticket is not None:
        config.session_ticket = ticket
    async with connect(
        HOST,
        port,
        configuration=config,
        create_protocol=Client,
        session_ticket_handler=saved.append,
        wait_connected=not early,
    ) as client:
        waiter = client.start(path)
        await asyncio.wait_for(waiter["done"], 20)
        status = dict(waiter["headers"]).get(b":status")
        return status, waiter["body"], saved[0] if saved else None


def count_of(body):
    """The request count the example reports, `early N after M` or `M`."""
    return int(body.decode().strip().split()[-1])


@contextlib.contextmanager
def server(policy):
    """The example under `policy`, and how many requests it had answered when it came up."""
    binary = (
        ROOT / "_build/native/debug/build/examples/15-early-data/15-early-data.exe"
    )
    if not binary.exists():
        binary = binary.with_suffix("")
    if not binary.exists():
        raise SystemExit("build the example first: moon build src/examples/15-early-data")
    env = dict(os.environ, MOONCAT_EARLY=policy, MOONCAT_PORT=str(PORT))
    process = subprocess.Popen(
        [str(binary)], cwd=ROOT, env=env, stdout=subprocess.DEVNULL
    )
    try:
        # A server that binds its QUIC socket a moment after its TCP one would otherwise fail the
        # first attempt for the wrong reason, so this waits for an answer, not for a clock.
        for _ in range(40):
            try:
                status, body, _ = asyncio.run(fetch(PORT))
                if status == b"200":
                    break
                time.sleep(0.25)
            except Exception:
                time.sleep(0.25)
        else:
            raise SystemExit(f"the {policy} server did not come up on {PORT}")
        yield count_of(body)
    finally:
        process.kill()
        process.wait()


def main():
    failures = 0

    def check(name, got, want):
        nonlocal failures
        if got == want:
            print(f"ok   {name}: {got!r}")
        else:
            failures += 1
            print(f"FAIL {name}: wanted {want!r}, got {got!r}")

    with server("accept") as base:
        status, body, ticket = asyncio.run(fetch(PORT))
        check(
            "accept, full handshake",
            (status, body),
            (b"200", f"early 0 after {base + 1}\n".encode()),
        )
        check("accept, a ticket is issued", ticket is not None, True)
        # The second request travels with the handshake, so the application is told it is early.
        status, body, _ = asyncio.run(fetch(PORT, ticket=ticket, early=True))
        check(
            "accept, 0-RTT",
            (status, body),
            (b"200", f"early 1 after {base + 2}\n".encode()),
        )

    with server("refuse") as base:
        _, _, ticket = asyncio.run(fetch(PORT))
        status, body, _ = asyncio.run(fetch(PORT, ticket=ticket, early=True))
        check("refuse, 0-RTT", (status, body), (b"425", b""))
        # RFC 8470 §4: 425 means "the request was not processed", so asking again after the
        # handshake is the same question and must be answered. The application ran once, for this.
        status, body, _ = asyncio.run(fetch(PORT, ticket=ticket))
        check(
            "refuse, then after the handshake",
            (status, body),
            (b"200", f"early 0 after {base + 2}\n".encode()),
        )

    with server("off") as base:
        _, _, ticket = asyncio.run(fetch(PORT))
        offered = ticket.max_early_data_size if ticket else 0
        check("off, no allowance in the ticket", offered or 0, 0)
        status, body, _ = asyncio.run(fetch(PORT, ticket=ticket))
        check(
            "off, a plain resumption",
            (status, body),
            (b"200", f"early 0 after {base + 2}\n".encode()),
        )

    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
