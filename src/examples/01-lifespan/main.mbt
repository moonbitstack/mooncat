///|
/// The ASGI lifespan protocol (← uvicorn `LifespanOn`) driven in-process over
/// two async queues — no socket. The app parks under a `Lifespan` scope; the
/// driver pushes `lifespan.startup`, the app answers `startup.complete`, then
/// `lifespan.shutdown` and `shutdown.complete`, in that fixed order.
///
///     moon run src/examples/01-lifespan --target native
#coverage.skip
async fn main {
  @async.with_task_group(g => {
    let log : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is Lifespan(_) else { return }
      for ;; {
        match receive() {
          LifespanStartup => {
            log.push("startup")
            send(@moonasgi.Event::LifespanStartupComplete)
          }
          LifespanShutdown => {
            log.push("shutdown")
            send(@moonasgi.Event::LifespanShutdownComplete)
            break
          }
          _ => ()
        }
      }
    }
    let lifespan = @mooncat.Driver::new(app)
    lifespan.spawn(g)
    lifespan.startup()
    println("after startup : \{join(log)}")
    lifespan.shutdown()
    println("after shutdown: \{join(log)}")
  })
}

///|
/// Join log entries with an arrow so the ordered protocol reads left to right.
fn join(a : Array[String]) -> String {
  let sb = StringBuilder()
  for i = 0; i < a.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(" -> ")
    }
    sb.write_string(a[i])
  }
  sb.to_string()
}
