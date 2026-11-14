"""An event stream's head reaches the client before its first event. The example sends its head
and waits two seconds for the first event; each client must hold the head within one second, and
the first event only after that wait. Needs httpx, curl and the example built:

    moon build src/examples/17-event-stream --target native
    python scripts/checks/check_event_stream.py
"""
import pathlib
import socket
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
URL = "http://127.0.0.1:12000/events"
HEAD_WITHIN = 1.0
FIRST_AFTER = 1.5


def started(server):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            socket.create_connection(("127.0.0.1", 12000), timeout=1).close()
            return
        except OSError:
            if server.poll() is not None:
                raise SystemExit("the example exited before it listened")
            time.sleep(0.1)
    raise SystemExit("the example did not listen within ten seconds")


def judge(name, head_at, first_at):
    assert head_at is not None and head_at < HEAD_WITHIN, f"{name}: head after {head_at}s"
    assert first_at is not None and first_at >= FIRST_AFTER, f"{name}: first event at {first_at}s"
    print(f"{name}: head at {head_at:.2f}s, first event at {first_at:.2f}s")


def raw():
    begin = time.monotonic()
    head_at = first_at = None
    seen = b""
    with socket.create_connection(("127.0.0.1", 12000), timeout=10) as s:
        s.sendall(b"GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        while first_at is None:
            piece = s.recv(4096)
            if not piece:
                break
            seen += piece
            if head_at is None and b"\r\n\r\n" in seen:
                head_at = time.monotonic() - begin
            if b"data: one" in seen:
                first_at = time.monotonic() - begin
    judge("socket, HTTP/1.1", head_at, first_at)


def httpx_stream():
    import httpx

    begin = time.monotonic()
    with httpx.stream("GET", URL, timeout=10) as r:
        # `stream` returns once the head is in; the body is still to come.
        head_at = time.monotonic() - begin
        assert r.status_code == 200 and r.headers["content-type"] == "text/event-stream"
        first_at = None
        for line in r.iter_lines():
            if line == "data: one":
                first_at = time.monotonic() - begin
                break
    judge("httpx, HTTP/1.1", head_at, first_at)


def curl(*flags):
    begin = time.monotonic()
    head_at = first_at = None
    run = subprocess.Popen(["curl", "-sS", "--no-buffer", "-D", "-", *flags, URL], stdout=subprocess.PIPE)
    assert run.stdout is not None
    try:
        for line in run.stdout:
            if head_at is None and line.startswith(b"HTTP/"):
                head_at = time.monotonic() - begin
            if line.startswith(b"data: one"):
                first_at = time.monotonic() - begin
                break
    finally:
        run.kill()
        run.wait()
    judge("curl " + (" ".join(flags) or "HTTP/1.1"), head_at, first_at)


if __name__ == "__main__":
    built = ROOT / "_build/native/debug/build"
    binary = next(p for p in built.rglob("examples/17-event-stream/*") if p.name in ("17-event-stream", "17-event-stream.exe"))
    server = subprocess.Popen([str(binary)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        started(server)
        raw()
        httpx_stream()
        curl()
        curl("--http2-prior-knowledge")
    finally:
        server.kill()
    print("ok")
