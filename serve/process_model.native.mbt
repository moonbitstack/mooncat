///|
/// A handle for driving a graceful shutdown of `serve_graceful` from outside the
/// serving task (← uvicorn's `Server.should_exit` / `handle_exit`). Hand one to
/// `serve_graceful`, then call `shutdown()` from any other task to stop the
/// server: it stops accepting, waits for in-flight requests to drain, runs the
/// ASGI lifespan shutdown, and closes the listener, in that order.
///
/// Two async queues carry the handshake. `request` receives the shutdown trigger
/// (a signal delivered through the runtime's global cancellation reaches the
/// server the same way — see `serve_graceful`). `done` is posted once the
/// server has finished the whole shutdown sequence, so `shutdown()` can block
/// until the port is actually free.
pub struct ShutdownHandle {
  request : @aqueue.Queue[Unit]
  done : @aqueue.Queue[Unit]
}

///|
/// Create an idle shutdown handle with empty unbounded signal queues.
pub fn ShutdownHandle::new() -> ShutdownHandle {
  {
    request: @aqueue.Queue::Queue(kind=Unbounded),
    done: @aqueue.Queue::Queue(kind=Unbounded),
  }
}

///|
/// Request a graceful shutdown and block until the server has drained in-flight
/// requests, run lifespan shutdown, and closed the listener. Returns once the
/// listen port is free again.
pub async fn ShutdownHandle::shutdown(self : ShutdownHandle) -> Unit {
  self.request.put(())
  self.done.get()
}

///|
/// Request a graceful shutdown without waiting for it to finish.
pub async fn ShutdownHandle::request_stop(self : ShutdownHandle) -> Unit {
  self.request.put(())
}

///|
/// Serve one accepted connection: read request heads under keep-alive and hand each to
/// `dispatch_http1`, until the peer closes, goes quiet past `timeout_keep_alive`, upgrades to
/// a WebSocket, or a limit is reached. The same code runs over a plain socket and over TLS,
/// so both get the same limits, the same pipelining and the same WebSocket bridge.
async fn serve_conn(
  app : @moonasgi.AsgiApp,
  reader : &@io.Reader,
  writer : &@io.Writer,
  scheme : String,
  config : @config.Config,
  bound : @socket.Addr,
  peer : @socket.Addr,
  inflight : Ref[Int32],
  served : Ref[Int32],
  handle : ShutdownHandle,
) -> Unit {
  let inbox = Inbox::new(reader)
  for ;; {
    guard next_head(inbox, config) is Some(req) else {
      if inbox.refused is Some(e) {
        config.logger.log(Warning, "Invalid HTTP request received.")
        writer.write(refusal(e.status()))
      }
      break
    }
    // uvicorn answers `503` rather than queueing once it is already at its concurrency
    // ceiling — a request refused promptly is better for a caller than one that waits.
    if over_concurrency(inflight.val, config.limit_concurrency) {
      config.logger.log(
        Warning,
        "Exceeded concurrency limit, refusing with 503",
      )
      writer.write(
        "HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
      )
      break
    }
    let keep = dispatch_http1(
      app,
      req,
      inbox,
      writer,
      scheme~,
      config~,
      server_addr=bound,
      client_addr=peer,
    )
    served.val = served.val + 1
    if over_request_limit(served.val, config.limit_max_requests) {
      config.logger.log(
        Info,
        "Maximum request limit reached, stopping the server",
      )
      handle.request_stop()
      break
    }
    guard keep else { break }
  }
}

///|
/// Whether a further request would pass the concurrency ceiling (← uvicorn's
/// `--limit-concurrency`). `inflight` counts this connection too, so a limit of `n` lets `n`
/// requests run and refuses the `n+1`th. `None` never trips.
fn over_concurrency(inflight : Int32, limit : Int32?) -> Bool {
  match limit {
    Some(n) => inflight > n
    None => false
  }
}

///|
/// The acceptor task: pull connections off the listener and spawn a handler for each, with a
/// TLS handshake first when `cert` is given, tracking the in-flight count so the shutdown path
/// can drain them. Runs until cancelled by the shutdown coordinator.
async fn accept_loop(
  g : @async.TaskGroup[Unit],
  server : @socket.TcpServer,
  app : @moonasgi.AsgiApp,
  inflight : Ref[Int32],
  served : Ref[Int32],
  handle : ShutdownHandle,
  config : @config.Config,
  bound : @socket.Addr,
  cert : TlsCert?,
) -> Unit {
  // The parallel-client ceiling, applied before accepting, so a full server leaves the
  // connection in the listen queue rather than accepting it and then sitting on it.
  let slots = match config.max_connections {
    Some(n) => Some(@async.Semaphore(n))
    None => None
  }
  for ;; {
    if slots is Some(sem) {
      sem.acquire()
    }
    let (conn, peer) = server.accept()
    g.spawn_bg(
      () => {
        inflight.val = inflight.val + 1
        defer {
          conn.close()
          inflight.val = inflight.val - 1
          if slots is Some(sem) {
            sem.release()
          }
        }
        contain(config.allow_failure, () => {
          match cert {
            Some(c) => {
              let tls = tls_accept(conn, c)
              defer tls.close()
              serve_conn(
                app, tls, tls, "https", config, bound, peer, inflight, served, handle,
              )
            }
            None =>
              serve_conn(
                app, conn, conn, "http", config, bound, peer, inflight, served, handle,
              )
          }
        })
      },
      allow_failure=config.allow_failure,
    )
  }
}

///|
/// Run `body`, swallowing its failure when `allow_failure` says one bad connection must not bring
/// the whole server down.
async fn contain(allow_failure : Bool, body : async () -> Unit) -> Unit {
  if allow_failure {
    body() catch {
      _ => ()
    }
  } else {
    body()
  }
}

///|
/// `allow_failure` is the difference between a server that survives a broken connection and one
/// that stops: contained, the failure goes no further; not contained, it reaches the task group
/// that is running the acceptor.
async test "allow_failure decides whether a handler failure escapes" {
  let escaped = Ref(false)
  contain(true, () => fail("connection blew up")) catch {
    _ => escaped.val = true
  }
  assert_eq(escaped.val, false)
  contain(false, () => fail("connection blew up")) catch {
    _ => escaped.val = true
  }
  assert_eq(escaped.val, true)
}

///|
/// Wait for the in-flight request count to reach zero, giving up after
/// `timeout` milliseconds if one is set (`None` waits for the last request to
/// finish, as uvicorn does by default). Polls on a short tick because the count
/// is only mutated at handler task boundaries.
async fn drain(inflight : Ref[Int32], timeout : Int32?) -> Unit {
  let mut waited = 0
  for ;; {
    if inflight.val <= 0 {
      break
    }
    match timeout {
      Some(t) => if waited >= t { break }
      None => ()
    }
    @async.sleep(10)
    waited = waited + 10
  }
}

///|
/// Serve a moonasgi application with a uvicorn-style process model: a graceful
/// shutdown path over a single acceptor that spawns a concurrent handler per
/// connection.
///
/// The lifespan protocol runs startup before the listener binds and shutdown on
/// the way out. A single acceptor task spawns one handler task per connection, so
/// requests are served concurrently, each through mooncat's HTTP/1.1 codec and,
/// on an upgrade, its WebSocket bridge. `serve`, `serve_config` and
/// `serve_tls_config` run this same loop; this entry point adds the handle.
///
/// Shutdown is triggered by `handle.shutdown()` / `handle.request_stop()`, by
/// reaching `Config::limit_max_requests`, or by a signal the runtime turns into
/// global cancellation (see the boundary note below). All three converge on one
/// sequence, run under `protect_from_cancel` so a signal can't abort it midway:
/// stop accepting (cancel the acceptor), drain in-flight requests (bounded by
/// `Config::graceful_timeout`), run the ASGI lifespan shutdown, then close the
/// listener.
///
/// The acceptor honours the connection ceilings: `max_connections` gates
/// accepting, so a full server leaves the next client in the listen queue rather
/// than accepting it and sitting on it,
/// and `allow_failure` decides whether one bad connection is contained or brings
/// the server down. `limit_concurrency` is the other kind of ceiling — a request
/// arriving past it is answered `503` rather than queued.
///
/// ## Multi-worker boundary
///
/// uvicorn's `--workers` binds the port once in the parent (`SO_REUSEADDR`, an
/// inheritable socket) and hands that socket to N worker processes it starts with
/// `multiprocessing`'s spawn context. `moonbitlang/async` can start a process but
/// cannot give it a listening socket, and its event loop allows only one
/// outstanding `accept` per listener handle (`wait_read` guards on a single
/// waiter), so even N in-process acceptor tasks on one shared listener aren't
/// expressible — a second concurrent `accept` on the same listener aborts.
/// mooncat therefore serves from one acceptor that spawns a concurrent handler
/// per connection, which is the concurrency a single uvicorn worker provides on
/// its event loop. Multiple workers land when the async layer can pass a
/// listening socket to a child process.
///
/// ## Signal boundary
///
/// The only signal hook `moonbitlang/async` exposes is
/// `@signal.set_global_cancellation_signals`, which cancels the whole task tree
/// on SIGINT/SIGTERM. mooncat catches that cancellation and still runs lifespan
/// shutdown and closes the listener under `protect_from_cancel`; but a signal
/// also cancels the in-flight handler tasks, so drain-before-close is only fully
/// honoured on the programmatic `ShutdownHandle` path. That matches uvicorn's
/// own escalation: a first signal drains, a second forces exit.
pub async fn serve_graceful(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  handle~ : ShutdownHandle = ShutdownHandle::new(),
) -> Unit {
  run(app, config, handle, None)
}

///|
/// The one serving loop every entry point shares: lifespan startup, bind, accept (with a TLS
/// handshake when `cert` is given), then on a stop request stop accepting, drain in-flight
/// requests within `graceful_timeout`, run lifespan shutdown and close the listener.
async fn run(
  app : @moonasgi.AsgiApp,
  config : @config.Config,
  handle : ShutdownHandle,
  cert : TlsCert?,
) -> Unit {
  @async.with_task_group(g => {
    let lifespan = @lifespan.Lifespan::new(app)
    let ltask = lifespan.spawn(g)
    lifespan.startup(ltask)
    let bound = @socket.Addr::parse(config.bind())
    let server = @socket.TcpServer(
      bound,
      dual_stack=config.dual_stack,
      reuse_addr=config.reuse_addr,
    )
    let scheme = if cert is Some(_) { "https" } else { "http" }
    config.logger.log(
      Info,
      "Started server process on \{scheme}://" + config.bind(),
    )
    let inflight = Ref(0)
    let served = Ref(0)
    let acceptor = g.spawn(
      () => {
        accept_loop(
          g, server, app, inflight, served, handle, config, bound, cert,
        )
      },
      allow_failure=true,
    )
    handle.request.get() catch {
      _ => ()
    }
    @async.protect_from_cancel(() => {
      acceptor.cancel()
      drain(inflight, config.graceful_timeout)
      lifespan.shutdown(ltask) catch {
        _ => ()
      }
      server.close()
      handle.done.put(())
    })
  })
}

///|
/// Graceful shutdown, end to end over a real socket: a slow in-flight request is
/// still running when shutdown is triggered; the server must let it finish
/// (return `200`) before it runs lifespan shutdown, and the listener must be
/// closed afterwards. The `log` order pins the drain-then-shutdown sequence — it
/// is the assertion the mutation test flips.
async test "graceful shutdown drains in-flight, runs lifespan shutdown, then closes the listener" {
  @async.with_task_group(g => {
    let log : Array[String] = []
    let handle = ShutdownHandle::new()
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      match scope {
        Lifespan(_) =>
          for ;; {
            match receive() {
              LifespanStartup => send(@moonasgi.Event::LifespanStartupComplete)
              LifespanShutdown => {
                log.push("lifespan-shutdown")
                send(@moonasgi.Event::LifespanShutdownComplete)
                break
              }
              _ => ()
            }
          }
        Http(_) => {
          @async.sleep(300)
          send(
            @moonasgi.Event::HttpResponseStart(
              status=200,
              headers=[],
              trailers=false,
            ),
          )
          send(
            @moonasgi.Event::HttpResponseBody(body=b"drained", more_body=false),
          )
          log.push("request-done")
        }
        _ => ()
      }
    }
    let srv = g.spawn(() => {
      serve_graceful(app, @config.Config::new(port=18090), handle~)
    })
    @async.sleep(250)
    let client = g.spawn(() => {
      let (resp, _b) = @http.get("http://127.0.0.1:18090/")
      resp.code
    })
    @async.sleep(100)
    handle.shutdown()
    assert_eq(client.wait(), 200)
    assert_eq(log, ["request-done", "lifespan-shutdown"])
    let refused = try {
      @http.get("http://127.0.0.1:18090/") |> ignore
      false
    } catch {
      _ => true
    }
    assert_eq(refused, true)
    srv.wait()
  })
}

///|
/// A burst of concurrent requests is served while each handler holds for a beat:
/// the single acceptor spawns a handler per connection, so all eight overlap and
/// all answer `200`. Exercises the concurrent-handler fan-out under the accept
/// loop.
async test "concurrent request burst is served by per-connection handlers" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(_) else { return }
      @async.sleep(80)
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let srv = g.spawn(() => {
      serve_graceful(app, @config.Config::new(port=18091), handle~)
    })
    @async.sleep(250)
    let codes : Array[Int32] = []
    let tasks : Array[@async.Task[Unit]] = []
    for _i in 0..<8 {
      tasks.push(
        g.spawn(() => {
          let (resp, _b) = @http.get("http://127.0.0.1:18091/")
          codes.push(resp.code)
        }),
      )
    }
    for t in tasks {
      t.wait()
    }
    assert_eq(codes.length(), 8)
    for c in codes {
      assert_eq(c, 200)
    }
    handle.shutdown()
    srv.wait()
  })
}

///|
/// A trivial app answering `200 ok`, for the tests below that are about the server rather than
/// about anything the app does.
async fn ok_app(
  scope : @moonasgi.Scope,
  _receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is Http(_) else { return }
  send(
    @moonasgi.Event::HttpResponseStart(status=200, headers=[], trailers=false),
  )
  send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
}

///|
/// uvicorn drops a keep-alive connection that has gone quiet for `timeout_keep_alive`; both of
/// mooncat's keep-alive loops used to block on the next read with no deadline, so a peer that
/// connected and said nothing held a socket and a task for as long as it cared to.
///
/// The read is bounded by a `with_timeout_opt` of its own so a regression fails the test instead
/// of wedging the suite.
async test "an idle keep-alive connection is dropped after timeout_keep_alive" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let srv = g.spawn(() => {
      serve_graceful(
        ok_app,
        @config.Config::new(
          port=18093,
          timeout_keep_alive=300,
          logger=@config.Logger::silent(),
        ),
        handle~,
      )
    })
    @async.sleep(250)
    let sock = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:18093"))
    // Connect and say nothing at all. The server has to be the one to give up.
    let opened = @async.now()
    let dropped = @async.with_timeout_opt(3000, () => sock.read_some() is None)
    let waited = @async.now() - opened
    sock.close()
    assert_eq(dropped, Some(true))
    // It waited for the timeout rather than closing on sight.
    assert_eq(waited >= 200L, true)
    handle.shutdown()
    srv.wait()
  })
}

///|
/// uvicorn's `--limit-max-requests` stops the server once it has served that many, which is how a
/// supervisor recycles a worker. Reaching it runs the ordinary graceful sequence — no signal, no
/// caller asking it to stop.
async test "the request-count limit stops the server on its own" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let srv = g.spawn(() => {
      serve_graceful(
        ok_app,
        @config.Config::new(
          port=18094,
          limit_max_requests=2,
          logger=@config.Logger::silent(),
        ),
        handle~,
      )
    })
    @async.sleep(250)
    let (first, _b1) = @http.get("http://127.0.0.1:18094/one")
    assert_eq(first.code, 200)
    let (second, _b2) = @http.get("http://127.0.0.1:18094/two")
    assert_eq(second.code, 200)
    // Nobody asked it to stop; the count did. Bounded, so a limit that never trips fails this
    // test rather than parking it on a server that will never exit.
    let stopped = @async.with_timeout_opt(5000, () => srv.wait())
    if stopped is None {
      handle.request_stop()
      srv.wait()
    }
    assert_eq(stopped is Some(_), true)
    let refused = try {
      @http.get("http://127.0.0.1:18094/three") |> ignore
      false
    } catch {
      _ => true
    }
    assert_eq(refused, true)
  })
}

///|
/// uvicorn answers `503 Service Unavailable` once it is at `--limit-concurrency` rather than
/// queueing the request behind the ones already running: a caller told "not now" can retry
/// elsewhere, where one left waiting cannot.
async test "limit_concurrency refuses the overflow request with 503" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let slow : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(_) else { return }
      @async.sleep(400)
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let srv = g.spawn(() => {
      serve_graceful(
        slow,
        @config.Config::new(
          port=18096,
          limit_concurrency=1,
          logger=@config.Logger::silent(),
        ),
        handle~,
      )
    })
    @async.sleep(250)
    let codes : Array[Int32] = []
    let first = g.spawn(() => {
      let (resp, _b) = @http.get("http://127.0.0.1:18096/slow")
      codes.push(resp.code)
    })
    // Far enough behind that the first request is certainly in flight, well inside its 400ms.
    @async.sleep(120)
    let (overflow, _b) = @http.get("http://127.0.0.1:18096/overflow")
    assert_eq(overflow.code, 503)
    first.wait()
    assert_eq(codes, [200])
    handle.shutdown()
    srv.wait()
  })
}

///|
/// `max_connections` caps parallel clients: with a ceiling of one, four overlapping clients are
/// served one at a time.
async test "graceful serve honours max_connections" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let live = Ref(0)
    let peak = Ref(0)
    let counted : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(_) else { return }
      live.val = live.val + 1
      if live.val > peak.val {
        peak.val = live.val
      }
      @async.sleep(120)
      live.val = live.val - 1
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let srv = g.spawn(() => {
      serve_graceful(
        counted,
        @config.Config::new(
          port=18097,
          max_connections=1,
          // A handler holds its slot until the connection ends, so the idle timeout bounds how
          // long a finished client can keep the next one waiting.
          timeout_keep_alive=200,
          logger=@config.Logger::silent(),
        ),
        handle~,
      )
    })
    @async.sleep(250)
    let tasks : Array[@async.Task[Unit]] = []
    let codes : Array[Int32] = []
    for _i in 0..<4 {
      tasks.push(
        g.spawn(() => {
          let (resp, _b) = @http.get("http://127.0.0.1:18097/")
          codes.push(resp.code)
        }),
      )
    }
    for t in tasks {
      t.wait()
    }
    assert_eq(codes.length(), 4)
    // Every client was served, but never two at once.
    assert_eq(peak.val, 1)
    handle.shutdown()
    srv.wait()
  })
}

///|
/// End to end through a real socket: uvicorn installs `ProxyHeadersMiddleware` by default, so a
/// request arriving from the trusted loopback proxy is reported to the app as the client the proxy
/// names, over the scheme the proxy terminated.
async test "a trusted proxy's forwarded headers reach the scope" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let seen : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(hs) else { return }
      seen.push(
        match hs.client {
          Some((host, port)) => "\{host}:\{port}"
          None => "no-client"
        },
      )
      seen.push(hs.scheme)
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let srv = g.spawn(() => {
      serve_graceful(
        app,
        @config.Config::new(port=18098, logger=@config.Logger::silent()),
        handle~,
      )
    })
    @async.sleep(250)
    let (resp, _b) = @http.get("http://127.0.0.1:18098/", headers={
      "x-forwarded-for": "203.0.113.7, 10.0.0.9",
      "x-forwarded-proto": "https",
    })
    assert_eq(resp.code, 200)
    // The chain's leftmost entry, with the port a forwarded chain cannot carry.
    assert_eq(seen[0], "203.0.113.7:0")
    assert_eq(seen[1], "https")
    handle.shutdown()
    srv.wait()
  })
}

///|
/// The same request from a peer the config does not trust changes nothing. This is the half that
/// matters: `forwarded_allow_ips` defaults to the loopback proxy precisely so that a client which
/// can reach the port directly cannot name its own address.
async test "an untrusted peer's forwarded headers are ignored" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let seen : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, _receive, send) => {
      guard scope is Http(hs) else { return }
      seen.push(
        match hs.client {
          Some((host, _port)) => host
          None => "no-client"
        },
      )
      seen.push(hs.scheme)
      send(
        @moonasgi.Event::HttpResponseStart(
          status=200,
          headers=[],
          trailers=false,
        ),
      )
      send(@moonasgi.Event::HttpResponseBody(body=b"ok", more_body=false))
    }
    let srv = g.spawn(() => {
      serve_graceful(
        app,
        // The loopback client this test runs from is not in the trusted set.
        @config.Config::new(
          port=18102,
          forwarded_allow_ips=["10.0.0.1"],
          logger=@config.Logger::silent(),
        ),
        handle~,
      )
    })
    @async.sleep(250)
    let (resp, _b) = @http.get("http://127.0.0.1:18102/", headers={
      "x-forwarded-for": "203.0.113.7",
      "x-forwarded-proto": "https",
    })
    assert_eq(resp.code, 200)
    assert_eq(seen[0], "127.0.0.1")
    assert_eq(seen[1], "http")
    handle.shutdown()
    srv.wait()
  })
}

///|
/// A WebSocket scope gets the same treatment as an HTTP one, with the one difference that matters:
/// its scheme is `ws`/`wss`, so a proxy that forwards `https` has to arrive as `wss` rather than as
/// the word the header spelled.
async test "a trusted proxy's forwarded headers reach a websocket scope" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let seen : Array[String] = []
    let app : @moonasgi.AsgiApp = (scope, receive, send) => {
      guard scope is WebSocket(ws) else { return }
      seen.push(ws.scheme)
      seen.push(
        match ws.client {
          Some((host, port)) => "\{host}:\{port}"
          None => "no-client"
        },
      )
      guard receive() is WebSocketConnect else { return }
      send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
      match receive() {
        WebSocketReceive(text~, bytes=_) =>
          match text {
            Some(t) => send(@moonasgi.Event::WebSocketSendText(t))
            None => ()
          }
        _ => ()
      }
    }
    let srv = g.spawn(() => {
      serve_graceful(
        app,
        @config.Config::new(port=18110, logger=@config.Logger::silent()),
        handle~,
      )
    })
    @async.sleep(250)
    let ws = @websocket.connect("ws://127.0.0.1:18110/chat", headers={
      "x-forwarded-for": "203.0.113.7",
      "x-forwarded-proto": "https",
    })
    ws.send_text("go")
    assert_eq(ws.recv().read_all().text(), "go")
    ws.close()
    // `https` becomes `wss`, not the literal the header carried.
    assert_eq(seen[0], "wss")
    assert_eq(seen[1], "203.0.113.7:0")
    handle.shutdown()
    srv.wait()
  })
}

///|
/// uvicorn dates every response; over a real socket the header has to survive the whole send path,
/// not just the codec that formats it.
async test "a served response carries a Date header" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let srv = g.spawn(() => {
      serve_graceful(
        ok_app,
        @config.Config::new(port=18111, logger=@config.Logger::silent()),
        handle~,
      )
    })
    @async.sleep(250)
    let (resp, _b) = @http.get("http://127.0.0.1:18111/")
    assert_eq(resp.code, 200)
    guard resp.headers.get("date") is Some(stamped) else {
      fail("the response carried no Date header")
    }
    // IMF-fixdate: fixed width, always GMT.
    assert_eq(stamped.length(), 29)
    assert_eq(stamped[25:].to_owned(), " GMT")
    handle.shutdown()
    srv.wait()
  })
}

///|
/// A WebSocket round-trip under `serve_graceful`: text and binary frames come back and
/// the client's close reaches the app as a disconnect.
async test "graceful serve bridges a websocket round-trip" {
  @async.with_task_group(g => {
    let handle = ShutdownHandle::new()
    let srv = g.spawn(() => {
      serve_graceful(ws_echo_app, @config.Config::new(port=18092), handle~)
    })
    @async.sleep(250)
    let ws = @websocket.connect("ws://127.0.0.1:18092/chat")
    ws.send_text("via graceful")
    assert_eq(ws.recv().read_all().text(), "via graceful")
    ws.send_binary(b"\x01\x02\x03\xff"[:])
    assert_eq(ws.recv().read_all().binary(), b"\x01\x02\x03\xff")
    ws.send_close(code=Normal)
    ws.close()
    handle.shutdown()
    srv.wait()
  })
}
