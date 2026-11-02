// The supervisor's half of HTTP/3 under several workers. `moonbitlang/async` binds a UDP socket in
// one step, so `SO_REUSEPORT` cannot be set on it the way the TCP listener sets it; the supervisor
// holds the port instead and passes datagrams to the workers. A worker reaches it over loopback
// TCP with the token from its environment.

///|
/// The variable that tells a worker where the supervisor's link listener is.
let relay_var : String = "MOONCAT_RELAY"

///|
/// The variable that carries the token a worker opens its link with.
let token_var : String = "MOONCAT_RELAY_TOKEN"

///|
/// How often the relay looks up from the socket to see whether the supervisor is done, in
/// milliseconds.
let relay_poll : Int32 = 250

///|
priv struct Relay {
  udp : @socket.UdpServer
  listener : @socket.TcpServer
  token : String
  // A worker's link, and how many times that worker has connected; a link that ends clears its
  // place only if no newer one has taken it.
  links : Array[(@socket.Tcp, Int32)?]
  joined : Array[Int32]
  sending : @async.Mutex
  logger : @config.Logger
  mut done : Bool
}

///|
async fn Relay::open(config : @config.Config) -> Relay {
  let udp = @socket.UdpServer::UdpServer(
    @socket.Addr::parse(config.bind()),
    dual_stack=config.dual_stack,
  )
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  {
    udp,
    listener,
    token: @base16.encode(entropy(16)[:]),
    links: Array::make(config.workers, None),
    joined: Array::make(config.workers, 0),
    sending: @async.Mutex(),
    logger: config.logger,
    done: false,
  }
}

///|
/// What every worker needs in its environment to find the relay.
fn Relay::env(self : Relay) -> Map[String, String] {
  Map([(relay_var, self.listener.addr.to_string()), (token_var, self.token)])
}

///|
/// Pass datagrams until `done` is set. It runs protected from cancellation: when the supervisor
/// is stopped, the workers drain their requests, and their answers still have to get out.
async fn Relay::run(self : Relay) -> Unit {
  @async.with_task_group(g => {
    // The links end with the loop below, not on their own.
    g.spawn_bg(no_wait=true, () => {
      for ;; {
        let (conn, _) = self.listener.accept()
        g.spawn_bg(no_wait=true, () => self.link(conn))
      }
    })
    let buf = FixedArray::make(65536, b'\x00')
    while !self.done {
      guard @async.with_timeout_opt(relay_poll, () => self.udp.recvfrom(buf))
        is Some((n, from)) else {
        continue
      }
      let datagram = Bytes::makei(n, i => buf[i])
      let index = worker_of(datagram[:], self.links.length())
      // A worker that is starting has no link yet; the client sends again.
      if self.links[index] is Some((conn, _)) {
        conn.write(relay_frame(from.to_string(), datagram[:])) catch {
          _ => ()
        }
      }
    }
  })
}

///|
/// One worker's link: its hello, then every datagram it sends out through the port.
async fn Relay::link(self : Relay, conn : @socket.Tcp) -> Unit {
  defer conn.close()
  let line = conn.read_until("\n") catch { _ => None }
  guard line is Some(line) &&
    read_hello(line.trim_end(chars="\r\n"), self.token, self.links.length())
    is Some(index) else {
    return
  }
  self.joined[index] = self.joined[index] + 1
  let generation = self.joined[index]
  self.links[index] = Some((conn, generation))
  defer (if self.links[index] is Some((_, g)) && g == generation {
    self.links[index] = None
  })
  for ;; {
    let (peer, datagram) = read_relayed(conn) catch { _ => break }
    self.sending.acquire()
    self.udp.sendto(datagram, @socket.Addr::parse(peer)) catch {
      e => self.logger.log(@moonlog.debug, "HTTP/3 datagram not sent: \{e}")
    }
    self.sending.release()
  }
}

///|
/// Run the workers with HTTP/3 shared through this process, until it is stopped.
async fn supervise_with_relay(config : @config.Config) -> Unit {
  let relay = Relay::open(config)
  config.logger.log(
    @moonlog.info,
    "HTTP/3 on udp://\{config.bind()} is passed to \{config.workers} workers by connection id",
  )
  @async.with_task_group(g => {
    g.spawn_bg(() => @async.protect_from_cancel(() => relay.run()))
    defer {
      relay.done = true
    }
    @serve.supervise(config, env=relay.env())
  })
}

///|
/// This worker's endpoint: a link to the supervisor when it holds the port, a socket of its own
/// otherwise.
async fn worker_endpoint(serving : @socket.Addr) -> Endpoint {
  match
    (@env.get_env_var(relay_var), @env.get_env_var(token_var), @serve.worker()) {
    (Some(relay), Some(token), Some(index)) =>
      Endpoint::relay(relay, token, index, serving)
    _ => Endpoint::bind(serving.to_string())
  }
}
