// Where a server says what it ended up listening on. Tests need it because they ask for port 0, so
// that two of them can never be given the same number; a caller that prints its address or hands it
// to a client needs it for the same reason.

///|
/// A listener's address, once there is one: pass it to a serving entry point and ask it later. A
/// caller that asked for port 0 has no other way to learn which port the system gave it.
pub struct Listening {
  priv ready : @cond_var.Cond
  priv mut addr : @socket.Addr?
}

///|
/// A handle with no listener behind it yet.
pub fn Listening::new() -> Listening {
  { ready: @cond_var.Cond(), addr: None, }
}

///|
/// Whether the socket is bound, which is when `addr` stops waiting.
pub fn Listening::bound(self : Listening) -> Bool {
  self.addr is Some(_)
}

///|
/// The address the listener got, waiting until it has one.
pub async fn Listening::addr(self : Listening) -> @socket.Addr {
  while self.addr is None {
    self.ready.wait()
  }
  self.addr.unwrap()
}

///|
/// Record the address the socket was given, and wake whoever is waiting for it.
fn Listening::set(self : Listening, addr : @socket.Addr) -> Unit {
  self.addr = Some(addr)
  self.ready.broadcast()
}
