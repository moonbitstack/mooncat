"""TLS 1.3 session resumption with the default configuration, with Python's ssl as the client: the
first connection gets a ticket, the second uses it. Needs openssl and the example built:

    moon build src/examples/14-http2-server --target native
    python scripts/checks/check_tls_resume.py
"""
import pathlib
import socket
import ssl
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
built = ROOT / "_build/native/debug/build"
server = next(p for p in built.rglob("examples/14-http2-server/*") if p.name in ("14-http2-server", "14-http2-server.exe"))

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.set_alpn_protocols(["http/1.1"])


def fetch(session=None):
    with socket.create_connection(("127.0.0.1", 12000), timeout=5) as raw:
        with ctx.wrap_socket(raw, server_hostname="localhost", session=session) as s:
            s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            head = s.recv(4096)
            # The tickets come after the handshake, so they arrive with the answer or just behind it.
            try:
                while s.recv(4096):
                    pass
            except ssl.SSLError:
                pass
            assert head.startswith(b"HTTP/1.1 200"), head[:40]
            return s.session, s.session_reused


with tempfile.TemporaryDirectory() as tmp:
    cert, key = f"{tmp}/cert.pem", f"{tmp}/key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                    "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost"], check=True, capture_output=True)
    running = subprocess.Popen([str(server), cert, key], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    try:
        ticket, reused = fetch()
        assert not reused, "the first connection cannot be a resumption"
        assert ticket is not None and ticket.has_ticket, "no ticket with the default configuration"
        _, reused = fetch(ticket)
        assert reused, "the ticket was not honoured"
    finally:
        running.kill()
print("ok")
