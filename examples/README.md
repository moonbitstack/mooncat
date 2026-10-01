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
