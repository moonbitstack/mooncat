// The other direction of the interoperability matrix: this repository's HTTP/3 client against
// another implementation's server. The server the runner starts is what answers; the body is the
// `/<n>` pattern `src/examples/16-interop-server` serves, so a fetched file is checked byte for
// byte rather than counted.
//
//     MOONCAT_URL=https://server:443/262144 MOONCAT_SIZE=262144 moon run integration/interop-client --target native

///|
/// The body a peer is expected to answer with. `pattern` is the file this
/// repository's server serves; the other two are what the peer images generate on
/// their own for `/<n>`, and are named so that a mismatch is a failure rather
/// than an accident of which peer was asked.
fn expecting(size : Int32, mode : String) -> Bytes {
  match mode {
    "zero" => Bytes::makei(size, _ => b'\x00')
    "z" => Bytes::makei(size, _ => b'Z')
    _ => Bytes::makei(size, i => (i % 251).to_byte())
  }
}

///|
async fn main {
  let url = @env.get_env_var("MOONCAT_URL").unwrap_or(
    "https://127.0.0.1:443/1024",
  )
  let size = match @env.get_env_var("MOONCAT_SIZE") {
    Some(text) => @string.parse_int(text) catch { _ => 0 }
    None => 1024
  }
  let tls = @tls.Client::new(
    @x509.Roots::new(),
    alpn=["h3"],
    verify=Custom((_, _) => ()),
  )
  let client = @moonfetch.Client::new(tls~, http3=true, timeout=Some(30000)) catch {
    _ => abort("FAIL the client could not start")
  }
  let response = client.get(url) catch {
    _ => abort("FAIL no answer from \{url}")
  }
  client.close()
  let body = response.body
  let mode = @env.get_env_var("MOONCAT_EXPECT").unwrap_or("pattern")
  if response.status != 200 || body != expecting(size, mode) {
    abort(
      "FAIL wanted 200 and \{size} bytes, got \{response.status} and \{body.length()}",
    )
  }
  println("ok   \{size} bytes over \{response.version}")
}
