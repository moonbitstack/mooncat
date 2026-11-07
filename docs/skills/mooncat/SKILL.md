---
name: mooncat
description: Serve a MoonBit ASGI application over HTTP/1.1, HTTP/2, HTTP/3, WebSocket and TLS from one process. Use it when you have an `AsgiApp` — yours or one from moonapi, moongql, moonmcp — and need a real socket, a port, limits, graceful shutdown or several workers under it.
---

# mooncat

Add it to the module, then import the server. The application is an `@moonasgi.AsgiApp`: a
function of a scope, a receive and a send. mooncat never sees your routes, and your application
never sees a socket.

```
moon add moonbitstack/mooncat
```

Everything below listens on a real socket, so it is native only.

## Serve an application

`serve` is the short way in: a host, a port, and the application. It speaks HTTP/1.1 and HTTP/2,
the second by prior knowledge in the clear and by ALPN under TLS.

```moonbit native
async fn main {
  let app : @moonasgi.AsgiApp = (scope, receive, send) => {
    guard scope is Http(http) else { return }
    ignore(receive())
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain; charset=utf-8")],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(
        body=@utf8.encode("hello from " + http.path + "\n"),
        more_body=false,
      ),
    )
  }
  @mooncat.serve(app, host="127.0.0.1", port=12000)
}
```

`serve_config` takes the record instead, which is where the limits live: `limit_concurrency`
answers `503` past a ceiling, `limit_max_requests` stops the server after a count, `lifespan`
decides whether the application's startup and shutdown run.

```moonbit native
async fn configured(app : @moonasgi.AsgiApp) -> Unit {
  let config = @mooncat.Config::new(
    host="0.0.0.0",
    port=12000,
    limit_concurrency=64,
    timeout_keep_alive=5000,
    lifespan=@mooncat.Lifespan::On,
  )
  @mooncat.serve_config(app, config)
}
```

## Add TLS and HTTP/3

`TlsCert` says where the chain and the key come from — two PEM files, or one PKCS#12 file — and
`@quic.serve_config` serves HTTP/1.1, HTTP/2 and HTTP/3 together, TCP and UDP on the same port,
telling clients about the third with `alt-svc`.

```moonbit native
async fn with_http3(app : @moonasgi.AsgiApp) -> Unit {
  @quic.serve_config(
    app,
    @mooncat.Config::new(port=12000),
    @mooncat.TlsCert::pem("cert.pem", "key.pem"),
  )
}
```

## Know when a request may be a replay

An HTTP/3 client can send a request with its handshake. Such a request may reach the application
twice, so `early_data` says so — and a route that must not run twice can answer `425`.

```moonbit native
async fn replay_safe(scope : @moonasgi.Scope, send : @moonasgi.Send) -> Unit {
  if @mooncat.early_data(scope) {
    send(
      @moonasgi.Event::HttpResponseStart(
        status=425,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(body=b"try again\n", more_body=false),
    )
    return
  }
  send(
    @moonasgi.Event::HttpResponseStart(
      status=200,
      headers=[],
      trailers=false,
    ),
  )
  send(@moonasgi.Event::HttpResponseBody(body=b"once\n", more_body=false))
}
```

`@mooncat.Config::new(early_data=@mooncat.EarlyData::Refuse)` makes the server answer `425` for
every early request without running the application at all, and `EarlyData::Off` stops it offering
early data in the first place.

## Take the port from the system

A test — or anything that starts several servers — should ask for port 0 and read back what it got,
rather than pick a number that something else may already hold.

```moonbit native
async fn on_a_free_port(app : @moonasgi.AsgiApp) -> String {
  let base : Ref[String] = Ref("")
  @async.with_task_group(g => {
    let listening = @mooncat.Listening::new()
    let task = g.spawn(() => {
      @mooncat.serve(app, port=0, listening=listening)
    })
    base.val = "http://" + listening.addr().to_string()
    task.cancel()
  })
  base.val
}
```

## Things that catch people out

- The application must read the body, or the connection's credit never comes back: call `receive`
  until `more_body` is false, even when the body is not wanted.
- `receive` says `http.disconnect` when the response is done or the client has gone; it is not an
  error, and a request loop that treats it as one reports failures on every keep-alive connection.
- Everything but `serve_config`'s configuration is native. `@mooncat.Config`, `Lifespan` and the
  scope helpers do compile elsewhere; the listeners do not.
- `workers > 1` needs the kernel to share a port, which is Linux only. Elsewhere the server falls
  back to one process.
- The command line is `@cli.run(app)`: it takes uvicorn's flags and refuses the ones the transport
  cannot honour, saying why.
