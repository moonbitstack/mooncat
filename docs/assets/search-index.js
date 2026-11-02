/* Written by scripts/docs/gen_search.py from the pages themselves.
   Regenerate rather than edit. */
window.SEARCH = [
 {
  "lang": "en",
  "page": "Home",
  "url": "index.html",
  "heading": "mooncat",
  "text": ""
 },
 {
  "lang": "en",
  "page": "Home",
  "url": "index.html#what",
  "heading": "What it does the whole job, in one picture",
  "text": "mooncat owns the half of a web server that is not the protocol: the listening socket, the connection, the request that arrives on it in pieces, and the answer that leaves in pieces. It hands the application a scope describing the request and two callables — on"
 },
 {
  "lang": "en",
  "page": "Home",
  "url": "index.html#protocols",
  "heading": "One port, every version",
  "text": "The listener decides as the connection opens. Under TLS the choice is made in the handshake; in the clear it is the first bytes on the wire. Either way the request lands in the same place. On the wire Decided by What the application sees HTTP/1.1 the request l"
 },
 {
  "lang": "en",
  "page": "Home",
  "url": "index.html#start",
  "heading": "Quick start",
  "text": "shell moon add moonbitstack/mooncat moon add moonbitstack/moonasgi An application is a function of three arguments. It answers with two events: src/main.mbt /// A server that greets whoever connects. async fn main { let app : @moonasgi.AsgiApp = (_scope, _rece"
 },
 {
  "lang": "en",
  "page": "Home",
  "url": "index.html#recorded",
  "heading": "A recorded run moon run src/examples/09-tour",
  "text": "The tour example starts real servers on real sockets, drives them with real clients, prints what came back and stops. Nothing below is typed by hand. moon run src/examples/09-tour --target native $ moon run src/examples/09-tour --target native # configuration,"
 },
 {
  "lang": "en",
  "page": "Home",
  "url": "index.html#packages",
  "heading": "The packages",
  "text": "A program that answers only over TCP links none of the UDP half. The split follows what a package costs to carry, not how it reads. Package What it is for mooncat the entry points, re-exported, so @mooncat.serve is all a small program needs mooncat/config Conf"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html",
  "heading": "The guide",
  "text": ""
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#first",
  "heading": "Your first server",
  "text": "Add the packages. An application needs the interface package as well as the server: shell moon add moonbitstack/mooncat moon add moonbitstack/moonasgi An ASGI application is an async function of three arguments: the scope of one request, a way to read the requ"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#config",
  "heading": "Configuration",
  "text": "serve_config takes a Config record instead of the three arguments serve unpacks. Every field has a default, so only what differs from it is written: src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#cli",
  "heading": "Command line",
  "text": "@cli.run(app) is a whole server program: it reads the process arguments, builds the configuration, and serves. Nothing else is needed in main . src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::HttpR"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#tls",
  "heading": "TLS",
  "text": "serve_tls serves the same application over TLS 1.3. The certificate and the key are PEM files, read once at startup; a key that is not the certificate's is refused there rather than at the first handshake. src/main.mbt async fn main { let app : @moonasgi.AsgiA"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#websocket",
  "heading": "WebSocket",
  "text": "An upgrade is a request like any other until the handshake completes; then the scope is a websocket scope and the same receive/send pair speaks frames. ws:// and wss:// share one path. src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (scope, receive,"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#http2",
  "heading": "HTTP/2 and h2c",
  "text": "serve and serve_tls already speak HTTP/2 beside HTTP/1.1 on the same port: under TLS the client names h2 in ALPN; in the clear a connection that opens with the HTTP/2 preface is served HTTP/2, which is what --http2-prior-knowledge sends. Nothing in the applica"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#http3",
  "heading": "HTTP/3",
  "text": "HTTP/3 is the UDP half, at the same port number as the TCP listener. @quic.serve_config takes the same application and the same Config , plus the certificate, and runs both halves under one lifespan and one shutdown: src/main.mbt async fn main { let app : @moo"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#lifespan",
  "heading": "Lifespan",
  "text": "The application is invoked once before the listener binds, under a Lifespan scope, and once more on the way out. That is where a connection pool is opened and closed. Config.lifespan decides how strictly this is enforced: Mode Behaviour Auto run it; an applica"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#workers",
  "heading": "Workers",
  "text": "workers runs the program several times and shares the port between the copies. The process that was started serves nothing itself: it supervises. src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::Htt"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#proxy",
  "heading": "Proxy headers",
  "text": "Behind a load balancer the peer address is the balancer's, and the scheme is whatever the balancer terminated. proxy_headers makes the server believe X-Forwarded-For , X-Forwarded-Proto and Forwarded — but only from the peers named in forwarded_allow_ips . A r"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#extensions",
  "heading": "Extensions",
  "text": "An HTTP scope advertises the extensions the server honours, on all three versions: Extension What the server does http.response.early_hint a 103 Early Hints goes out before the answer, one link field per link http.response.trailers a response started with trai"
 },
 {
  "lang": "en",
  "page": "Guide",
  "url": "guide.html#targets",
  "heading": "Targets",
  "text": "Serving runs wherever the async sockets are available: the native and wasm backends, and the test suite runs on both. On js and wasm-gc the configuration, lifespan and proxy packages build and the serving packages are empty, so a program that only parses a con"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html",
  "heading": "API reference",
  "text": ""
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat",
  "heading": "mooncat 25 items",
  "text": "The entry points, re-exported: what a program that serves one application needs, and nothing it does not. Values fn fn http_date(Int64) -> String Format a Unix-epoch millisecond count as an HTTP-date in the IMF-fixdate form RFC 7231 §7.1.1.1 makes mandatory fo"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat-config",
  "heading": "mooncat/config 19 items",
  "text": "The configuration record, the access and error log, and the HTTP date every response can carry. Values fn fn http_date(Int64) -> String Format a Unix-epoch millisecond count as an HTTP-date in the IMF-fixdate form RFC 7231 §7.1.1.1 makes mandatory for a Date h"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat-lifespan",
  "heading": "mooncat/lifespan 6 items",
  "text": "The lifespan protocol: an application invoked once before the listener binds and once on the way out. Errors error suberror LifespanError Raised when the lifespan protocol stops the boot or reports a failed shutdown: the application sent lifespan.startup.faile"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat-proxy",
  "heading": "mooncat/proxy 1 items",
  "text": "The client and scheme a trusted proxy reports, and the decision to believe it. Values fn fn proxy_rewrite(Map[String, String], (String, Int32)?, String, trusted~ : Array[String], websocket? : Bool) -> ((String, Int32)?, String) Rewrite a request's client and s"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat-serve",
  "heading": "mooncat/serve 27 items",
  "text": "The accept loop, HTTP/1.1, HTTP/2, WebSocket, TLS, workers and the graceful shutdown. Values let let alpn : Array[String] The application protocols a TLS listener offers, in preference order: HTTP/2 first, as hypercorn and nginx do, falling back to HTTP/1.1. f"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat-cli",
  "heading": "mooncat/cli 10 items",
  "text": "The command line as a set of flags, and run(app) as a whole server program. Values fn fn command(version? : String) -> @argparse.Command The command line, as argparse describes it. Options carry no defaults on purpose: an absent flag must be distinguishable fr"
 },
 {
  "lang": "en",
  "page": "API reference",
  "url": "api.html#moonbitstack-mooncat-quic",
  "heading": "mooncat/quic 11 items",
  "text": "HTTP/3: the UDP socket, the datagram loop that routes by connection ID, and the request streams. Values fn fn now() -> Int64 The event loop's clock, in the microseconds the recovery and idle timers are measured in. @async.now() counts milliseconds since the ep"
 },
 {
  "lang": "en",
  "page": "Playground",
  "url": "playground.html",
  "heading": "How a connection is answered",
  "text": ""
 },
 {
  "lang": "zh",
  "page": "首页",
  "url": "zh/index.html",
  "heading": "mooncat",
  "text": ""
 },
 {
  "lang": "zh",
  "page": "首页",
  "url": "zh/index.html#what",
  "heading": "它做什么 一张图看完全部工作",
  "text": "mooncat 管服务器里与协议无关的那一半：套接字、连接、分段到达的请求、分段离开的响应。应用拿到 scope，以及读请求体、写响应的两个函数。路由到模板都属于应用。 客户端连到 mooncat，mooncat 把请求以 scope、receive、send 的形式交给应用。 客户端 curl、浏览器 mooncat 接受循环 · 每条连接一个任务 h1.1 h2 h3 ws tls 端口、限额、keep-alive、lifespan、停机 应用拿到的 scope、receive 与 send 你的应用 路由、J"
 },
 {
  "lang": "zh",
  "page": "首页",
  "url": "zh/index.html#protocols",
  "heading": "一个端口，每一代协议",
  "text": "选择发生在连接打开时：TLS 在握手定，明文看头几个字节。最后都落到同一处。 线上协议 由什么决定 应用看到什么 HTTP/1.1 明文里的请求行 一个 http scope；请求体一段一段到达 HTTPS TLS 握手，ALPN 里给出 h2 与 http/1.1 同一个 scope， scheme 为 https ，证书在 extensions 里 h2c 连接前言 PRI * HTTP/2.0 同一个 scope，每条流一个 HTTP/2 ALPN 应答 h2 每条流一个 scope，每条流一个任务 HTTP"
 },
 {
  "lang": "zh",
  "page": "首页",
  "url": "zh/index.html#start",
  "heading": "快速开始",
  "text": "shell moon add moonbitstack/mooncat moon add moonbitstack/moonasgi 应用是接受三个参数的异步函数，用两个事件作答： src/main.mbt /// 谁连上来就问候谁的服务器。 async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send( @moonasgi.Event::HttpResponseStart( status= 200 , header"
 },
 {
  "lang": "zh",
  "page": "首页",
  "url": "zh/index.html#recorded",
  "heading": "一次实录 moon run src/examples/09-tour",
  "text": "tour 示例起真实服务器，用真实客户端打，打印结果后停下。以下均为实录。 moon run src/examples/09-tour --target native $ moon run src/examples/09-tour --target native # configuration, as the command line reads it bind 127.0.0.1:12001 keep-alive 30000 ms retire after 100 trusted proxies 127.0.0."
 },
 {
  "lang": "zh",
  "page": "首页",
  "url": "zh/index.html#packages",
  "heading": "各个包",
  "text": "只答 TCP 的程序不会链进 UDP 那一半。拆分看链接成本，不看阅读顺序。 包 用来做什么 mooncat 入口函数的重导出，小程序的全部就是 @mooncat.serve mooncat/config Config 、访问与错误日志、HTTP 日期 mooncat/lifespan 监听之前的 startup，之后的 shutdown mooncat/proxy 受信代理报告的客户端与 scheme mooncat/serve 接受循环、HTTP/1.1、HTTP/2、WebSocket、TLS、多 worke"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html",
  "heading": "指南",
  "text": ""
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#first",
  "heading": "第一个服务器",
  "text": "装两个包：服务器与接口定义。 shell moon add moonbitstack/mooncat moon add moonbitstack/moonasgi ASGI 应用是接受三个参数的异步函数：scope、读请求体、写响应。 src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send( @moonasgi.Event::HttpResponseStart( status= 200"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#config",
  "heading": "配置",
  "text": "serve_config 收一个 Config 。字段都有默认值，只写不同的： src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::HttpResponseStart(status= 200 , headers=[], trailers= false )) send(@moonasgi.Event::HttpResponseBody(body=b "
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#cli",
  "heading": "命令行",
  "text": "@cli.run(app) 就是完整的服务器程序：读参数、拼配置、服务。 src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::HttpResponseStart(status= 200 , headers=[], trailers= false )) send(@moonasgi.Event::HttpResponseBody(body=b \"se"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#tls",
  "heading": "TLS",
  "text": "serve_tls 用 TLS 1.3 服务同一个应用。PEM 启动时读一次，私钥与证书不配对就在此时报错。 src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::HttpResponseStart(status= 200 , headers=[], trailers= false )) send(@moonasgi.Event::HttpRespo"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#websocket",
  "heading": "WebSocket",
  "text": "握手完成前是一次普通请求；之后 scope 变成 websocket ，同一对 receive/send 改说帧。 ws:// 与 wss:// 共用一条路径。 src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (scope, receive, send) => { guard scope is WebSocket(_) else { return } for ;; { match receive() { WebSocketConnect => s"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#http2",
  "heading": "HTTP/2 与 h2c",
  "text": "serve 与 serve_tls 已在同端口上说 HTTP/2：TLS 下由 ALPN 点名 h2 ，明文下看前言。应用不用改。 实录 — 同一个应用，无 TLS，无升级 $ curl --http2-prior-knowledge http://127.0.0.1:12000/ HTTP/2 200 content-type: text/plain; charset=utf-8 server: mooncat date: Mon, 02 Nov 2026 10:11:38 GMT hello from moon"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#http3",
  "heading": "HTTP/3",
  "text": "HTTP/3 在 UDP 上，端口号与 TCP 相同。 @quic.serve_config 收同一应用、同一份 Config 与证书： src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (scope, receive, send) => { guard scope is Http(http) else { return } send(@moonasgi.Event::HttpResponseStart(status= 200 , headers="
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#lifespan",
  "heading": "lifespan",
  "text": "应用在监听前与退出前各被调用一次，都在 Lifespan scope 下。连接池在这里开关。 Config.lifespan 决定严格程度： 模式 行为 Auto 照跑；在 lifespan scope 上失败的应用照样服务 On 照跑；在它上面失败，服务器就不启动 Off 完全不跑 src/main.mbt async fn main { let mut pool = \"\" let app : @moonasgi.AsgiApp = (scope, receive, send) => { match scope "
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#workers",
  "heading": "多 worker",
  "text": "workers 把程序跑若干份，共享一个端口。被启动的进程自己不服务，只监督。 src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (_scope, _receive, send) => { send(@moonasgi.Event::HttpResponseStart(status= 200 , headers=[], trailers= false )) send(@moonasgi.Event::HttpResponseBody(body=b "
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#proxy",
  "heading": "代理头",
  "text": "负载均衡后面，对端地址是均衡器的。 proxy_headers 让服务器相信 X-Forwarded-For 、 X-Forwarded-Proto 、 Forwarded ，但只对 forwarded_allow_ips 里的对端。 src/main.mbt async fn main { let app : @moonasgi.AsgiApp = (scope, receive, send) => { guard scope is Http(http) else { return } let who = mat"
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#extensions",
  "heading": "扩展",
  "text": "HTTP scope 声明支持的扩展，三代一致： 扩展 服务器做什么 http.response.early_hint 答案之前先发 103 Early Hints ，每个链接一个 link 字段 http.response.trailers 以 trailers=true 开始的响应改用 chunked，尾字段在最后一块里；HTTP/2 上是收尾的 HEADERS 帧 tls TLS 连接上： tls_version 、 cipher_suite ，以及服务器证书的 PEM src/main.mbt async "
 },
 {
  "lang": "zh",
  "page": "指南",
  "url": "zh/guide.html#targets",
  "heading": "目标平台",
  "text": "有异步套接字即可服务：native 与 wasm，测试两边都跑。js 与 wasm-gc 上只有配置、lifespan、代理三个包，服务包为空。QUIC 只在 native。 ← 首页 API 参考 →"
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html",
  "heading": "API 参考",
  "text": ""
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat",
  "heading": "mooncat 25 项",
  "text": "入口函数的重导出：服务一个应用需要的东西，不多一样。 值 fn fn http_date(Int64) -> String Format a Unix-epoch millisecond count as an HTTP-date in the IMF-fixdate form RFC 7231 §7.1.1.1 makes mandatory for a Date header: Sun, 06 Nov 1994 08:49:37 GMT , always GMT, always fixed-width. The"
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat-config",
  "heading": "mooncat/config 19 项",
  "text": "配置记录、访问与错误日志，以及每个响应可以带的 HTTP 日期。 值 fn fn http_date(Int64) -> String Format a Unix-epoch millisecond count as an HTTP-date in the IMF-fixdate form RFC 7231 §7.1.1.1 makes mandatory for a Date header: Sun, 06 Nov 1994 08:49:37 GMT , always GMT, always fixed-widt"
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat-lifespan",
  "heading": "mooncat/lifespan 6 项",
  "text": "lifespan 协议：应用在监听前被调用一次，退出前再一次。 错误 error suberror LifespanError Raised when the lifespan protocol stops the boot or reports a failed shutdown: the application sent lifespan.startup.failed or lifespan.shutdown.failed , or it raised under Lifespan::On . Carries "
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat-proxy",
  "heading": "mooncat/proxy 1 项",
  "text": "受信代理报告的客户端与 scheme，以及要不要相信它。 值 fn fn proxy_rewrite(Map[String, String], (String, Int32)?, String, trusted~ : Array[String], websocket? : Bool) -> ((String, Int32)?, String) Rewrite a request's client and scheme from a trusted proxy's forwarding headers (← uvic"
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat-serve",
  "heading": "mooncat/serve 27 项",
  "text": "接受循环、HTTP/1.1、HTTP/2、WebSocket、TLS、多 worker 与优雅停机。 值 let let alpn : Array[String] The application protocols a TLS listener offers, in preference order: HTTP/2 first, as hypercorn and nginx do, falling back to HTTP/1.1. fn async fn read_frame(&@io.Reader, clien"
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat-cli",
  "heading": "mooncat/cli 10 项",
  "text": "命令行参数，以及把 run(app) 当作完整的服务器程序。 值 fn fn command(version? : String) -> @argparse.Command The command line, as argparse describes it. Options carry no defaults on purpose: an absent flag must be distinguishable from one that happens to match the default, because "
 },
 {
  "lang": "zh",
  "page": "API 参考",
  "url": "zh/api.html#moonbitstack-mooncat-quic",
  "heading": "mooncat/quic 11 项",
  "text": "HTTP/3：UDP 套接字、按连接 ID 分发的数据报循环，以及请求流。 值 fn fn now() -> Int64 The event loop's clock, in the microseconds the recovery and idle timers are measured in. @async.now() counts milliseconds since the epoch. fn async fn serve(String, @conn.Endpoint[@socket.Addr], tic"
 },
 {
  "lang": "zh",
  "page": "演示",
  "url": "zh/playground.html",
  "heading": "一条连接是怎么被答掉的",
  "text": ""
 }
];
