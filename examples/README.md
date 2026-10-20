# Examples

Runnable examples of the current public `@mooncat` API. Each folder is a
`main` package for the native target:

```bash
moon run examples/01-lifespan --target native
```

Run `moon check --target native --deny-warn` to compile the package and all
examples. The in-process examples exit after printing their results. `00-hello`
is the only example that binds a socket; it serves HTTP/1.1 on port 12000 and
stays running until cancelled.

## Server

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 00 | [`hello`](00-hello/) | Serve the smallest moonasgi app over native HTTP/1.1 | `serve`, `@moonasgi.AsgiApp`, `Event::HttpResponseStart` / `HttpResponseBody` |
| 01 | [`lifespan`](01-lifespan/) | The ASGI lifespan protocol driven in-process over async queues | `Lifespan::new` / `spawn` / `startup` / `shutdown` |
| 02 | [`config`](02-config/) | The `Config` transport knobs and the `TlsCert` bundle | `Config::new` / `bind`, `TlsCert` |

## HTTP/2

| # | Example | What it shows | Key API |
| --- | --- | --- | --- |
| 33 | [`http2-h2c`](33-http2-h2c/) | In-process HTTP/2 frame round-trips and a moonasgi response carried as DATA; it does not bind a socket | `@http2.Frame`, `@http2.decode`, `@moonasgi.run_http` |

## Notes

**Native only.** `mooncat` rides `moonbitlang/async` (a native-only HTTP/TLS
transport), so the library and examples use the `native` target.

`serve` (00-hello) blocks in a keep-alive accept loop until its task is
cancelled — leave it running and hit it from another shell:

```bash
curl http://127.0.0.1:12000
# hello from mooncat, heke1228
```

TLS, QUIC, HTTP/3, WebSocket, and cryptographic implementation details are
covered by their owning packages. This repository's examples focus on the
server API and the h2c integration surface.

## 34-cli

A whole server program whose body is one line, driven by uvicorn's flags.

```
moon run examples/34-cli --target native -- --help
moon run examples/34-cli --target native -- --port 9000 --log-level debug
curl http://127.0.0.1:9000
```

`--workers 4` shows the other half of the design: a flag mooncat cannot honour
answers with the reason.

## 35-tour

Everything mooncat does, in one program that runs to completion and stops.
Real servers on real sockets, driven by real clients, printing what came back.

```
moon run examples/35-tour --target native
```

Configuration read off a command line, the lifespan protocol, an app on a
socket, the request limit that retires a server, forwarded headers believed
and ignored, WebSocket echo, h2c, and a graceful shutdown that lets the
request in flight finish.
