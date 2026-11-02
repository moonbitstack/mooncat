"""HTTP/3 under several workers, with real processes and aioquic, on Linux: connections spread
across the workers, every request of one connection is answered by the same worker, a killed
worker is replaced and HTTP/3 goes on, and a stopped supervisor takes the port with it.

    moon build --target native
    pip install aioquic
    python scripts/checks/check_workers_http3.py
"""
import asyncio
import os
import pathlib
import signal
import ssl
import subprocess
import sys
import time

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SERVER = ROOT / "_build/native/debug/build/examples/08-workers/08-workers.exe"
PORT = 18991
WORKERS = 3
failed = False


def say(ok, name, detail=""):
    global failed
    failed = failed or not ok
    print("%-4s %-52s %s" % ("ok" if ok else "FAIL", name, detail), flush=True)


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = H3Connection(self._quic)
        self.waiting = {}

    def quic_event_received(self, event):
        for e in self.h3.handle_event(event):
            waiter = self.waiting.get(getattr(e, "stream_id", None))
            if waiter is None:
                continue
            if isinstance(e, DataReceived):
                waiter["body"] += e.data
            if getattr(e, "stream_ended", False) and not waiter["done"].done():
                waiter["done"].set_result(None)

    async def get(self, path="/"):
        stream = self._quic.get_next_available_stream_id()
        waiter = {"body": b"", "done": self._loop.create_future()}
        self.waiting[stream] = waiter
        self.h3.send_headers(stream, [(b":method", b"GET"), (b":scheme", b"https"),
                                      (b":authority", b"127.0.0.1:%d" % PORT), (b":path", path.encode())],
                             end_stream=True)
        self.transmit()
        await waiter["done"]
        return waiter["body"].decode().strip()


async def session(requests=1, timeout=5.0):
    """One QUIC connection making `requests` requests; the answers, or None if it failed."""
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE
    try:
        async with connect("127.0.0.1", PORT, configuration=config, create_protocol=Client) as client:
            return [await asyncio.wait_for(client.get(), timeout) for _ in range(requests)]
    except Exception:
        return None


def ask(requests=1, timeout=5.0):
    try:
        return asyncio.run(asyncio.wait_for(session(requests, timeout), timeout + 2))
    except (asyncio.TimeoutError, OSError):
        return None


def children(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()]


def main():
    if not SERVER.exists():
        print("build first: moon build --target native")
        return 2
    server = subprocess.Popen([str(SERVER), "--workers", str(WORKERS), "--port", str(PORT), "--http3",
                               "--ssl-certfile", "src/certs/cert.pem", "--ssl-keyfile", "src/certs/key.pem",
                               "--log-level", os.environ.get("LOG_LEVEL", "warning")], cwd=ROOT)
    try:
        for _ in range(50):
            if ask(timeout=1.0):
                break
            time.sleep(0.2)
        say(len(children(server.pid)) == WORKERS, "three workers run", str(len(children(server.pid))))

        answers = [ask() for _ in range(30)]
        served = [a[0] for a in answers if a]
        say(len(served) == 30, "thirty HTTP/3 connections answered", "%d of 30" % len(served))
        seen = sorted(set(served))
        say(len(seen) >= 2, "connections spread across workers", ", ".join(seen))
        say("alone" not in seen, "the supervisor serves nothing")

        many = ask(requests=12)
        say(bool(many) and len(set(many)) == 1, "one connection stays with one worker",
            ", ".join(sorted(set(many or []))))

        victim = children(server.pid)[0]
        os.kill(victim, signal.SIGKILL)
        time.sleep(1.5)
        after = children(server.pid)
        say(len(after) == WORKERS and victim not in after, "a killed worker is replaced", str(after))
        answers = [ask() for _ in range(12)]
        say(all(answers), "HTTP/3 goes on after the replacement", "%d of 12" % sum(1 for a in answers if a))

        workers = children(server.pid)
        server.send_signal(signal.SIGTERM)
        try:
            server.wait(timeout=15)
            say(True, "the supervisor stops on SIGTERM")
        except subprocess.TimeoutExpired:
            say(False, "the supervisor stops on SIGTERM")
        left = [w for w in workers if os.path.exists("/proc/%d" % w)]
        say(not left, "every worker stops with it", str(left))
        say(ask(timeout=1.0) is None, "the port is closed")
    finally:
        if server.poll() is None:
            server.kill()
        for w in children(server.pid):
            os.kill(w, signal.SIGKILL)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
