///|
/// A server-sent event stream: the head goes out at once, the events follow as they happen.
/// The app sends its head and then waits two seconds for its first event; the client has the
/// head (and can show that the stream is open) before that, as with uvicorn.
///
///     moon run src/examples/17-event-stream --target native
///     curl --no-buffer http://127.0.0.1:12000/events
#coverage.skip
async fn main {
  let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
    guard scope is Http(http) && http.path == "/events" else {
      send(
        @moonasgi.Event::HttpResponseStart(
          status=404,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
      return
    }
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[
          ("content-type", "text/event-stream"),
          ("cache-control", "no-cache"),
        ],
        trailers=false,
      ),
    )
    for event in ["one", "two", "three"] {
      @async.sleep(if event == "one" { 2000 } else { 200 })
      send(
        @moonasgi.Event::HttpResponseBody(
          body=@utf8.encode("data: \{event}\n\n"),
          more_body=event != "three",
        ),
      )
    }
  }
  println("mooncat serving events on http://127.0.0.1:12000/events")
  @mooncat.serve(app, host="127.0.0.1", port=12000) catch {
    err => println("mooncat stopped: \{err}")
  }
}
