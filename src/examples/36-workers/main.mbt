///|
/// Several processes on one port (← `uvicorn main:app --workers 4`), on Linux.
///
///     moon run src/examples/36-workers --target native -- --workers 4
///     curl http://127.0.0.1:12000
///
/// Each answer names the worker that gave it. The process that was started serves nothing: it
/// runs this program four more times, replaces a worker that dies, and stops them all when it is
/// stopped. `scripts/check_workers.sh` drives exactly that. With `WORKERS_FAIL` in the environment
/// the application refuses to start, and under `--lifespan on` the supervisor gives up with exit
/// code 3 rather than restarting something that would only fail again.
#coverage.skip
async fn main {
  let who = @env.get_env_var("MOONCAT_WORKER").unwrap_or("alone")
  let refuse = @env.get_env_var("WORKERS_FAIL") is Some(_)
  let app : @moonasgi.AsgiApp = (scope, receive, send) => {
    match scope {
      Lifespan(_) =>
        for ;; {
          match receive() {
            LifespanStartup if refuse =>
              send(@moonasgi.Event::LifespanStartupFailed(message="refused"))
            LifespanStartup => send(@moonasgi.Event::LifespanStartupComplete)
            LifespanShutdown => {
              send(@moonasgi.Event::LifespanShutdownComplete)
              break
            }
            _ => ()
          }
        }
      _ => {
        send(
          @moonasgi.Event::HttpResponseStart(
            status=200,
            headers=[("content-type", "text/plain; charset=utf-8")],
            trailers=false,
          ),
        )
        send(
          @moonasgi.Event::HttpResponseBody(
            body=@utf8.encode(who + "\n"),
            more_body=false,
          ),
        )
      }
    }
  }
  @cli.run(app)
}
