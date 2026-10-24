///|
suberror Unknown derive(Debug)

///|
/// Serves HTTP only: fails on any other scope, as plenty of ASGI applications do.
let http_only : @moonasgi.AsgiApp = (scope, _, _) => {
  @async.pause()
  guard scope is Http(_) else { raise Unknown }
}

///|
/// Answers startup and shutdown with the given replies, storing a value in the state first.
fn answering(
  startup : @moonasgi.Event,
  shutdown : @moonasgi.Event,
) -> @moonasgi.AsgiApp {
  (scope, receive, send) => {
    guard scope is Lifespan(s) else { return }
    while true {
      match receive() {
        LifespanStartup => {
          s.state["db"] = "ready"
          send(startup)
        }
        LifespanShutdown => {
          send(shutdown)
          break
        }
        _ => ()
      }
    }
  }
}

///|
/// Run startup and then shutdown under `mode`, returning the log lines and each step's error.
async fn cycle(
  app : @moonasgi.AsgiApp,
  mode : @config.Lifespan,
) -> (Array[String], Error?, Error?, @lifespan.Driver) {
  let lines = []
  let driver = @lifespan.Driver::new(
    app,
    mode~,
    logger=@config.Logger::new(write=line => lines.push(line)),
  )
  let up : Ref[Error?] = Ref(None)
  let down : Ref[Error?] = Ref(None)
  @async.with_task_group(g => {
    driver.spawn(g)
    driver.startup() catch {
      e => up.val = Some(e)
    }
    driver.shutdown() catch {
      e => down.val = Some(e)
    }
  })
  (lines, up.val, down.val, driver)
}

///|
async test "auto: an application that fails on the lifespan scope is served without it" {
  let (lines, up, down, _) = cycle(http_only, Auto)
  assert_true(up is None)
  assert_true(down is None)
  assert_true(
    lines.contains("INFO:     ASGI 'lifespan' protocol appears unsupported."),
  )
  assert_true(lines.contains("INFO:     Application startup complete."))
}

///|
async test "on: the same failure stops the boot" {
  let (lines, up, _, _) = cycle(http_only, On)
  assert_true(up is Some(@lifespan.LifespanError(_)))
  assert_true(lines.contains("ERROR:     Application startup failed. Exiting."))
}

///|
async test "off: the application is never run under the lifespan scope" {
  let calls = []
  let app : @moonasgi.AsgiApp = (scope, _, _) => {
    @async.pause()
    calls.push(scope)
  }
  let (lines, up, down, _) = cycle(app, Off)
  assert_true(up is None && down is None)
  assert_eq(calls.length(), 0)
  assert_eq(lines.length(), 0)
}

///|
async test "a startup the application reports failed raises its message in every mode" {
  for mode in [@config.Lifespan::Auto, On] {
    let (_, up, _, _) = cycle(
      answering(
        LifespanStartupFailed(message="no db"),
        LifespanShutdownComplete,
      ),
      mode,
    )
    assert_true(up is Some(@lifespan.LifespanError("no db")))
  }
}

///|
async test "a shutdown the application reports failed raises its message" {
  let (_, up, down, _) = cycle(
    answering(LifespanStartupComplete, LifespanShutdownFailed(message="leak")),
    Auto,
  )
  assert_true(up is None)
  assert_true(down is Some(@lifespan.LifespanError("leak")))
}

///|
async test "what startup stores in the state stays on the driver" {
  let (lines, up, down, driver) = cycle(
    answering(LifespanStartupComplete, LifespanShutdownComplete),
    On,
  )
  assert_true(up is None && down is None)
  assert_eq(driver.state.get("db"), Some(Json::string("ready")))
  assert_eq(lines, [
    "INFO:     Waiting for application startup.", "INFO:     Application startup complete.",
    "INFO:     Waiting for application shutdown.", "INFO:     Application shutdown complete.",
  ])
}

///|
async test "an application that returns without answering needs no shutdown" {
  let app : @moonasgi.AsgiApp = (_, _, _) => @async.pause()
  let (lines, up, down, _) = cycle(app, On)
  assert_true(up is None && down is None)
  assert_false(lines.contains("INFO:     Waiting for application shutdown."))
}
