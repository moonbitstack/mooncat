///|
/// A routed application of the smallest useful shape: `/greet/<name>` answers JSON
/// and anything else is a 404.
///
/// Written against the ASGI seam directly rather than with a framework, because
/// what these tests prove is mooncat's half — that an application is served over
/// the wire — and a framework would make them prove the framework's half too. That
/// the two halves meet is moonhelo's to show; it is the end-to-end slice of all
/// nine repositories and depends on both.
fn greet_app() -> @moonasgi.AsgiApp {
  (scope, _receive, send) => {
    guard scope is Http(h) else { return }
    let (status, body, kind) = if h.path.has_prefix("/greet/") {
      let name = h.path[7:].to_owned()
      let json : Json = { "message": Json::string("hello " + name) }
      (200, json.stringify(), "application/json")
    } else {
      (404, "not found", "text/plain")
    }
    send(
      @moonasgi.Event::HttpResponseStart(
        status~,
        headers=[("content-type", kind)],
        trailers=false,
      ),
    )
    send(
      @moonasgi.Event::HttpResponseBody(
        body=@utf8.encode(body),
        more_body=false,
      ),
    )
  }
}

///|
/// mooncat serves a routed application on a live socket, and a real `@http` client
/// GETs a route and reads back the JSON and the status — the server half of the
/// greet chain, over the wire rather than over a pipe.
async test "greet: mooncat serves a routed app answering a real HTTP GET" {
  @async.with_task_group(g => {
    let task = g.spawn(() => @mooncat.serve(greet_app(), port=18095))
    @async.sleep(250)
    let (resp, body) = @http.get("http://127.0.0.1:18095/greet/moon")
    assert_eq(resp.code, 200)
    assert_eq(resp.headers.get("content-type"), Some("application/json"))
    assert_eq(body.json(), { "message": "hello moon" })
    // A route miss still routes: the app answers 404, mooncat frames it.
    let (miss, _b) = @http.get("http://127.0.0.1:18095/nope")
    assert_eq(miss.code, 404)
    task.cancel()
  })
}
