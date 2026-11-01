///|
fn serve_http3(
  _app : @moonasgi.AsgiApp,
  _config : @mooncat.Config,
  _cert : @mooncat.TlsCert,
  _suites : Array[@record.Suite]?,
  _suites12 : Array[@record.Suite12]?,
) -> Unit raise {
  fail("HTTP/3 needs the native backend")
}
