///|
/// Raised when an application reports `lifespan.startup.failed` or
/// `lifespan.shutdown.failed`, carrying the failure message the app supplied.
pub suberror LifespanError {
  LifespanError(String)
}

///|
/// Drives an ASGI application's lifespan protocol (← uvicorn `LifespanOn`).
///
/// A single long-lived invocation of the app runs under a `Lifespan` scope. The
/// server and that invocation exchange messages through two async queues: the
/// server pushes `lifespan.startup` / `lifespan.shutdown` onto `inbox` (which
/// backs the app's `Receive`), and the app pushes its `*.complete` / `*.failed`
/// replies onto `outbox` (which the app's `Send` writes to). `state` seeds the
/// lifespan scope and is shared into request scopes by the caller.
pub struct Lifespan {
  app : @moonasgi.AsgiApp
  inbox : @aqueue.Queue[@moonasgi.Event]
  outbox : @aqueue.Queue[@moonasgi.Event]
  state : Map[String, Json]
}

///|
/// Create a lifespan driver for `app`, with empty unbounded message queues and
/// empty lifespan state.
pub fn Lifespan::new(app : @moonasgi.AsgiApp) -> Lifespan {
  {
    app,
    inbox: @aqueue.Queue::Queue(kind=Unbounded),
    outbox: @aqueue.Queue::Queue(kind=Unbounded),
    state: Map([]),
  }
}

///|
/// Spawn the application under a `Lifespan` scope as a task in `g`, returning its
/// handle. The task blocks on `receive()` until `startup()` / `shutdown()` push
/// signals; a lifespan-aware app therefore stays parked for the server's whole
/// life, while an app that ignores the lifespan scope simply returns at once
/// (detected via the returned task in `startup` / `shutdown`).
pub fn Lifespan::spawn(
  self : Lifespan,
  g : @async.TaskGroup[Unit],
) -> @async.Task[Unit] {
  let receive : @moonasgi.Receive = () => self.inbox.get()
  let send : @moonasgi.Send = event => {
    match event {
      LifespanStartupComplete
      | LifespanStartupFailed(_)
      | LifespanShutdownComplete
      | LifespanShutdownFailed(_) => self.outbox.put(event)
      _ => ()
    }
  }
  let scope = @moonasgi.Scope::Lifespan({
    asgi: @moonasgi.AsgiVersion::lifespan(),
    state: self.state,
  })
  g.spawn(() => (self.app)(scope, receive, send))
}

///|
/// Run ASGI lifespan **startup**: push `lifespan.startup` and await the app's
/// reply. Returns once the app sends `lifespan.startup.complete`, or once the
/// app returns without lifespan support (its `task` finishing wins the race, and
/// startup is treated as a no-op, matching uvicorn's `lifespan="auto"`). Raises
/// `LifespanError` if the app reports `lifespan.startup.failed`.
pub async fn Lifespan::startup(
  self : Lifespan,
  task : @async.Task[Unit],
) -> Unit {
  self.inbox.put(LifespanStartup)
  let ev : @moonasgi.Event? = @async.any([
    () => Some(self.outbox.get()),
    () => {
      task.wait()
      None
    },
  ])
  match ev {
    Some(LifespanStartupFailed(message~)) => raise LifespanError(message)
    _ => ()
  }
}

///|
/// Run ASGI lifespan **shutdown**: push `lifespan.shutdown` and await the app's
/// reply, or return immediately if the app invocation has already finished.
/// Raises `LifespanError` if the app reports `lifespan.shutdown.failed`.
pub async fn Lifespan::shutdown(
  self : Lifespan,
  task : @async.Task[Unit],
) -> Unit {
  self.inbox.put(LifespanShutdown)
  let ev : @moonasgi.Event? = @async.any([
    () => Some(self.outbox.get()),
    () => {
      task.wait()
      None
    },
  ])
  match ev {
    Some(LifespanShutdownFailed(message~)) => raise LifespanError(message)
    _ => ()
  }
}
