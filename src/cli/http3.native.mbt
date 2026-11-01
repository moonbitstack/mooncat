///|
async fn serve_http3(
  app : @moonasgi.AsgiApp,
  config : @mooncat.Config,
  cert : @mooncat.TlsCert,
) -> Unit {
  @quic.serve_config(app, config, cert)
}
