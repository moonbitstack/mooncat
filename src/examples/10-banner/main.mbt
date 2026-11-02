// 此功能不入文档

///|
/// A server that says its name before it starts listening.
///
/// The banner is off in every other example and in the library itself; this one
/// turns it on, which is the whole of the interface: `enable`, an optional name,
/// and `print`. Pass a name to see another alphabet:
///
///     moon run src/examples/10-banner --target native
///     moon run src/examples/10-banner --target native -- cats
///
/// `@logo.names()` lists the built-in ones; `@logo.register` adds one of your own.
#coverage.skip
async fn main {
  let args = @env.args()
  let wanted = if args.length() > 1 { args[1] } else { "fast" }
  @logo.enable(name=wanted)
  @logo.print()
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
        body=b"the banner was printed above\n",
        more_body=false,
      ),
    )
  }
  @mooncat.serve(app, host="127.0.0.1", port=12000)
}
