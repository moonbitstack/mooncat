///|
/// A connection's inbox over a pipe that already holds `wire` and is closed.
async fn inbox_of(wire : String) -> Inbox {
  let (r, w) = @pipe.pipe()
  w.write(@utf8.encode(wire))
  w.close()
  Inbox::new(r)
}

///|
/// Two requests in one segment are two requests.
///
/// A client that pipelines sends the second before the first is answered, and
/// `read_some` hands both back together. The inbox exists so that the second is still
/// there when the connection loop asks for it; before it, the octets past the first
/// head were whatever the read happened to leave in the reader.
async test "http1: two pipelined requests in one segment are both read" {
  let inbox = inbox_of(
    "GET /a HTTP/1.1\r\nhost: x\r\n\r\nGET /b HTTP/1.1\r\nhost: x\r\n\r\n",
  )
  let config = Config::new(timeout_keep_alive=3000)
  guard next_head(inbox, config) is Some(first) else {
    fail("the first request should be read")
  }
  assert_eq(first.target, "/a")
  guard next_head(inbox, config) is Some(second) else {
    fail("the second request was in the same segment and should be read too")
  }
  assert_eq(second.target, "/b")
  // And then the peer has closed.
  assert_eq(next_head(inbox, config) is None, true)
}

///|
/// A body read after the head takes exactly its length, leaving the next request.
async test "http1: a sized body followed by the next request leaves that request intact" {
  let inbox = inbox_of(
    "POST /p HTTP/1.1\r\ncontent-length: 5\r\n\r\nhelloGET /q HTTP/1.1\r\n\r\n",
  )
  let config = Config::new(timeout_keep_alive=3000)
  guard next_head(inbox, config) is Some(post) else {
    fail("the POST should be read")
  }
  assert_eq(post.body, Sized(5))
  assert_eq(inbox.exactly(5), b"hello")
  guard next_head(inbox, config) is Some(next) else {
    fail("the request after the body should be read")
  }
  assert_eq(next.target, "/q")
}

///|
/// The same for a chunked body, whose end is only known by reading it.
async test "http1: a chunked body followed by the next request leaves that request intact" {
  let inbox = inbox_of(
    "POST /c HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n" +
    "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" +
    "GET /after HTTP/1.1\r\n\r\n",
  )
  let config = Config::new(timeout_keep_alive=3000)
  guard next_head(inbox, config) is Some(post) else {
    fail("the POST should be read")
  }
  assert_eq(post.body, Chunked)
  assert_eq(inbox.chunks(), b"hello world")
  guard next_head(inbox, config) is Some(next) else {
    fail("the request after the chunked body should be read")
  }
  assert_eq(next.target, "/after")
}

///|
/// A head that smuggles is refused at the connection, not handed to the app.
///
/// The checks are moonhttp's; what this proves is that the server acts on them — a
/// refused head ends the connection rather than reaching dispatch.
async test "http1: a request that tries to smuggle a second one is not read" {
  let inbox = inbox_of(
    "POST / HTTP/1.1\r\ncontent-length: 5\r\ntransfer-encoding: chunked\r\n\r\n",
  )
  assert_eq(
    next_head(inbox, Config::new(timeout_keep_alive=3000)) is None,
    true,
  )
}

///|
test "a request path is percent-decoded, and a stray escape is kept as written" {
  assert_eq(@utf8.decode_lossy(percent_decode("/a%20b/%E6%97%A5")), "/a b/日")
  assert_eq(percent_decode("/100%/%zz/%4"), b"/100%/%zz/%4")
}
