///|
/// The server `Config` surface (← uvicorn's `Config`): every transport knob
/// mooncat honours, the `host:port` bind string, uvicorn's own defaults, and
/// the `TlsCert` bundle `serve_tls_config` consumes. Built and printed
/// in-process — no socket is bound.
///
///     moon run src/examples/03-config --target native
#coverage.skip
fn main {
  let cfg = @mooncat.Config::new(
    host="0.0.0.0",
    port=12000,
    backlog=1024,
    dual_stack=true,
    reuse_addr=true,
    server_headers=Map([("server", "mooncat"), ("x-powered-by", "moonbit")]),
    max_connections=66666,
    allow_failure=false,
    graceful_timeout=23333,
  )
  println("bind             = \{cfg.bind()}")
  println("backlog          = \{cfg.backlog}")
  println("dual_stack       = \{cfg.dual_stack}")
  println("reuse_addr       = \{cfg.reuse_addr}")
  println("max_connections  = \{opt(cfg.max_connections)}")
  println("allow_failure    = \{cfg.allow_failure}")
  println("graceful_timeout = \{opt(cfg.graceful_timeout)}")
  for k, v in cfg.server_headers {
    println("server_header    = \{k}: \{v}")
  }
  let d = @mooncat.Config::new()
  println(
    "defaults         = \{d.bind()} backlog=\{d.backlog} reuse_addr=\{d.reuse_addr} allow_failure=\{d.allow_failure}",
  )
  let pem = @mooncat.TlsCert::pem("src/certs/cert.pem", "src/certs/key.pem")
  let pfx = @mooncat.TlsCert::pkcs12("src/certs/server.p12", password="moon")
  for cert in [pem, pfx] {
    match cert {
      Pem(certificate_file~, private_key_file~, ..) =>
        println(
          "tls bundle       = cert=\{certificate_file} key=\{private_key_file}",
        )
      Pkcs12(file~, ..) => println("tls bundle       = pkcs12=\{file}")
    }
  }
}

///|
/// Render an optional int knob (`None` = uvicorn's unbounded default).
fn opt(o : Int32?) -> String {
  match o {
    Some(n) => n.to_string()
    None => "unset"
  }
}
