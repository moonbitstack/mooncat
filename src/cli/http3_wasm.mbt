///|
fn serve_http3(
  _app : @moonasgi.AsgiApp,
  _config : @mooncat.Config,
  _cert : @mooncat.TlsCert,
) -> Unit raise {
  fail("HTTP/3 needs the native backend")
}
