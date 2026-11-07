"""One process, many QUIC connections.

Three shapes of the same question, because each has failed somewhere before: a hundred connections
one after another, fifty at once, and one that stays open while the rest come and go. Every
connection asks for `/` and every answer has to arrive.

Needs `pip install aioquic`, and the example built:

    moon build src/examples/07-http3 --target native
    python scripts/http3/check_connections.py
"""
import asyncio
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
PORT = int(os.environ.get("MOONCAT_PORT", "12000"))
SEQUENTIAL = int(os.environ.get("MOONCAT_SEQUENTIAL", "100"))
CONCURRENT = int(os.environ.get("MOONCAT_CONCURRENT", "20"))


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

    async def request(self, path="/"):
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
        await asyncio.wait_for(waiter["done"], 30)
        return dict(waiter["headers"]).get(b":status"), waiter["body"]


async def one():
    """One connection, one request: the answer's status, or the reason there is none."""
    config = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN, verify_mode=ssl.CERT_NONE
    )
    try:
        async with connect(
            HOST, PORT, configuration=config, create_protocol=Client
        ) as client:
            status, _ = await client.request()
            return status
    except Exception as err:  # noqa: BLE001 - the failure is the result here
        return repr(err)


async def sequential(times):
    return [await one() for _ in range(times)]


async def concurrent(times):
    return await asyncio.gather(*[one() for _ in range(times)])


async def alongside_an_open_one(times):
    """A held connection asking throughout: a server keyed by one connection would fail here."""
    config = QuicConfiguration(
        is_client=True, alpn_protocols=H3_ALPN, verify_mode=ssl.CERT_NONE
    )
    async with connect(
        HOST, PORT, configuration=config, create_protocol=Client
    ) as held:
        answers = [await held.request("/before")]
        # Asked in the middle of the burst, not after it: a connection left idle long enough is
        # dropped by its own idle timer, and that is not the question here.
        batch = asyncio.gather(*[one() for _ in range(times)])
        for i in range(3):
            answers.append(await held.request(f"/during{i}"))
        answers += await batch
        answers.append(await held.request("/after"))
        return [answer[0] if isinstance(answer, tuple) else answer for answer in answers]


def binary():
    built = ROOT / "_build/native/debug/build/examples/07-http3"
    return next(p for p in built.iterdir() if p.name in ("07-http3", "07-http3.exe"))


def main():
    server = subprocess.Popen(
        [str(binary())],
        cwd=ROOT,
        env=dict(os.environ, MOONCAT_PORT=str(PORT)),
        stdout=subprocess.DEVNULL,
    )
    failures = 0
    try:
        started = time.time()
        while True:
            if asyncio.run(one()) == b"200":
                break
            if time.time() - started > 20:
                print("the server did not come up")
                return 1
            time.sleep(0.25)

        for name, answers in (
            (f"{SEQUENTIAL} one after another", asyncio.run(sequential(SEQUENTIAL))),
            (f"{CONCURRENT} at once", asyncio.run(concurrent(CONCURRENT))),
            (
                f"{CONCURRENT} beside one held open",
                asyncio.run(alongside_an_open_one(CONCURRENT)),
            ),
        ):
            bad = [answer for answer in answers if answer != b"200"]
            if bad:
                failures += 1
                print(f"FAIL {name}: {len(bad)} of {len(answers)} unanswered, e.g. {bad[0]!r}")
            else:
                print(f"ok   {name}: {len(answers)} answers")
    finally:
        server.kill()
        server.wait()
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
