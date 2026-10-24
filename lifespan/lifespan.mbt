///|
/// Raised when the lifespan protocol stops the boot or reports a failed shutdown: the application
/// sent `lifespan.startup.failed` or `lifespan.shutdown.failed`, or it raised under
/// `Lifespan::On`. Carries the application's message.
pub suberror LifespanError {
  LifespanError(String)
}

///|
/// What the lifespan invocation of the application said, or how it ended.
priv enum Reply {
  Said(@moonasgi.Event)
  Returned
  Raised(Error)
}

///|
/// Drives an application's lifespan protocol (← uvicorn's `LifespanOn`).
///
/// One invocation of the application runs under a `Lifespan` scope for the server's whole life:
/// `startup` sends `lifespan.startup` and waits for the answer, `shutdown` sends
/// `lifespan.shutdown`. `state` is the scope's namespace; the server gives every request scope a
/// shallow copy, so what startup stores there reaches each request.
///
/// `mode` is uvicorn's `--lifespan`: under `Auto` an application that fails on the lifespan scope,
/// as one serving only HTTP does, is taken not to speak the protocol and the server carries on;
/// under `On` that failure stops the boot; under `Off` nothing runs.
pub struct Driver {
  priv app : @moonasgi.AsgiApp
  priv mode : @config.Lifespan
  priv logger : @config.Logger
  priv inbox : @aqueue.Queue[@moonasgi.Event]
  priv replies : @aqueue.Queue[Reply]
  priv mut running : Bool
  state : Map[String, Json]
}

///|
pub fn Driver::new(
  app : @moonasgi.AsgiApp,
  mode~ : @config.Lifespan = Auto,
  logger~ : @config.Logger = @config.Logger::silent(),
  state~ : Map[String, Json] = {},
) -> Driver {
  {
    app,
    mode,
    logger,
    inbox: @aqueue.Queue::Queue(kind=Unbounded),
    replies: @aqueue.Queue::Queue(kind=Unbounded),
    running: false,
    state,
  }
}

///|
/// Start the lifespan invocation as a task in `g`. It waits on `receive()` until `startup`
/// and `shutdown` send it something; its failure is contained, and reported through them.
pub fn Driver::spawn(self : Driver, g : @async.TaskGroup[Unit]) -> Unit {
  if self.mode is Off {
    return
  }
  let receive : @moonasgi.Receive = () => self.inbox.get()
  let send : @moonasgi.Send = event => {
    match event {
      LifespanStartupComplete
      | LifespanStartupFailed(_)
      | LifespanShutdownComplete
      | LifespanShutdownFailed(_) => self.replies.put(Said(event))
      _ => ()
    }
  }
  let scope = @moonasgi.Scope::Lifespan({
    asgi: @moonasgi.AsgiVersion::lifespan(),
    state: self.state,
  })
  self.running = true
  g.spawn_bg(allow_failure=true, () => {
    let ended = try (self.app)(scope, receive, send) catch {
      e => Raised(e)
    } noraise {
      _ => Returned
    }
    self.running = false
    self.replies.put(ended)
  })
}

///|
/// Run lifespan **startup**: send `lifespan.startup` and wait for the answer. Returns on
/// `lifespan.startup.complete`, and when the application returns without answering. Raises
/// `LifespanError` on `lifespan.startup.failed`, and on a failure of the application under
/// `On`; under `Auto` such a failure means the application does not speak the protocol.
pub async fn Driver::startup(self : Driver) -> Unit {
  guard self.running else { return }
  self.logger.log(Info, "Waiting for application startup.")
  self.inbox.put(LifespanStartup)
  match self.replies.get() {
    Said(LifespanStartupFailed(message~)) => {
      self.logger.log(Error, message)
      self.logger.log(Error, "Application startup failed. Exiting.")
      raise LifespanError(message)
    }
    Raised(e) if self.mode is On => {
      self.logger.log(
        Error,
        "Exception in 'lifespan' protocol: " + e.to_string(),
      )
      self.logger.log(Error, "Application startup failed. Exiting.")
      raise LifespanError(e.to_string())
    }
    Raised(_) =>
      self.logger.log(Info, "ASGI 'lifespan' protocol appears unsupported.")
    _ => ()
  }
  self.logger.log(Info, "Application startup complete.")
}

///|
/// Run lifespan **shutdown**: send `lifespan.shutdown` and wait for the answer, unless the
/// invocation has already ended. Raises `LifespanError` on `lifespan.shutdown.failed`, and on a
/// failure of the application under `On`.
pub async fn Driver::shutdown(self : Driver) -> Unit {
  guard self.running else { return }
  self.logger.log(Info, "Waiting for application shutdown.")
  self.inbox.put(LifespanShutdown)
  match self.replies.get() {
    Said(LifespanShutdownFailed(message~)) => {
      self.logger.log(Error, message)
      raise LifespanError(message)
    }
    Raised(e) if self.mode is On => {
      self.logger.log(
        Error,
        "Exception in 'lifespan' protocol: " + e.to_string(),
      )
      raise LifespanError(e.to_string())
    }
    _ => ()
  }
  self.logger.log(Info, "Application shutdown complete.")
}
