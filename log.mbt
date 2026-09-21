// Logging, in the shape of uvicorn's two loggers: `uvicorn.error` for the
// server's own lifecycle and failures, `uvicorn.access` for one line per
// request. A server that says nothing is a server nobody can operate — a request
// that 500s, a port that was already taken, a lifespan that refused to start all
// look identical from outside.
//
// The levels, the filtering and the sink are `moonlog`'s. What is here is what
// belongs to this server: uvicorn's line shape, and the access log, which is
// switched separately because a service behind a proxy that already logs
// requests wants the server's own messages and not a second copy.

///|
/// How much the server says, and where it goes.
pub struct Logger {
  out : @moonlog.Logger
  access : Bool
}

///|
/// One line in uvicorn's shape: the level, a colon, and five spaces.
fn uvicorn(record : @moonlog.Record) -> String {
  record.level.name() + ":     " + record.message
}

///|
/// A logger printing to stdout at `level`, with the access log on — uvicorn's
/// defaults. `access` off silences the per-request lines while keeping the
/// server's own.
pub fn Logger::new(
  level? : @moonlog.Level = Info,
  access? : Bool = true,
  write? : (String) -> Unit = line => println(line),
) -> Logger {
  {
    out: @moonlog.Logger::new(
      @moonlog.Lines::new(write, format=uvicorn),
      level~,
    ),
    access,
  }
}

///|
/// A logger that says nothing, for an embedder that does its own reporting or a
/// test that would rather not have output.
pub fn Logger::silent() -> Logger {
  { out: @moonlog.Logger::silent(), access: false, }
}

///|
/// Whether a line at `level` would be written.
pub fn Logger::enabled(self : Logger, level : @moonlog.Level) -> Bool {
  self.out.enabled(level)
}

///|
/// Write one server-lifecycle line (uvicorn's `uvicorn.error` logger, which
/// carries ordinary startup messages as well as failures).
pub fn Logger::log(
  self : Logger,
  level : @moonlog.Level,
  message : String,
) -> Unit {
  self.out.log(level, message)
}

///|
/// Write the one-line-per-request access log (uvicorn's `uvicorn.access`), in
/// the same shape: peer, request line, status.
pub fn Logger::access_line(
  self : Logger,
  client : String,
  verb : String,
  target : String,
  http_version : String,
  status : Int,
) -> Unit {
  if self.access {
    self.out.info(
      client +
      " - \"" +
      verb +
      " " +
      target +
      " HTTP/" +
      http_version +
      "\" " +
      status.to_string() +
      " " +
      reason(status),
    )
  }
}

///|
/// The reason phrase an access line pairs with a status. Lives here rather than
/// beside the native server because the access line is written on every backend.
fn reason(code : Int) -> String {
  match code {
    200 => "OK"
    201 => "Created"
    204 => "No Content"
    301 => "Moved Permanently"
    302 => "Found"
    304 => "Not Modified"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    500 => "Internal Server Error"
    _ => ""
  }
}
