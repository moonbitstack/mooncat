///|
/// Hand everything one end has queued to the other, both ways, until neither has more.
fn shuttle(a : @http2.Conn, b : @http2.Conn) -> Unit raise {
  for ;; {
    let ab = a.take()
    let ba = b.take()
    if ab.length() == 0 && ba.length() == 0 {
      break
    }
    b.receive(ab[:])
    a.receive(ba[:])
  }
}

///|
/// The events waiting on one end, up to `NeedData`.
fn drain(conn : @http2.Conn) -> Array[@http2.Event] raise {
  let out = []
  for ;; {
    let event = conn.next()
    if event is NeedData {
      break
    }
    out.push(event)
  }
  out
}

///|
fn fields(list : Array[@header.Header]) -> String {
  list.map(f => f.ascii()).map(p => "\{p.0}: \{p.1}").join(", ")
}

///|
/// One HTTP/2 exchange as mooncat serves it, run in-process: two of moonhttp's connection
/// state machines pass octets to each other, the server end with mooncat's default settings.
/// The server turns the request head into a moonasgi request, the application answers, and the
/// answer goes back as a head and DATA. `serve_h2c_config` does the same over a socket, with
/// each stream in a task of its own.
///
///     moon run examples/33-http2-h2c --target native
#coverage.skip
fn main raise {
  let limits = @mooncat.H2Config::new()
  let server = @http2.Conn::new(
    Server,
    settings=@http2.Settings::new(
      max_concurrent_streams=Some(limits.max_streams),
      initial_window_size=limits.window,
      max_frame_size=limits.max_frame,
      max_header_list_size=Some(limits.max_header_list),
    ),
  )
  server.widen(0, limits.connection_window - @http2.initial.initial_window_size)
  let client = @http2.Conn::new(Client)
  let id = client.next_stream()
  client.headers(id, [
    @header.Header::of(":method", "GET"),
    @header.Header::of(":scheme", "http"),
    @header.Header::of(":path", "/hello"),
    @header.Header::of(":authority", "127.0.0.1"),
  ])
  shuttle(client, server)
  println(
    "server settings: \{limits.max_streams} streams, \{limits.window}-octet stream window, \{limits.max_frame}-octet frames",
  )
  let app : @moonasgi.Handler = req => {
    @moonasgi.Response::text("hello over h2c, path \{req.path}")
  }
  for event in drain(server) {
    guard event is Request(stream~, fields=head) else { continue }
    println("request on stream \{stream}: \{fields(head)}")
    let path = head
      .iter()
      .find_first(f => f.ascii().0 == ":path")
      .map(f => f.ascii().1)
      .unwrap_or("/")
    let resp = app({
      http_method: "GET",
      path,
      query_string: b"",
      headers: [],
      body: b"",
    })
    server.headers(stream, [
      @header.Header::of(":status", resp.status.to_string()),
      @header.Header::of("content-type", "text/plain"),
    ])
    server.data(stream, resp.body[:], end=true)
  }
  shuttle(client, server)
  for event in drain(client) {
    match event {
      Response(stream~, fields=head) =>
        println("response on stream \{stream}: \{fields(head)}")
      Data(data~, ..) => println("body: " + @utf8.decode_lossy(data))
      End(stream~) => println("stream \{stream} ended")
      _ => ()
    }
  }
}
