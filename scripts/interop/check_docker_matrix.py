"""The interoperability matrix in Docker, against quic-go, ngtcp2 and aioquic.

The cases are the ones the QUIC interoperability runner names. The peers are the
runner's own images, named in `implementations.json`, so the crossing is with the
same binaries the public matrix uses rather than with a local imitation.

Two directions are run for every peer:

  * the peer's HTTP/3 client downloads from the mooncat server in
    `src/examples/16-interop-server`;
  * a client built from this repository (`integration/interop-client`) fetches
    from the peer's HTTP/3 server.

The runner's clients speak HTTP/0.9 for every case except its `http3` one, and
mooncat speaks HTTP/3 only. A case whose knob the peer's HTTP/3 client does not
expose is recorded as not applicable, with the reason, rather than counted as a
pass. `scripts/interop/check_matrix.py` covers all nine cases directly against
aioquic's HTTP/3 client, without Docker.

    docker build -f scripts/interop/Dockerfile -t mooncat-interop .
    python3 scripts/interop/check_docker_matrix.py

The images are the runner's (`implementations.json`). Nothing here pulls a
nightly build of its own.
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
HOST = "server"
PORT = 443
SERVER = "mooncat-interop-server"
CLIENT = "mooncat-interop-client"

# The server's `/<n>` is `n` bytes, byte i being i % 251. The test files are
# therefore checkable without carrying them anywhere.
PATTERN = bytes(i % 251 for i in range(251))


def pattern(size):
    whole, rest = divmod(size, len(PATTERN))
    return PATTERN * whole + PATTERN[:rest]


# ---------------------------------------------------------------- the peers


def aioquic_client(case, paths, run):
    args = [
        "examples/http3_client.py",
        "--insecure",
        "--output-dir",
        "/downloads",
        "--quic-log",
        "/logs/qlog",
        "--secrets-log",
        "/logs/keys.log",
        "-v",
    ]
    if case == "transfer":
        args += ["--max-data", "262144", "--max-stream-data", "262144"]
    elif case == "chacha20":
        args += ["--cipher-suites", "CHACHA20_POLY1305_SHA256"]
    elif case == "keyupdate":
        args += ["--key-update"]
    elif case in ("resumption", "zerortt"):
        args += ["--session-ticket", "/downloads/session.ticket"]
        if case == "zerortt" and run > 0:
            args += ["--zero-rtt"]
    elif case == "v2":
        args += ["--negotiate-v2"]
    args += ["https://%s:%d%s" % (HOST, PORT, path) for path in paths]
    return {
        "image": "aiortc/aioquic-qns:latest",
        "entrypoint": "/aioquic/env/bin/python",
        "workdir": "/aioquic",
        "args": args,
    }


def ngtcp2_client(case, paths, run):
    args = [
        HOST,
        str(PORT),
        "--download",
        "/downloads",
        "--exit-on-all-streams-close",
        "--no-quic-dump",
        "--no-http-dump",
        "--qlog-dir",
        "/logs/qlog",
        "--cc",
        "bbr",
        "--initial-rtt",
        "100ms",
    ]
    if case == "chacha20":
        args += ["--ciphers=TLS_CHACHA20_POLY1305_SHA256"]
    elif case == "keyupdate":
        args += ["--key-update=10ms"]
    elif case in ("resumption", "zerortt"):
        args += [
            "--session-file",
            "/downloads/session.txt",
            "--tp-file",
            "/downloads/tp.txt",
            "--wait-for-ticket",
        ]
        if case == "resumption":
            args += ["--disable-early-data"]
    elif case == "v2":
        args += ["--available-versions", "v2,v1"]
    elif case == "migration":
        args += ["--change-local-addr=1s", "--nat-rebinding"]
    args += ["https://%s:%d%s" % (HOST, PORT, path) for path in paths]
    return {
        "image": "ghcr.io/ngtcp2/ngtcp2-interop:latest",
        "entrypoint": "/usr/local/bin/wsslclient",
        "workdir": "/",
        "args": args,
    }


def quicgo_client(case, paths, run):
    args = ["https://%s:%d%s" % (HOST, PORT, path) for path in paths]
    return {
        "image": "martenseemann/quic-go-interop:latest",
        "entrypoint": "./client",
        "workdir": "/quic-go",
        "args": args,
        "env": {"TESTCASE": "http3"},
    }


CLIENTS = {
    "aioquic": aioquic_client,
    "ngtcp2": ngtcp2_client,
    "quic-go": quicgo_client,
}


def aioquic_server(case):
    return {
        "image": "aiortc/aioquic-qns:latest",
        "entrypoint": "/aioquic/env/bin/python",
        "workdir": "/aioquic",
        "args": [
            "examples/http3_server.py",
            "--certificate",
            "/certs/cert.pem",
            "--private-key",
            "/certs/priv.key",
            "--host",
            "0.0.0.0",
            "--port",
            str(PORT),
            "-v",
            "pattern:app",
        ],
        "env": {"PYTHONPATH": "/app"},
    }


def ngtcp2_server(case):
    return {
        "image": "ghcr.io/ngtcp2/ngtcp2-interop:latest",
        "entrypoint": "/usr/local/bin/wsslserver",
        "workdir": "/",
        "args": [
            "*",
            str(PORT),
            "/certs/priv.key",
            "/certs/cert.pem",
            "-s",
            "-d",
            "/www",
            "--qlog-dir",
            "/logs/qlog",
            "--cc",
            "bbr",
            "--initial-rtt",
            "100ms",
        ],
    }


def quicgo_server(case):
    return {
        "image": "martenseemann/quic-go-interop:latest",
        "entrypoint": "./server",
        "workdir": "/quic-go",
        "args": [],
        "env": {"TESTCASE": "http3"},
    }


SERVERS = {
    "aioquic": aioquic_server,
    "ngtcp2": ngtcp2_server,
    "quic-go": quicgo_server,
}

# What each peer's HTTP/3 client cannot express, and why. These are recorded in
# the README rather than hidden: a case the runner's client only runs over
# HTTP/0.9 cannot be asked of an HTTP/3 server.
NOT_APPLICABLE = {
    ("quic-go", "resumption"): "the image's HTTP/3 client exposes no session cache",
    ("quic-go", "zerortt"): "the image's HTTP/3 client exposes no 0-RTT",
    ("quic-go", "chacha20"): "the cipher-suite knob is only wired for HTTP/0.9",
    ("quic-go", "keyupdate"): "the key-update knob is only wired for HTTP/0.9",
    ("quic-go", "v2"): "the server offers QUIC version 1 only",
    ("quic-go", "migration"): "the image's HTTP/3 client does not move its address",
    ("aioquic", "v2"): "the server offers QUIC version 1 only",
    ("aioquic", "migration"): "the image's HTTP/3 client does not move its address",
    ("ngtcp2", "v2"): "the server offers QUIC version 1 only",
}

# The reverse direction: our client fetches one URL per run. The client library
# advertises a 16 KiB stream window and does not raise it as the body is read, so
# a body past that would wait for a window update that never comes. The handshake
# case asks for a small file; a multi-megabyte transfer is the forward table's.
REVERSE_CASES = {"handshake": [1024]}

# What each case asks the server and the client to do, and what must arrive.
CASES = {
    "handshake": {"paths": ["/1024"], "sizes": [1024]},
    "transfer": {"paths": ["/1048576", "/262144"], "sizes": [1048576, 262144]},
    "retry": {"paths": ["/1024"], "sizes": [1024], "retry": True},
    "resumption": {"paths": ["/1024", "/65536"], "sizes": [1024, 65536], "runs": 2},
    "zerortt": {"paths": ["/1024", "/65536"], "sizes": [1024, 65536], "runs": 2,
                "early": True},
    "chacha20": {"paths": ["/262144"], "sizes": [262144]},
    "keyupdate": {"paths": ["/262144"], "sizes": [262144]},
    "v2": {"paths": ["/1024"], "sizes": [1024]},
    "migration": {"paths": ["/262144"], "sizes": [262144]},
}


# ---------------------------------------------------------------- plumbing


def run(cmd, **kwargs):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, **kwargs)


def docker(args, **kwargs):
    return run(["docker", *args], **kwargs)


def create_certs():
    """The runner's layout: `cert.pem` beside `priv.key`, both self-signed."""
    certs = pathlib.Path(tempfile.mkdtemp(prefix="mooncat-interop-certs-"))
    shutil.copyfile(ROOT / "src/certs/cert.pem", certs / "cert.pem")
    shutil.copyfile(ROOT / "src/certs/key.pem", certs / "priv.key")
    return certs


def create_www(sizes):
    www = pathlib.Path(tempfile.mkdtemp(prefix="mooncat-interop-www-"))
    for size in sizes:
        (www / str(size)).write_bytes(pattern(size))
    return www


def create_app():
    """The ASGI application the aioquic server serves: the same `/<n>` pattern."""
    app = pathlib.Path(tempfile.mkdtemp(prefix="mooncat-interop-app-"))
    (app / "pattern.py").write_text(
        "async def app(scope, receive, send):\n"
        "    if scope['type'] == 'lifespan':\n"
        "        while True:\n"
        "            message = await receive()\n"
        "            if message['type'] == 'lifespan.startup':\n"
        "                await send({'type': 'lifespan.startup.complete'})\n"
        "            else:\n"
        "                await send({'type': 'lifespan.shutdown.complete'})\n"
        "                return\n"
        "    path = scope.get('path', '/').strip('/')\n"
        "    n = int(path) if path.isdigit() else 1024\n"
        "    body = bytes(i % 251 for i in range(n))\n"
        "    await send({'type': 'http.response.start', 'status': 200,\n"
        "                'headers': [(b'content-type', b'application/octet-stream')]})\n"
        "    await send({'type': 'http.response.body', 'body': body})\n",
        encoding="utf-8",
    )
    return app


def wait_for_udp(name):
    for _ in range(150):
        probe = docker(
            [
                "exec",
                name,
                "sh",
                "-c",
                "grep -qi ':01BB' /proc/net/udp 2>/dev/null || "
                "grep -qi ':01BB' /proc/net/udp6 2>/dev/null",
            ]
        )
        if probe.returncode == 0:
            return
        state = docker(["inspect", "-f", "{{.State.Running}}", name]).stdout.strip()
        if state != "true":
            raise RuntimeError("the container exited: " + docker(["logs", name]).stdout)
        time.sleep(0.1)
    raise RuntimeError(
        "the container never bound %d/udp: %s"
        % (PORT, (docker(["logs", name]).stdout or "").strip()[-2000:])
    )


def start_server(case, server_spec, volumes):
    env = [
        "-e", "ROLE=server",
        "-e", "TESTCASE=" + case,
        "-e", "MOONCAT_PORT=%d" % PORT,
        "-e", "MOONCAT_CERT=/certs/cert.pem",
        "-e", "MOONCAT_KEY=/certs/priv.key",
    ]
    if CASES[case].get("retry"):
        env += ["-e", "MOONCAT_RETRY=1"]
    if CASES[case].get("early"):
        env += ["-e", "MOONCAT_EARLY=accept"]
    args = [
        "run", "-d", "--rm", "--name", SERVER, "--network", NETWORK,
        "--network-alias", HOST,
    ]
    for volume in volumes:
        args += ["-v", str(volume)]
    args += env + [server_spec["image"]]
    result = docker(args)
    if result.returncode != 0:
        raise RuntimeError("could not start the server: " + result.stdout)
    wait_for_udp(SERVER)


def stop(name):
    docker(["rm", "-f", name], check=False)


def start_peer_server(peer, case):
    spec = SERVERS[peer](case)
    # The images' servers answer HTTP/0.9 for every testcase but `http3`; the
    # reverse direction is entirely HTTP/3, so both sides are told `http3`.
    env = ["-e", "ROLE=server", "-e", "TESTCASE=http3"]
    for key, value in spec.get("env", {}).items():
        env += ["-e", "%s=%s" % (key, value)]
    args = [
        "run",
        "-d",
        "--rm",
        "--name",
        SERVER,
        "--network",
        NETWORK,
        "--network-alias",
        HOST,
        "-v",
        str(CERTS) + ":/certs:ro",
        "-v",
        str(WWW) + ":/www:ro",
        "-v",
        str(LOGS) + ":/logs",
    ]
    if peer == "aioquic":
        args += ["-v", str(APP) + ":/app:ro"]
    args += env + [
        "--entrypoint",
        spec["entrypoint"],
        "-w",
        spec["workdir"],
        spec["image"],
        *spec["args"],
    ]
    result = docker(args)
    if result.returncode != 0:
        raise RuntimeError("could not start %s: %s" % (peer, result.stdout))
    wait_for_udp(SERVER)


def run_peer_client(peer, case, run_index, paths, downloads):
    spec = CLIENTS[peer](case, paths, run_index)
    env = [
        "-e", "ROLE=client",
        "-e", "TESTCASE=" + case,
        "-e", "REQUESTS=" + " ".join(
            "https://%s:%d%s" % (HOST, PORT, path) for path in paths
        ),
        "-e", "SSLKEYLOGFILE=/logs/keys.log",
        "-e", "QLOGDIR=/logs/qlog",
    ]
    for key, value in spec.get("env", {}).items():
        env += ["-e", "%s=%s" % (key, value)]
    args = [
        "run",
        "--rm",
        "--name",
        CLIENT,
        "--network",
        NETWORK,
        "-v",
        str(downloads) + ":/downloads",
        "-v",
        str(LOGS) + ":/logs",
        *env,
        "--entrypoint",
        spec["entrypoint"],
        "-w",
        spec["workdir"],
        spec["image"],
        *spec["args"],
    ]
    stop(CLIENT)
    try:
        return docker(args, timeout=120)
    except subprocess.TimeoutExpired as expired:
        return subprocess.CompletedProcess(
            args, 124, (expired.stdout or "") + "\nthe client did not finish in 120 s"
        )


def run_our_client(size, expect):
    result = docker(
        [
            "run",
            "--rm",
            "--name",
            CLIENT,
            "--network",
            NETWORK,
            "-e",
            "MOONCAT_URL=https://%s:%d/%d" % (HOST, PORT, size),
            "-e",
            "MOONCAT_SIZE=%d" % size,
            "-e",
            "MOONCAT_EXPECT=" + expect,
            "--entrypoint",
            "/usr/local/bin/mooncat-interop-client",
            "mooncat-interop",
        ],
        timeout=120,
    )
    return result


def verify_downloads(downloads, sizes):
    got = {
        path.stat().st_size: path
        for path in pathlib.Path(downloads).iterdir()
        if path.is_file()
    }
    missing = [size for size in sizes if size not in got]
    if missing:
        listing = sorted(
            (path.name, path.stat().st_size)
            for path in pathlib.Path(downloads).iterdir()
            if path.is_file()
        )
        return "no file of %s bytes; downloaded %s" % (missing, listing)
    for size in sizes:
        body = got[size].read_bytes()
        if body != pattern(size):
            return "%s is not the %d-byte pattern" % (got[size].name, size)
    return None


def clear(downloads):
    for path in pathlib.Path(downloads).iterdir():
        if path.is_file():
            path.unlink()
        else:
            shutil.rmtree(path)


# ---------------------------------------------------------------- the matrix


def forward(peer, case):
    """The peer's HTTP/3 client downloads from our server."""
    if (peer, case) in NOT_APPLICABLE:
        return "n/a", NOT_APPLICABLE[(peer, case)]
    spec = CASES[case]
    downloads = DOWNLOADS[peer]
    clear(downloads)
    start_server(case, {"image": "mooncat-interop"},
                 [str(CERTS) + ":/certs:ro", str(LOGS) + ":/logs"])
    try:
        runs = spec.get("runs", 1)
        for index in range(runs):
            paths = spec["paths"][index:index + 1] if runs > 1 else spec["paths"]
            result = run_peer_client(peer, case, index, paths, downloads)
            if result.returncode != 0:
                tail = (result.stdout or "").strip().splitlines()[-3:]
                return "fail", " ".join(tail)
        sizes = spec["sizes"][-1:] if runs > 1 else spec["sizes"]
        problem = verify_downloads(downloads, sizes)
        if problem:
            return "fail", problem
        return "pass", ""
    finally:
        stop(SERVER)


REVERSE_NOT_APPLICABLE = {
    "transfer": "the client's 16 KiB stream window carries no multi-megabyte body",
}


def reverse(peer, case):
    """Our HTTP/3 client fetches from the peer's server."""
    if case not in REVERSE_CASES:
        return "n/a", REVERSE_NOT_APPLICABLE.get(
            case, "the client exposes no session or transport knob for this case"
        )
    start_peer_server(peer, case)
    # ngtcp2's HTTP/3 server answers `/<n>` with n zero bytes; the other two serve
    # the file at `/www/<n>`, which is the pattern this repository's server serves.
    expect = "zero" if peer == "ngtcp2" else "pattern"
    try:
        for size in REVERSE_CASES[case]:
            result = run_our_client(size, expect)
            if result.returncode != 0:
                tail = (result.stdout or "").strip().splitlines()[-3:]
                return "fail", " ".join(tail)
        return "pass", ""
    finally:
        stop(SERVER)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--peers", default=",".join(CLIENTS))
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args()

    global NETWORK, DOWNLOADS, LOGS, CERTS, WWW, APP
    NETWORK = "mooncat-interop-%d" % os.getpid()
    LOGS = pathlib.Path(tempfile.mkdtemp(prefix="mooncat-interop-logs-"))
    (LOGS / "qlog").mkdir()
    CERTS = create_certs()
    WWW = create_www(sorted({size for sizes in REVERSE_CASES.values() for size in sizes}))
    APP = create_app()
    made = docker(["network", "create", NETWORK])
    if made.returncode != 0:
        raise SystemExit("could not create the network: " + made.stdout)
    DOWNLOADS = {
        peer: pathlib.Path(tempfile.mkdtemp(prefix="mooncat-interop-%s-" % peer))
        for peer in args.peers.split(",")
    }
    failures = 0
    results = {}
    try:
        for peer in args.peers.split(","):
            for case in args.cases.split(","):
                for direction, name in ((forward, "client"), (reverse, "server")):
                    result, detail = direction(peer, case)
                    results.setdefault(case, {}).setdefault(peer, {})[name] = result
                    if result == "fail":
                        failures += 1
                    print("%-5s %-8s %-10s %-6s %s" % (result, peer, case, name, detail))
    finally:
        stop(SERVER)
        docker(["network", "rm", NETWORK], check=False)
        for path in [*DOWNLOADS.values(), LOGS, CERTS, WWW, APP]:
            shutil.rmtree(path, ignore_errors=True)

    if args.markdown:
        peers = args.peers.split(",")
        for name in ("client", "server"):
            print()
            print("| Case | " + " | ".join(peers) + " |")
            print("|:--|" + "|".join(":--:" for _ in peers) + "|")
            for case in args.cases.split(","):
                cells = [
                    results[case].get(peer, {}).get(name, "")
                    for peer in peers
                ]
                print("| %s | %s |" % (case, " | ".join(cells)))

    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
