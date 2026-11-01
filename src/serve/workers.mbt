// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// `Config.workers` (← uvicorn's `Multiprocess`): the process the user started becomes a supervisor
// that serves nothing, and runs the same program N times. Each worker binds the port itself under
// `SO_REUSEPORT` and runs its own lifespan, and the kernel spreads connections across them; a
// listening socket cannot be handed to a child through `moonbitlang/async`, which is what uvicorn
// does instead, and why this is Linux only.

///|
/// The variable that makes a process a worker; its value is the worker's number.
let worker_var : String = "MOONCAT_WORKER"

///|
/// The exit code of a worker that could not start (← uvicorn's `STARTUP_FAILURE`). A worker that dies
/// later is replaced; this one would only die the same way again, so the supervisor stops instead.
let startup_failure : Int32 = 3

///|
/// How long a dead worker's place stays empty, in milliseconds (← uvicorn checks its children twice
/// a second), so a worker that dies at once does not spin the machine.
let restart_delay : Int32 = 500

///|
/// How long a worker has past `graceful_timeout` to finish before it is killed, in milliseconds, or
/// in all when there is no `graceful_timeout`.
let stop_margin : Int32 = 30000

///|
extern "C" fn exit(code : Int32) = "exit"

///|
fn is_worker() -> Bool {
  @env.get_env_var(worker_var) is Some(_)
}

///|
/// A worker that failed before it listened tells the supervisor so through its exit code.
fn leave_failed(config : @config.Config, e : Error) -> Unit {
  config.logger.log(@moonlog.error, "Worker failed to start: \{e}")
  exit(startup_failure)
}

///|
/// Run `config.workers` workers until this process is stopped, replacing any that die. Stopping
/// this process stops them, each given `graceful_timeout` to drain.
async fn supervise(config : @config.Config) -> Unit {
  guard @async.platform is Linux else {
    fail(
      "workers above 1 need the kernel to share a port between processes, which only Linux does",
    )
  }
  config.logger.log(
    @moonlog.info,
    "Started parent of \{config.workers} workers",
  )
  let args = @env.args()[1:].to_owned()
  @async.with_task_group(g => {
    for i in 0..<config.workers {
      g.spawn_bg(() => keep_worker(i, args, config))
    }
  }) catch {
    e => {
      if @async.is_being_cancelled() {
        raise e
      }
      config.logger.log(@moonlog.error, "\{e}")
      exit(startup_failure)
    }
  }
}

///|
/// One worker's place: run it, and run another when it ends, which is also how
/// `limit_max_requests` recycles a worker.
async fn keep_worker(
  index : Int32,
  args : Array[String],
  config : @config.Config,
) -> Unit {
  let stop = @process.graceful_cancel(
    timeout=config.graceful_timeout.unwrap_or(0) + stop_margin,
  )
  for ;; {
    let code = @process.run(
      "/proc/self/exe",
      args,
      extra_env=Map([(worker_var, index.to_string())]),
      cancel_handler=stop,
    )
    if code == startup_failure {
      fail("Worker \{index} failed to start")
    }
    config.logger.log(
      @moonlog.warn,
      "Worker \{index} exited with \{code}, starting another",
    )
    @async.sleep(restart_delay)
  }
}
