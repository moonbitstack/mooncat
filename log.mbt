// Logging, in the shape of uvicorn's two loggers: `uvicorn.error` for the server's
// own lifecycle and failures, `uvicorn.access` for one line per request. A server
// that says nothing is a server nobody can operate — a request that 500s, a port
// that was already taken, a lifespan that refused to start all look identical from
// outside.

///|
/// How much the server says. Ordered, so a level is enabled when it is at least as
/// severe as the configured one — the same arrangement as Python's `logging`.
pub(all) enum LogLevel {
  Trace
  Debug
  Info
  Warning
  Error
  Critical
} derive(Eq)

///|
/// The level's rank, low to high, for the "at least as severe" comparison.
fn LogLevel::rank(self : LogLevel) -> Int {
  match self {
    Trace => 0
    Debug => 1
    Info => 2
    Warning => 3
    Error => 4
    Critical => 5
  }
}

///|
/// The level's name as it appears in a log line.
fn LogLevel::name(self : LogLevel) -> String {
  match self {
    Trace => "TRACE"
    Debug => "DEBUG"
    Info => "INFO"
    Warning => "WARNING"
    Error => "ERROR"
    Critical => "CRITICAL"
  }
}

///|
/// Where log lines go. Writing through a sink rather than straight to stdout is
/// what lets a test read what the server said, and what lets an embedder route
/// the lines into its own logging.
pub(all) struct Logger {
  level : LogLevel
  access : Bool
  write : (String) -> Unit
}

///|
/// A logger printing to stdout at `level`, with the access log on — uvicorn's
/// defaults. `access` off silences the per-request lines while keeping the
/// server's own.
pub fn Logger::new(
  level? : LogLevel = Info,
  access? : Bool = true,
  write? : (String) -> Unit = line => println(line),
) -> Logger {
  { level, access, write, }
}

///|
/// A logger that says nothing, for an embedder that does its own reporting or a
/// test that would rather not have output.
pub fn Logger::silent() -> Logger {
  { level: Critical, access: false, write: _line => (), }
}

///|
/// Whether a line at `level` would be written.
pub fn Logger::enabled(self : Logger, level : LogLevel) -> Bool {
  level.rank() >= self.level.rank()
}

///|
/// Write one server-lifecycle line (uvicorn's `uvicorn.error` logger, which carries
/// ordinary startup messages as well as failures).
pub fn Logger::log(self : Logger, level : LogLevel, message : String) -> Unit {
  if self.enabled(level) {
    (self.write)(level.name() + ":     " + message)
  }
}

///|
/// Write the one-line-per-request access log (uvicorn's `uvicorn.access`), in the
/// same shape: peer, request line, status.
///
/// Kept separate from `log` because it is switched separately: a service behind a
/// proxy that already logs requests wants the server's own messages and not a
/// second copy of the access log.
pub fn Logger::access_line(
  self : Logger,
  client : String,
  verb : String,
  target : String,
  http_version : String,
  status : Int,
) -> Unit {
  if self.access && self.enabled(Info) {
    (self.write)(
      "INFO:     " +
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
/// The reason phrase an access line pairs with a status. Lives here rather than beside
/// the native server because the access line is written on every backend.
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

///|
pub extend LogLevel with Eq::{not_equal, equal}
