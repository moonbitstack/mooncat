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
  guard got.tls is Some(Pem(certificate_file~, private_key_file~, password~)) else {
    fail("no certificate")
  }
  assert_eq(certificate_file, "cert.pem")
  assert_eq(private_key_file, "key.pem")
  assert_eq(password, None)
}

///|
test "a PKCS#12 file stands for both halves, and the password goes with it" {
  let got = plan([
    "--ssl-pkcs12", "server.p12", "--ssl-keyfile-password", "moon",
  ])
  guard got.tls is Some(Pkcs12(file~, password~)) else { fail("no PKCS#12") }
  assert_eq(file, "server.p12")
  assert_eq(password, "moon")
  let pem = plan([
    "--ssl-certfile", "cert.pem", "--ssl-keyfile", "key.pem", "--ssl-keyfile-password",
    "moon",
  ])
  assert_true(pem.tls is Some(Pem(password=Some("moon"), ..)))
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
  guard refusal(["--uds", "/tmp/s"]) is Some(@cli.Unsupported(flag~, why~)) else {
    fail("--uds was accepted")
  }
  assert_eq(flag, "--uds")
  assert_true(why.contains("TCP"))
  guard refusal(["--reload"]) is Some(@cli.Unsupported(why~, ..)) else {
    fail("--reload was accepted")
  }
  assert_true(why.contains("mctl serve --reload"))
  for
    one in [
      "--uds", "--fd", "--app-dir", "--interface", "--loop", "--http", "--ws", "--log-config",
      "--env-file", "--ssl-version",
    ] {
    guard refusal([one, "x"]) is Some(@cli.Unsupported(..)) else {
      fail("\{one} was accepted")
    }
  }
  for one in ["--factory"] {
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
  assert_false(
    @cli.parse([][:], base=quiet).config.logger.enabled(@moonlog.info),
  )
  assert_true(
    @cli.parse(["--log-level", "debug"][:], base=quiet).config.logger.enabled(
      @moonlog.debug,
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
  assert_true(help.contains("--workers"))
  assert_false(help.contains("--uds"))
}

///|
/// What a request sent in 0-RTT gets is a word, and a word the parser does not know is refused
/// with the three it does.
test "early data is a word, and an unknown one is refused" {
  assert_eq(
    plan(["--early-data", "refuse"]).config.early_data,
    @mooncat.EarlyData::Refuse,
  )
  assert_eq(
    plan(["--early-data", "off"]).config.early_data,
    @mooncat.EarlyData::Off,
  )
  let base = @mooncat.Config::new(early_data=@mooncat.EarlyData::Off)
  assert_eq(
    @cli.parse(["--early-data", "accept"][:], base~).config.early_data,
    @mooncat.EarlyData::Accept,
  )
  guard refusal(["--early-data", "maybe"]) is Some(@cli.Value(want~, ..)) else {
    fail("--early-data accepted a word it does not know")
  }
  assert_eq(want, "accept, refuse or off")
}

///|
/// The command line inherits the safe default: no flag means no early data, and the flag is the
/// only way a program started from the command line offers it.
test "early data is off on the command line until asked for" {
  assert_eq(plan([]).config.early_data, @mooncat.EarlyData::Off)
  assert_eq(
    plan(["--early-data", "accept"]).config.early_data,
    @mooncat.EarlyData::Accept,
  )
  assert_eq(
    plan(["--early-data", "refuse"]).config.early_data,
    @mooncat.EarlyData::Refuse,
  )
  assert_eq(
    plan(["--early-data", "off"]).config.early_data,
    @mooncat.EarlyData::Off,
  )
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

///|
test "the lifespan mode is one of three words" {
  assert_eq(plan([]).config.lifespan, Auto)
  assert_eq(plan(["--lifespan", "on"]).config.lifespan, On)
  assert_eq(plan(["--lifespan", "off"]).config.lifespan, Off)
  let refused : Result[@cli.Plan, Error] = Ok(plan(["--lifespan", "maybe"])) catch {
    e => Err(e)
  }
  assert_true(refused is Err(@cli.Value(flag="--lifespan", ..)))
}

///|
test "the clear beside TLS can be turned off" {
  assert_eq(plan([]).config.cleartext, true)
  assert_eq(plan(["--no-cleartext"]).config.cleartext, false)
}

///|
test "--workers sets how many processes serve, and the default is one" {
  assert_eq(@cli.parse([]).config.workers, 1)
  assert_eq(@cli.parse(["--workers", "4"]).config.workers, 4)
}

///|
test "the WebSocket flags reach the config, in seconds, with 0 for off" {
  let base = @cli.parse([]).config.ws
  assert_eq(base.max_queue, 32)
  assert_eq(base.ping_interval, Some(20000))
  assert_eq(base.ping_timeout, Some(20000))
  assert_true(base.deflate)
  let ws = @cli.parse([
      "--ws-max-queue", "4", "--ws-ping-interval", "5", "--ws-ping-timeout", "0",
      "--ws-per-message-deflate", "false",
    ]).config.ws
  assert_eq(ws.max_queue, 4)
  assert_eq(ws.ping_interval, Some(5000))
  assert_eq(ws.ping_timeout, None)
  assert_false(ws.deflate)
  assert_eq(
    refusal(["--ws-per-message-deflate", "maybe"]),
    Some(
      @cli.Value(
        flag="--ws-per-message-deflate",
        got="maybe",
        want="true or false",
      ),
    ),
  )
}

///|
test "--ssl-ciphers names TLS 1.3 suites, --http3 needs a certificate, and runs under workers" {
  let plan = @cli.parse([
    "--ssl-certfile", "c.pem", "--ssl-keyfile", "k.pem", "--ssl-ciphers", "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
  ])
  assert_eq(plan.suites, Some([Aes256Gcm, ChaCha20Poly1305]))
  assert_eq(plan.suites12, None)
  assert_true(refusal(["--ssl-ciphers", "RC4"]) is Some(@cli.Value(..)))
  let both = @cli.parse([
    "--ssl-ciphers", "TLS_RSA_WITH_AES_128_CBC_SHA:TLS_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
  ])
  assert_eq(both.suites, Some([Aes128Gcm]))
  assert_eq(
    both.suites12.map(list => list.map(suite => suite.code)),
    Some([0x002f, 0xc02f]),
  )
  let older = @cli.parse(["--ssl-ciphers", "TLS_DHE_RSA_WITH_AES_256_CCM_8"])
  assert_eq(older.suites, None)
  assert_true(refusal(["--http3"]) is Some(@cli.Unsupported(..)))
  let shared = @cli.parse([
    "--http3", "--workers", "2", "--ssl-certfile", "c.pem", "--ssl-keyfile", "k.pem",
  ])
  assert_true(shared.http3)
  assert_eq(shared.config.workers, 2)
}
