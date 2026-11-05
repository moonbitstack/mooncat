"""QUIC against aioquic, an implementation that shares no code with this one, in both directions.

Our server takes a ticket-carrying client, 0-RTT, a port change and a key update from aioquic. Our
client then does a handshake, a stream, a key update and a resumption with 0-RTT against an aioquic
server. Each is a thing that passed in-process and still failed against a real peer. Needs
`pip install aioquic`, openssl, and the examples built:

    moon build src/examples/12-quic-echo src/examples/13-quic-client --target native
    python scripts/quic/check_interop.py
"""
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

from aioquic.buffer import Buffer
from aioquic.quic import events
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.packet import pull_quic_header

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
OURS = ("127.0.0.1", 12110)
THEIRS = ("127.0.0.1", 12111)
ALPN = ["echo"]


def example(name):
    built = ROOT / "_build/native/debug/build"
    return next(p for p in built.rglob(f"examples/{name}/*") if p.name in (name, name + ".exe"))


def pump(conn, sock, until, seconds=5):
    deadline = time.time() + seconds
    got = {"data": b"", "done": None}
    while time.time() < deadline and not until(got):
        for data, addr in conn.datagrams_to_send(now=time.time()):
            sock.sendto(data, addr)
        try:
            data, addr = sock.recvfrom(65536)
            conn.receive_datagram(data, addr, now=time.time())
        except socket.timeout:
            conn.handle_timer(now=time.time())
        except ConnectionResetError:
            pass
        while (ev := conn.next_event()) is not None:
            if isinstance(ev, events.StreamDataReceived):
                got["data"] += ev.data
            elif isinstance(ev, events.HandshakeCompleted):
                got["done"] = ev
            elif isinstance(ev, events.ConnectionTerminated):
                raise AssertionError(f"closed: {ev.error_code} {ev.reason_phrase!r}")
    return got


def udp():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.05)
    return sock


def client(ticket=None, tickets=None):
    config = QuicConfiguration(is_client=True, alpn_protocols=ALPN, verify_mode=ssl.CERT_NONE, session_ticket=ticket)
    conn = QuicConnection(configuration=config, session_ticket_handler=tickets.append if tickets is not None else None)
    conn.connect(OURS, now=time.time())
    return conn


def against_our_server():
    tickets = []
    conn = client(tickets=tickets)
    sock = udp()
    stream = conn.get_next_available_stream_id()
    conn.send_stream_data(stream, b"on the first port", end_stream=True)
    got = pump(conn, sock, lambda g: g["data"] == b"ON THE FIRST PORT" and tickets)
    assert got["data"] == b"ON THE FIRST PORT", got
    assert tickets, "our server issued no ticket"
    assert tickets[0].max_early_data_size == 0xffffffff, tickets[0].max_early_data_size
    print("ours: a stream and a ticket")

    # The client's port changes, as a NAT rebinding would change it. The old socket is gone.
    sock.close()
    sock = udp()
    stream = conn.get_next_available_stream_id()
    conn.send_stream_data(stream, b"on the second port", end_stream=True)
    got = pump(conn, sock, lambda g: g["data"] == b"ON THE SECOND PORT")
    assert got["data"] == b"ON THE SECOND PORT", got
    print("ours: followed a port change")

    # On purpose this time: a new id as well as a new port, which needs a spare from the server.
    sock.close()
    sock = udp()
    conn.change_connection_id()
    stream = conn.get_next_available_stream_id()
    conn.send_stream_data(stream, b"on a new id", end_stream=True)
    got = pump(conn, sock, lambda g: g["data"] == b"ON A NEW ID")
    assert got["data"] == b"ON A NEW ID", got
    print("ours: followed a new connection id")

    conn.request_key_update()
    stream = conn.get_next_available_stream_id()
    conn.send_stream_data(stream, b"after the update", end_stream=True)
    got = pump(conn, sock, lambda g: g["data"] == b"AFTER THE UPDATE")
    assert got["data"] == b"AFTER THE UPDATE", got
    print("ours: followed a key update")
    conn.close()
    for data, addr in conn.datagrams_to_send(now=time.time()):
        sock.sendto(data, addr)
    sock.close()

    conn = client(ticket=tickets[0])
    sock = udp()
    stream = conn.get_next_available_stream_id()
    conn.send_stream_data(stream, b"early data", end_stream=True)
    got = pump(conn, sock, lambda g: g["data"] == b"EARLY DATA" and g["done"])
    assert got["data"] == b"EARLY DATA", got
    assert got["done"].session_resumed, "not resumed"
    assert got["done"].early_data_accepted, "0-RTT declined"
    print("ours: resumed, and took 0-RTT")
    sock.close()


def their_server(cert, key, stop, seen):
    tickets = {}
    config = QuicConfiguration(is_client=False, alpn_protocols=ALPN)
    config.load_cert_chain(cert, key)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(THEIRS)
    sock.settimeout(0.02)
    conns = {}
    while not stop.is_set():
        try:
            data, addr = sock.recvfrom(65536)
            header = pull_quic_header(Buffer(data=data), host_cid_length=8)
            conn = conns.get(header.destination_cid)
            if conn is None:
                conn = QuicConnection(
                    configuration=config,
                    original_destination_connection_id=header.destination_cid,
                    session_ticket_fetcher=tickets.get,
                    session_ticket_handler=lambda t: tickets.__setitem__(t.ticket, t),
                )
                conns[header.destination_cid] = conn
                conns[conn.host_cid] = conn
            conn.receive_datagram(data, addr, now=time.time())
        except (socket.timeout, ConnectionResetError):
            pass
        for conn in set(conns.values()):
            timer = conn.get_timer()
            if timer is not None and timer < time.time():
                conn.handle_timer(now=time.time())
            while (ev := conn.next_event()) is not None:
                if isinstance(ev, events.StreamDataReceived):
                    if not conn._handshake_complete:
                        seen.append(ev.data)
                    conn.send_stream_data(ev.stream_id, ev.data.upper(), end_stream=ev.end_stream)
                elif isinstance(ev, events.ConnectionIdIssued):
                    conns[ev.connection_id] = conn
            for out, to in conn.datagrams_to_send(now=time.time()):
                sock.sendto(out, to)
    sock.close()


def against_their_server(cert, key):
    stop = threading.Event()
    seen = []
    server = threading.Thread(target=their_server, args=(cert, key, stop, seen))
    server.start()
    try:
        out = subprocess.run([str(example("13-quic-client")), f"{THEIRS[0]}:{THEIRS[1]}"], capture_output=True, text=True, timeout=60).stdout
    finally:
        stop.set()
        server.join()
    print(out, end="")
    for want in ["connected true", "stream FIRST", "ticket true", "updated true", "stream after update SECOND", "0-RTT queued true", "early reply EARLY", "early accepted true"]:
        assert want in out, f"our client: no `{want}`"
    assert seen == [b"early"], ("the server did not read it before the handshake finished", seen)
    print("theirs: read 0-RTT from our client before the handshake finished")


with tempfile.TemporaryDirectory() as tmp:
    cert, key = f"{tmp}/cert.pem", f"{tmp}/key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
    ours = subprocess.Popen([str(example("12-quic-echo")), cert, key, f"{OURS[0]}:{OURS[1]}"], stdout=subprocess.DEVNULL)
    time.sleep(1)
    try:
        against_our_server()
        assert ours.poll() is None, "our server stopped when a client left"
    finally:
        ours.kill()
    against_their_server(cert, key)
print("ok")
sys.exit(0)
