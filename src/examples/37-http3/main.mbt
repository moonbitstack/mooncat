///|
/// `/` greets, `/big` streams a mebibyte, and anything sent is counted and reported back.
async fn app(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is Http(http) else { return }
  let start = (status : Int32) => {
    @moonasgi.Event::HttpResponseStart(
      status~,
      headers=[("content-type", "text/plain")],
      trailers=false,
    )
  }
  match http.path {
    "/big" => {
      send(start(200))
      for _ in 0..<16 {
        send(
          @moonasgi.Event::HttpResponseBody(
            body=Bytes::make(65536, b'x'),
            more_body=true,
          ),
        )
      }
      send(@moonasgi.Event::HttpResponseBody(body=b"", more_body=false))
    }
    _ => {
      let mut size = 0
      for ;; {
        guard receive() is HttpRequest(body~, more_body~) else { return }
        size = size + body.length()
        if !more_body {
          break
        }
      }
      send(start(200))
      let line = "\{http.http_version} \{http.http_method} \{http.path} \{size}\n"
      send(
        @moonasgi.Event::HttpResponseBody(
          body=@utf8.encode(line),
          more_body=false,
        ),
      )
    }
  }
}

///|
async fn main {
  @quic.serve_config(app, @mooncat.Config::new(port=12000), {
    certificate_file: "src/certs/cert.pem",
    private_key_file: "src/certs/key.pem",
  })
}
