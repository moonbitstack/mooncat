///|
/// Hello, mooncat. The smallest moonasgi app — a `200` with a text body —
/// served over native HTTP/1.1 by `serve`, the role uvicorn plays for a Python
/// ASGI app. It blocks in the keep-alive accept loop until the task is
/// cancelled, so leave it running and hit it from another shell:
///
///     moon run examples/00-hello --target native
///     curl http://127.0.0.1:12000
#coverage.skip
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
      @moonasgi.Event::HttpResponseBody(
        body=b"hello from mooncat, heke1228\n",
        more_body=false,
      ),
    )
  }
  println("mooncat serving on http://127.0.0.1:12000")
  @mooncat.serve(app, host="127.0.0.1", port=12000) catch {
    err => println("mooncat stopped: \{err}")
  }
}
