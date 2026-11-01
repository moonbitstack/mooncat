///|
async fn serve_http3(
  app : @moonasgi.AsgiApp,
  config : @mooncat.Config,
  cert : @mooncat.TlsCert,
  suites : Array[@record.Suite]?,
  suites12 : Array[@record.Suite12]?,
) -> Unit {
  @quic.serve_config(app, config, cert, suites?, suites12?)
}
