///|
/// A typed greeting payload, the mctl-friendly shape a spec would generate:
/// `derive(ToJson)` for serialisation, so the handler returns it straight into a
/// JSON response.
struct Greeting {
  message : String
} derive(ToJson)

///|
/// The server half of the greet chain (§6.9): mooncat hosts a real moonapi `App`
/// on a live socket, and a real `@http` client GETs a typed route and reads back
/// the JSON body and status. This proves the two repos cooperate end to end over
/// the wire — a moonapi app answering a genuine HTTP request through mooncat's
/// accept loop and the moonasgi SEAM — not just that each compiles.
async test "greet: mooncat serves a moonapi app answering a real HTTP GET" {
  @async.with_task_group(g => {
    let api = @moonapi.App::new()
    api.get("/greet/:name", ctx => {
      let name = match ctx.param("name") {
        Some(n) => n
        None => "world"
      }
      @moonapi.json(
        200,
        ToJson::to_json(({ message: "hello \{name}", } : Greeting)),
      )
    })
    let app = api.to_asgi()
    let task = g.spawn(() => @mooncat.serve(app, port=18095))
    @async.sleep(250)
    let (resp, body) = @http.get("http://127.0.0.1:18095/greet/moon")
    assert_eq(resp.code, 200)
    assert_eq(resp.headers.get("content-type"), Some("application/json"))
    assert_eq(body.json(), { "message": "hello moon" })
    // A route miss still routes: moonapi answers 404, mooncat frames it.
    let (miss, _b) = @http.get("http://127.0.0.1:18095/nope")
    assert_eq(miss.code, 404)
    task.cancel()
  })
}
