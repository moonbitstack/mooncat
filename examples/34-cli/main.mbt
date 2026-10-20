///|
/// A whole server program, in one line of body (← `uvicorn main:app`).
///
/// `uvicorn main:app --port 9000` names the app by string because Python
/// imports by string. MoonBit links it in instead, so the app is a value and
/// the flags are what carries over:
///
///     moon run examples/34-cli --target native -- --port 9000 --log-level debug
///     moon run examples/34-cli --target native -- --help
///     curl http://127.0.0.1:9000
///
/// `--help` lists every flag. A uvicorn flag mooncat cannot honour answers
/// with the reason rather than with "unexpected argument":
///
///     moon run examples/34-cli --target native -- --workers 4
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
        body=b"served from the command line\n",
        more_body=false,
      ),
    )
  }
  @cli.run(app) catch {
    err => println("mooncat: \{err}")
  }
}
