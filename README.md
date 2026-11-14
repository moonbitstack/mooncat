<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo/wide-dark.png">
  <img src="docs/assets/logo/wide-light.png" alt="mooncat" width="420">
</picture>

**An ASGI 3.0 server for MoonBit.**

[Home](https://moonbitstack.github.io/mooncat/) · [Guide](https://moonbitstack.github.io/mooncat/guide.html) · [API reference](https://moonbitstack.github.io/mooncat/api.html) · [mooncakes](https://mooncakes.io/docs/moonbitstack/mooncat)

</div>

mooncat accepts a network connection, turns each request into a scope, a receive
and a send, and drives your application with them. It speaks HTTP/1.1, HTTP/2,
HTTP/3 and WebSocket, with TLS, on one port.

An application is a function. It never sees a socket; the server never sees a
route:

```moonbit native
async fn main {
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain; charset=utf-8")],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(body=b"hello from mooncat\n", more_body=false),
    )
  }
  @mooncat.serve(app, host="127.0.0.1", port=12000)
}
```

```
$ moon run src/main --target native
$ curl -i http://127.0.0.1:12000/
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
server: mooncat
date: Mon, 02 Nov 2026 10:11:23 GMT
content-length: 19

hello from mooncat
```

## Install

```
moon add moonbitstack/mooncat
moon add moonbitstack/moonasgi
```

Both, in `moon.mod`, and the importing package needs them in its `moon.pkg`.

## One port, every version

| On the wire | Decided by | What the application sees |
|:--|:--|:--|
| HTTP/1.1 | the request line, in the clear | an `http` scope; the body one piece at a time |
| HTTPS | a TLS 1.3 handshake, `h2` and `http/1.1` offered by ALPN | the same scope with `scheme` `https`, and the certificate in `extensions` |
| h2c | the connection preface `PRI * HTTP/2.0` | the same scope, once per stream |
| HTTP/2 | ALPN answering `h2` | one scope per stream, each stream in a task of its own |
| HTTP/3 | the same port number on UDP | one scope per stream, advertised with `alt-svc` |
| 0-RTT | a QUIC request that travelled with the handshake, only when `early_data=Accept` | the same scope, with `Early-Data: 1` in its headers and `early_data(scope)` true |
| ws, wss | `Upgrade: websocket` on an ordinary request | a `websocket` scope: connect, accept, receive, send, close |

The listener decides as the connection opens: under TLS in the handshake, in the
clear from the first bytes on the wire.

A response's head goes out with its first piece of body, framed by `content-length`
when that piece is the whole body. An application that sends the head and then waits
before the first piece, as an event stream or an MCP `GET` does, has the head written
at once, framed as a stream: chunked on HTTP/1.1, closed with the connection on HTTP/1.0.
HTTP/2 and HTTP/3 write the head as soon as it is sent.

## The entry points

| Function | What it starts |
|:--|:--|
| `serve(app, host=, port=, backlog=)` | HTTP/1.1 and HTTP/2, one listener |
| `serve_config(app, config)` | the same, under an explicit `Config` |
| `serve_tls(app, certificate_file~, private_key_file~, ..)` | HTTPS, and the clear on the same port unless `cleartext=false` |
| `serve_tls_config(app, config, cert)` · `serve_tls_server(app, config, server)` | HTTPS with a certificate or a `@tls.Server` you built |
| `serve_h2c(app, host=, port=)` · `serve_h2c_config(app, config)` | HTTP/2 in the clear, and nothing else |
| `serve_graceful(app, config, handle=)` | the same loop, with a `ShutdownHandle` that drains before it closes |
| `@quic.serve_config(app, config, cert, ..)` | HTTP/1.1, HTTP/2 and HTTP/3 under one certificate |
| `@cli.run(app)` | a whole server program, configured from the command line |

Every entry point runs the same loop, so they share the limits, keep-alive,
pipelining and the WebSocket bridge. `serve` is the short way in;
`serve_config` takes the record.

Every listener also takes `listening=`: hand it a `Listening` and it reports the
address it bound, which is how a caller that asked for port 0 — every test does —
learns which port the system gave it.

```moonbit native
async fn configured() -> Unit {
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(@moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false))
    send(@moonasgi.Event::HttpResponseBody(body=b"configured\n", more_body=false))
  }
  let config = @mooncat.Config::new(
    port=12000,
    limit_concurrency=64,
    limit_max_requests=1000,
    server_headers=Map([("server", "mooncat")]),
  )
  @mooncat.serve_config(app, config)
}
```

## Command line

`@cli.run(app)` reads the process arguments and serves. The flags are the ones a
Python server of this shape takes, so a habit carries over; a flag the transport
cannot honour answers with the reason rather than "unexpected argument".

```moonbit native
async fn on_the_command_line() -> Unit {
  let app : @moonasgi.AsgiApp = (_scope, _receive, send) => {
    send(@moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false))
    send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
  }
  @cli.run(app)
}
```

```
$ ./app --help
Usage: mooncat [options]

Serve an ASGI application over HTTP/1.1, HTTP/2, HTTPS or HTTP/3.

Options:
  -h, --help                                                       Show help information.
  -V, --version                                                    Show version information.
  --[no-]date-header                                               stamp a Date header on every response
  --[no-]server-header                                             stamp a Server header
  --[no-]proxy-headers                                             believe X-Forwarded-* from the allowed peers
  --[no-]access-log                                                log one line per request
  --dual-stack                                                     accept IPv4 and IPv6 on one socket
  --h2c                                                            speak HTTP/2 in the clear instead of HTTP/1.1
  --http3                                                          serve HTTP/3 on UDP beside HTTPS, on the same port
  --early-data <early-data>                                        accept, refuse or off (off by default)
  --host <host>                                                    address to bind [env: MOONCAT_HOST]
  --port <port>                                                    port to bind [env: MOONCAT_PORT]
  --limit-concurrency <limit-concurrency>                          refuse with 503 above this many in flight
  --timeout-keep-alive <timeout-keep-alive>                        seconds an idle keep-alive connection is held
  --lifespan <lifespan>                                            auto, on or off
  --ssl-certfile <ssl-certfile>                                    PEM certificate; serves HTTPS
  --ssl-keyfile <ssl-keyfile>                                      PEM private key; serves HTTPS
  --ssl-keyfile-password <ssl-keyfile-password>                    password of the key file or the PKCS#12 file
  --ssl-pkcs12 <ssl-pkcs12>                                        PKCS#12 file (.p12, .pfx) holding the chain and the key; serves HTTPS

$ ./app --uds /tmp/app.sock
mooncat: --uds: the async transport binds TCP only
```

`@cli.parse(argv)` returns the plan without opening anything, for a program that
wants to look before it serves.

## Certificates

`TlsCert` says where the chain and the key come from: PEM files, with a password when the key is
encrypted, or one PKCS#12 file. A PKCS#12 file does not promise an order, so the certificate that
holds the key's public half is put first. Either serves HTTPS, HTTP/2 and HTTP/3 alike.

```moonbit native
let pem = @mooncat.TlsCert::pem("cert.pem", "key.pem", password="secret")
let pfx = @mooncat.TlsCert::pkcs12("server.p12", password="secret")
```

On the command line the same choice is `--ssl-certfile` with `--ssl-keyfile`, or `--ssl-pkcs12`,
and `--ssl-keyfile-password` for whichever holds the key.

## Configuration

`Config` holds what the flags set. Every field has a default, so only what
differs is written.

| Field | Default | What it does |
|:--|:--|:--|
| `host`, `port` | `"127.0.0.1"`, `12000` | where the listener binds |
| `max_connections` | none | above this, a client waits at the socket |
| `limit_concurrency` | none | above this, the request is answered `503` |
| `limit_max_requests` | none | the server retires once it has served this many |
| `timeout_keep_alive` | `5000` ms | an idle keep-alive connection is closed after this |
| `timeout_handshake` | `60000` ms | a TLS handshake that has not finished is dropped |
| `max_head_size` | `16384` | a request head past this is answered `431` |
| `server_headers` | `{"server": "mooncat"}` | added to every response |
| `date_header` | `true` | stamp a `date` on every response |
| `root_path` | `""` | the prefix something in front has stripped |
| `lifespan` | `Auto` | `Auto`, `On` or `Off` |
| `cleartext` | `true` | on a TLS port, serve connections that start without a handshake |
| `proxy_headers` | `true` | believe forwarded headers from `forwarded_allow_ips` |
| `workers` | `1` | processes on one port, on Linux |
| `ws` | 16 MiB messages, 32 queued, 20 s pings | the WebSocket side |
| `h2` | 100 streams, 64 KiB fields, 16 KiB frames, 1 MiB windows | the HTTP/2 side |
| `early_data` | `Off` | what a request sent in 0-RTT gets: taken and marked, `Refuse`d with 425, or `Off` |
| `early_data_size` | `16384` | how much early data one ticket allows |

## HTTP/3

`@quic.serve_config` runs the TCP listener and the UDP one under the same
lifespan, limits and shutdown, and advertises the UDP port on every response
with `alt-svc`. The QUIC half is native only. Under `workers` the kernel shares
the TCP port and the supervisor shares the UDP one: it holds the socket and passes
each datagram to the worker whose number is in the connection id, so a connection
stays with the worker that took it.

## HTTP over 0-RTT

HTTP/3 runs TLS 1.3, so a client that has a ticket from an earlier visit can send
its next request with the handshake instead of after it. Such a request may reach
the application twice — anything that saw the early data can replay it — and RFC
8470 asks the origin to say so and to be able to refuse.

A request that arrived that way reaches the application with `Early-Data: 1` in
its headers, with the `http.request.early_data` extension, and with
`early_data(scope)` true. The application decides what that means for it:

```moonbit native
async fn replay_safe(scope : @moonasgi.Scope, send : @moonasgi.Send) -> Unit {
  let early = @mooncat.early_data(scope)
  let status = if early { 425 } else { 200 }
  send(
    @moonasgi.Event::HttpResponseStart(status~, headers=[], trailers=false),
  )
  send(
    @moonasgi.Event::HttpResponseBody(
      body=@utf8.encode("early: \{early}\n"),
      more_body=false,
    ),
  )
}
```

`early_data` is `Off` by default: a replayable request is only taken when the
server was explicitly configured to take it, as nginx's `ssl_early_data` is off
unless switched on. `EarlyData::Accept` takes the request and marks it;
`EarlyData::Refuse` answers `425 Too Early` and never runs the application, for a
server whose routes cannot be replayed; `Off` puts no allowance in a ticket, so
no client can send any. On the command line the same three words go to
`--early-data`, and a program that wants 0-RTT has to ask for it:

```
$ ./app --http3 --early-data accept --ssl-certfile cert.pem --ssl-keyfile key.pem
```

`early_data_size` is how much one ticket allows. Over TCP there is no early data
whatever the setting says: a byte stream cannot hold a request back until the
handshake says whether to take it.

## Interoperability

Two harnesses, both in CI. `scripts/interop/check_matrix.py` drives
`src/examples/16-interop-server` with aioquic's HTTP/3 client directly, without
Docker, and covers all nine cases. `scripts/interop/check_docker_matrix.py` starts
the runner's own images — quic-go, ngtcp2 and aioquic, named in
`scripts/interop/implementations.json` — and crosses them with this server in both
directions.

The nine cases, against aioquic's HTTP/3 client:

| Case | What it checks | Result |
|:--|:--|:--|
| handshake | the TLS handshake completes and ALPN settles on `h3` | pass |
| transfer | a mebibyte down, 64 KiB up, both intact | pass |
| retry | an Initial that proved nothing is answered with a Retry, and the handshake after it completes | pass |
| resumption | a ticket is issued, and the next handshake resumes | pass |
| zerortt | early data is accepted and the request answered | pass |
| chacha20 | a handshake offering only ChaCha20-Poly1305 completes | pass |
| keyupdate | the client moves to QUIC key phase 1 and the server follows (RFC 9001 §6) | pass |
| migration | the same connection is answered at a source port it did not start on | pass |
| v2 | a client that starts in QUIC version 1 and offers 2 is moved to 2 by compatible negotiation (RFC 9368), and one that starts in 2 stays in it | pass |

Retry and 0-RTT cannot be the same run: a client that has been sent a Retry may
not send early data under a token it has not been given yet (RFC 9000 §8.1), so
the server is started once with Retry on and once without.

The same cases in Docker, the peer as the client and this server as the server:

| Case | aioquic | quic-go | ngtcp2 | What it checks |
|:--|:--:|:--:|:--:|:--|
| handshake | pass | pass | pass | ALPN settles on `h3` and the first request is answered |
| transfer | pass | pass | pass | a mebibyte and 256 KiB, both intact |
| retry | pass | pass | pass | an Initial with no token is answered with a Retry, and the handshake after it completes |
| resumption | pass | n/a | pass | a ticket is issued and the next handshake resumes |
| zerortt | pass | n/a | pass | early data is accepted and the request answered |
| chacha20 | pass | n/a | pass | a handshake offering only ChaCha20-Poly1305 completes |
| keyupdate | pass | n/a | pass | the client moves to key phase 1 and the server follows |
| v2 | pass | n/a | pass | the client offers version 2 beside 1 and the transfer completes |
| migration | n/a | n/a | pass | the same connection is answered at a source address it did not start on |

The reverse direction, this repository's HTTP/3 client (`integration/interop-client`)
against the peer's server:

| Case | aioquic | quic-go | ngtcp2 |
|:--|:--:|:--:|:--:|
| handshake | pass | pass | pass |
| the other eight | n/a | n/a | n/a |

`n/a` is a case a client cannot express, or one the server does not offer, not a
case that failed. The runner's clients speak HTTP/0.9 for every case but its
`http3` one, and this server speaks HTTP/3 only, so the crossing is made on each
image's HTTP/3 side. The client here asks for one file and takes the answer as it
comes, with the 16 KiB stream window it advertises; that carries the handshake
case, and a multi-megabyte transfer belongs to the forward table, whose clients
raise the window as they read.

`scripts/http3/check_connections.py` asks the other question a server can fail: a
hundred connections one after another, a burst at once, and one connection that
stays open and keeps asking while the others come and go.

## Conformance

| Suite | Cases | Result |
|:--|:--|:--|
| h2spec, in the clear and over TLS | 146 | all pass |
| h2spec, strict | 147 | all pass |
| h3spec 0.1.14, its HTTP/3 servers section | 34 | all pass |
| Autobahn `fuzzingclient`, WebSocket | 343 | 336 pass, 4 pass non-strict, 3 informational, none failed |
| HTTP/3 matrix, against aioquic | 9 | all pass |
| QUIC matrix in Docker, three peers | 9 × 3 forward, 1 × 3 reverse | pass, with the `n/a` rows above |

TLS KeyUpdate is not a case: QUIC has no such
message, and the runner's `keyupdate` case is a QUIC key phase update, which
passes. Autobahn's `NON-STRICT` is a case that passed by a route the suite
would have preferred otherwise, and `INFORMATIONAL` is a case that asserts
nothing; neither is a failure, and the run fails the build on `FAILED` alone.

## Packages

| Package | What is in it | What it costs to link |
|:--|:--|:--|
| `mooncat` | the entry points, re-exported | all of them |
| `mooncat/config` | `Config`, the access and error log, the HTTP date | the log, the date |
| `mooncat/lifespan` | the lifespan protocol | — |
| `mooncat/proxy` | forwarded headers from a trusted proxy | — |
| `mooncat/serve` | the accept loop, HTTP/1.1, HTTP/2, WebSocket, TLS, workers | the transport and the protocol codecs |
| `mooncat/cli` | the command line, and `run(app)` | the package above, plus the argument parser |
| `mooncat/quic` | HTTP/3: the UDP socket, the datagram loop, the streams | QUIC and its TLS |

## Examples

Each directory under `src/examples/` is a program that runs:

```
moon run src/examples/01-hello --target native
moon run src/examples/09-tour --target native
```

`01-hello` serves one route on port 12000. `09-tour` starts real servers, drives
them with real clients and prints what came back, then stops.
`11-event-log` wraps an application in a middleware that prints every ASGI message
it sees, one JSON line each; the playground is recorded from it.
`12-quic-echo` and `13-quic-client` are bare QUIC over a real socket, with no HTTP in between: tickets, 0-RTT, a key update.
`15-early-data` serves HTTP over 0-RTT and says whether each request was one:
`MOONCAT_EARLY=accept`, `refuse` or `off`. `16-interop-server` is what
`scripts/interop/check_matrix.py` drives: `GET /<n>` is `n` bytes.
`14-http2-server` is what `scripts/http2/check_h2spec.sh` runs h2spec against: all 146 cases pass in the clear and over TLS, and all 147 with its strict checks on.
`17-event-stream` sends its head and its first event two seconds apart; `scripts/checks/check_event_stream.py` checks that a raw socket, httpx and curl (HTTP/1.1 and h2c) hold the head within a second.
`07-http3` serves HTTP/1.1, HTTP/2 and HTTP/3 on one port, and is what `scripts/http3/check_h3spec.sh` runs h3spec against: all 34 cases of its "HTTP/3 servers" section pass.

## Targets

Serving runs where the async sockets are: the native and wasm backends, and the
suite runs on both. On js and wasm-gc the configuration, lifespan and proxy
packages build and the serving packages are empty. The QUIC half is native only.

## License

Apache-2.0.
