///|
/// Every message goes back as it came.
async fn echo(
  scope : @moonasgi.Scope,
  receive : @moonasgi.Receive,
  send : @moonasgi.Send,
) -> Unit {
  guard scope is WebSocket(_) else { return }
  for ;; {
    match receive() {
      WebSocketConnect =>
        send(@moonasgi.Event::WebSocketAccept(subprotocol=None, headers=[]))
      WebSocketReceive(text=Some(text), ..) =>
        send(@moonasgi.Event::WebSocketSendText(text))
      WebSocketReceive(bytes=Some(bytes), ..) =>
        send(@moonasgi.Event::WebSocketSendBytes(bytes))
      WebSocketDisconnect(..) => break
      _ => ()
    }
  }
}

///|
async fn main {
  @mooncat.serve(echo, port=9001)
}
