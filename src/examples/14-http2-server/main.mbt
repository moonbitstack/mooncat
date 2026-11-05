// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// `14-http2-server`: HTTP/2 in the clear on port 12000. `14-http2-server cert.pem key.pem`: over
/// TLS on the same port. It reads each request body to the end and answers `200`.
async fn main {
  let app : @moonasgi.AsgiApp = (_scope, receive, send) => {
    while true {
      match receive() {
        @moonasgi.Event::HttpRequest(more_body=false, ..) => break
        @moonasgi.Event::HttpRequest(_) => continue
        _ => break
      }
    }
    send(
      @moonasgi.Event::HttpResponseStart(
        status=200,
        headers=[("content-type", "text/plain")],
        trailers=false,
      ),
    )
    send(@moonasgi.Event::HttpResponseBody(body=b"hello\n", more_body=false))
  }
  let args = @env.args()
  if args.length() > 2 {
    @mooncat.serve_tls(app, certificate_file=args[1], private_key_file=args[2])
  } else {
    @mooncat.serve_h2c(app)
  }
}
