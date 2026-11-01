///|
async fn serve_http3(
  app : @moonasgi.AsgiApp,
  config : @mooncat.Config,
  cert : @mooncat.TlsCert,
  suites : Array[@record.Suite]?,
) -> Unit {
  @quic.serve_config(app, config, cert, suites?)
}
