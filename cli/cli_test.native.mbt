// The command line, flag by flag. `parse` reads a slice and returns a plan;
// it opens no socket and reads no environment, so every case here is a value
// compared against a value.

///|
fn plan(argv : Array[String]) -> @cli.Plan raise {
  @cli.parse(argv[:])
}

///|
test "nothing given leaves the defaults alone" {
  let got = plan([])
  let base = @mooncat.Config::new()
  assert_eq(got.config.host, base.host)
  assert_eq(got.config.port, 12000)
  assert_eq(got.config.date_header, true)
  assert_eq(got.config.proxy_headers, true)
  assert_true(got.tls is None)
  assert_false(got.h2c)
}

///|
test "the socket flags" {
  let got = plan(["--host", "0.0.0.0", "--port", "9000", "--backlog", "512"])
  assert_eq(got.config.host, "0.0.0.0")
  assert_eq(got.config.port, 9000)
  assert_eq(got.config.backlog, 512)
}

///|
/// uvicorn counts these in seconds and the config field holds milliseconds.
test "the two timeouts are seconds on the way in" {
  let got = plan([
    "--timeout-keep-alive", "30", "--timeout-graceful-shutdown", "5",
  ])
  assert_eq(got.config.timeout_keep_alive, 30_000)
  assert_eq(got.config.graceful_timeout, Some(5_000))
}

///|
test "the limits" {
  let got = plan([
    "--limit-concurrency", "100", "--limit-max-requests", "1000", "--max-connections",
    "50", "--h11-max-incomplete-event-size", "8192", "--ws-max-size", "65536",
  ])
  assert_eq(got.config.limit_concurrency, Some(100))
  assert_eq(got.config.limit_max_requests, Some(1000))
  assert_eq(got.config.max_connections, Some(50))
  assert_eq(got.config.max_head_size, 8192)
  assert_eq(got.config.ws.max_size, 65536)
}

///|
/// Every negatable flag, both ways, against a default that is the opposite of
/// what the flag sets — so neither direction can pass by accident.
test "the switches turn both ways" {
  assert_false(plan(["--no-date-header"]).config.date_header)
  assert_true(plan(["--date-header"]).config.date_header)
  assert_false(plan(["--no-proxy-headers"]).config.proxy_headers)
  assert_true(plan(["--proxy-headers"]).config.proxy_headers)
  assert_false(plan(["--no-reuse-addr"]).config.reuse_addr)
  assert_true(plan(["--reuse-addr"]).config.reuse_addr)
  assert_true(plan(["--dual-stack"]).config.dual_stack)
  assert_false(plan([]).config.dual_stack)
}

///|
/// `--no-server-header` empties the map rather than writing an empty value,
/// because a header with no value is still a header.
test "the server header can be taken off" {
  assert_true(plan([]).config.server_headers.length() > 0)
  assert_eq(plan(["--no-server-header"]).config.server_headers.length(), 0)
}

///|
test "forwarded peers split on commas and ignore the spaces" {
  let got = plan(["--forwarded-allow-ips", "10.0.0.1, 10.0.0.2 ,10.0.0.3"])
  assert_eq(got.config.forwarded_allow_ips, ["10.0.0.1", "10.0.0.2", "10.0.0.3"])
  assert_eq(plan(["--forwarded-allow-ips", "*"]).config.forwarded_allow_ips, [
    "*",
  ])
}

///|
test "the root path reaches the app" {
  assert_eq(plan(["--root-path", "/api"]).config.root_path, "/api")
}

///|
/// Both halves of a certificate, or neither. One alone is an error rather than
/// a server that quietly serves plaintext on the HTTPS port.
test "a certificate takes both files" {
  let got = plan(["--ssl-certfile", "cert.pem", "--ssl-keyfile", "key.pem"])
  guard got.tls is Some(cert) else { fail("no certificate") }
  assert_eq(cert.certificate_file, "cert.pem")
  assert_eq(cert.private_key_file, "key.pem")
}

///|
test "half a certificate is refused" {
  assert_eq(
    refusal(["--ssl-certfile", "cert.pem"]),
    Some(@cli.Partial(flag="--ssl-certfile", needs="--ssl-keyfile")),
  )
  assert_eq(
    refusal(["--ssl-keyfile", "key.pem"]),
    Some(@cli.Partial(flag="--ssl-keyfile", needs="--ssl-certfile")),
  )
}

///|
test "h2c picks the other listener" {
  assert_true(plan(["--h2c"]).h2c)
  assert_false(plan([]).h2c)
}

///|
test "a value that is not a number says which flag" {
  assert_eq(
    refusal(["--port", "nine"]),
    Some(@cli.Value(flag="--port", got="nine", want="a number")),
  )
  assert_eq(
    refusal(["--ws-max-size", ""]),
    Some(@cli.Value(flag="--ws-max-size", got="", want="a number")),
  )
}

///|
test "a level outside the six is refused, and names the six" {
  guard refusal(["--log-level", "loud"]) is Some(@cli.Value(got~, want~, ..)) else {
    fail("a bad level was accepted")
  }
  assert_eq(got, "loud")
  assert_true(want.contains("critical"))
  // The six themselves all parse.
  for name in ["trace", "debug", "info", "warning", "error", "critical"] {
    plan(["--log-level", name]) |> ignore
  }
}

///|
/// The point of declaring the flags mooncat cannot honour: the answer says
/// why, instead of calling the flag a typo.
test "a uvicorn flag we cannot honour explains itself" {
  guard refusal(["--workers", "4"]) is Some(@cli.Unsupported(flag~, why~)) else {
    fail("--workers was accepted")
  }
  assert_eq(flag, "--workers")
  assert_true(why.contains("one process"))
  guard refusal(["--reload"]) is Some(@cli.Unsupported(why~, ..)) else {
    fail("--reload was accepted")
  }
  assert_true(why.contains("reload_watch"))
  for
    one in [
      "--uds", "--fd", "--app-dir", "--interface", "--loop", "--http", "--ws", "--log-config",
      "--env-file", "--ws-ping-interval", "--ws-max-queue", "--ssl-version", "--ssl-ciphers",
    ] {
    guard refusal([one, "x"]) is Some(@cli.Unsupported(..)) else {
      fail("\{one} was accepted")
    }
  }
  for one in ["--factory", "--ws-per-message-deflate"] {
    guard refusal([one]) is Some(@cli.Unsupported(..)) else {
      fail("\{one} was accepted")
    }
  }
}

///|
/// What the command line does not mention, it does not touch.
test "a base config shows through where no flag covers it" {
  let base = @mooncat.Config::new(
    host="10.0.0.1",
    port=8443,
    root_path="/mounted",
    dual_stack=true,
  )
  let got = @cli.parse(["--port", "9001"][:], base~)
  assert_eq(got.config.port, 9001)
  assert_eq(got.config.host, "10.0.0.1")
  assert_eq(got.config.root_path, "/mounted")
  assert_true(got.config.dual_stack)
}

///|
/// Stated because it is a wart: `Logger` is opaque, so either logging flag
/// replaces the one in `base` rather than adjusting it.
test "a logging flag replaces the logger, and silence survives without one" {
  let quiet = @mooncat.Config::new(logger=@mooncat.Logger::silent())
  assert_false(@cli.parse([][:], base=quiet).config.logger.enabled(Info))
  assert_true(
    @cli.parse(["--log-level", "debug"][:], base=quiet).config.logger.enabled(
      Debug,
    ),
  )
}

///|
/// `--help` and `--version` are argparse's: it prints and exits, so they are
/// not reachable from here. What is reachable is the text itself.
test "the help text names the flags a user will reach for" {
  let help = @cli.command().render_help()
  for
    one in [
      "--host", "--port", "--log-level", "--ssl-certfile", "--[no-]date-header",
      "--root-path",
    ] {
    assert_true(help.contains(one))
  }
  // The ones we cannot honour are hidden: they answer when typed, and do not
  // clutter the list of what works.
  assert_false(help.contains("--workers"))
}

///|
fn refusal(argv : Array[String]) -> @cli.Refused? {
  try {
    @cli.parse(argv[:]) |> ignore
    None
  } catch {
    @cli.Value(flag~, got~, want~) => Some(@cli.Value(flag~, got~, want~))
    @cli.Unsupported(flag~, why~) => Some(@cli.Unsupported(flag~, why~))
    @cli.Partial(flag~, needs~) => Some(@cli.Partial(flag~, needs~))
    _ => None
  }
}
