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
| 0-RTT | a QUIC request that travelled with the handshake | the same scope, with `Early-Data: 1` in its headers and `early_data(scope)` true |
| ws, wss | `Upgrade: websocket` on an ordinary request | a `websocket` scope: connect, accept, receive, send, close |

The listener decides as the connection opens: under TLS in the handshake, in the
clear from the first bytes on the wire.

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
| `early_data` | `Accept` | what a request sent in 0-RTT gets: taken and marked, `Refuse`d with 425, or `Off` |
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

`early_data = Accept` takes the request and marks it, which is the default;
`EarlyData::Refuse` answers `425 Too Early` and never runs the application, for a
server whose routes cannot be replayed; `EarlyData::Off` puts no allowance in a
ticket, so no client can send any. `early_data_size` is how much one ticket
allows. Over TCP there is no early data whatever the setting says: a byte stream
cannot hold a request back until the handshake says whether to take it.

## Interoperability

`scripts/interop/check_matrix.py` runs the cases the QUIC interoperability runner
names, against aioquic, in CI. `src/examples/16-interop-server` is the server
under them.

| Case | What it checks | Result |
|:--|:--|:--|
| handshake | the TLS handshake completes and ALPN settles on `h3` | pass |
| transfer | a mebibyte down, 64 KiB up, both intact | pass |
| retry | an Initial that proved nothing is answered with a Retry, and the handshake after it completes | pass |
| resumption | a ticket is issued, and the next handshake resumes | pass |
| zerortt | early data is accepted and the request answered | pass |
| chacha20 | a handshake offering only ChaCha20-Poly1305 completes | pass |
| migration | the same connection is answered at a source port it did not start on | pass |
| v2 | QUIC version 2 | not offered: version 1 only, and a version 2 Initial is answered with a negotiated list naming 1 |
| keyupdate | a TLS KeyUpdate | not a case: QUIC has none, and one closes the connection (RFC 9001 §6) |

Retry and 0-RTT cannot be the same run: a client that has been sent a Retry may
not send early data under a token it has not been given yet (RFC 9000 §8.1), so
the server is started once with Retry on and once without.

`scripts/interop/` also holds the image the runner starts — `Dockerfile`,
`run_endpoint.sh` — and `implementations.json` naming the peers to cross with:
quic-go, aioquic and ngtcp2. The matrix above is what was executed here; the image
needs Docker, which the machine that wrote this did not have.

`scripts/http3/check_connections.py` asks the other question a server can fail: a
hundred connections one after another, a burst at once, and one connection that
stays open and keeps asking while the others come and go.

## Conformance

| Suite | Cases | Result |
|:--|:--|:--|
| h2spec, in the clear and over TLS | 146 | all pass |
| h2spec, strict | 147 | all pass |
| h3spec 0.1.14, its HTTP/3 servers section | 34 | all pass |
| Autobahn `fuzzingclient`, WebSocket | all cases | pass |
| HTTP/3 matrix, against aioquic | 7 | pass, and the two cases above that do not apply |

What does not pass is what this server does not offer: QUIC version 2, which is
the transport's to add, and TLS KeyUpdate, which QUIC does not have.

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
`07-http3` serves HTTP/1.1, HTTP/2 and HTTP/3 on one port, and is what `scripts/http3/check_h3spec.sh` runs h3spec against: all 34 cases of its "HTTP/3 servers" section pass.

## Targets

Serving runs where the async sockets are: the native and wasm backends, and the
suite runs on both. On js and wasm-gc the configuration, lifespan and proxy
packages build and the serving packages are empty. The QUIC half is native only.

## License

Apache-2.0.
