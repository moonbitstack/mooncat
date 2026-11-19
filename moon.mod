name = "moonbitstack/mooncat"

version = "0.21.2"

readme = "README.md"

repository = "https://github.com/moonbitstack/mooncat"

license = "Apache-2.0"

keywords = [
  "asgi",
  "server",
  "web-server",
  "http-server",
  "uvicorn",
  "hypercorn",
  "http",
  "http1",
  "http2",
  "h2c",
  "http3",
  "quic",
  "quic-v1",
  "0-rtt",
  "zero-rtt",
  "early-data",
  "rfc8470",
  "rfc9000",
  "rfc9114",
  "retry",
  "resumption",
  "interop",
  "interoperability",
  "websocket",
  "tls",
  "https",
  "alpn",
  "workers",
  "proxy-headers",
  "forwarded",
  "unix-socket",
  "native",
  "cli",
  "moonbit",
]

description = "A native ASGI server for MoonBit."

preferred_target = "native"

import {
  "moonbitstack/moonasgi@0.11.3",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonbase@0.5.1",
  "moonbitstack/mooncrypt@0.5.2",
  "moonbitstack/mooncred@0.8.1",
  "moonbitstack/moonjson@0.5.1",
  "moonbitstack/moonlog@0.2.1",
  "moonbitstack/moontls@0.10.4",
  "moonbitstack/moonquic@0.4.1",
  "moonbitstack/moonnet@0.2.2",
  "moonbitstack/moonhttp@0.16.1",
  "moonbitstack/moonurl@0.3.1",
  "moonbitstack/moondate@0.2.1",
  "moonbitstack/moonvar@0.3.1",
}

source = "src"
