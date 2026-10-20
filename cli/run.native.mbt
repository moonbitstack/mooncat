// Starting a server is native-only, the same boundary `serve` sits on: the
// async HTTP transport has no wasm or js backend. Reading and checking a
// command line is portable and stays in `cli.mbt`, where it can be tested on
// every target.

///|
/// Serve `app` the way the command line says to.
///
/// This is the whole of a server program:
///
/// ```moonbit nocheck
/// async fn main {
///   @cli.run(app)
/// }
/// ```
///
/// ```
/// moon run src/main --target native -- --port 9000 --log-level debug
/// ```
///
/// With no `argv`, the real one is read and its first element — the path to
/// the executable — is dropped. `base` is where the flags start from, so a
/// program that wants its own defaults passes them and lets the command line
/// override only what was typed.
pub async fn run(
  app : @moonasgi.AsgiApp,
  argv? : ArrayView[String],
  base? : @mooncat.Config = @mooncat.Config::new(),
) -> Unit {
  let argv = match argv {
    Some(argv) => argv
    None => {
      let whole = @env.args()
      whole[1:]
    }
  }
  serve(app, parse(argv, base~))
}

///|
/// Serve under a plan already parsed, for a program that wants to look at the
/// plan — or change it — before the socket opens.
pub async fn serve(app : @moonasgi.AsgiApp, plan : Plan) -> Unit {
  match plan.tls {
    Some(cert) => @mooncat.serve_tls_config(app, plan.config, cert)
    None =>
      if plan.h2c {
        @mooncat.serve_h2c_config(app, plan.config)
      } else {
        @mooncat.serve_config(app, plan.config)
      }
  }
}
