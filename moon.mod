name = "moonbitstack/mooncat"

version = "0.19.8"

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
  "moonbitstack/moonasgi@0.10.8",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonbase@0.4.5",
  "moonbitstack/mooncrypt@0.4.15",
  "moonbitstack/mooncred@0.6.14",
  "moonbitstack/moonjson@0.4.4",
  "moonbitstack/moonlog@0.1.7",
  "moonbitstack/moontls@0.9.16",
  "moonbitstack/moonquic@0.3.14",
  "moonbitstack/moonnet@0.1.12",
  "moonbitstack/moonhttp@0.15.10",
  "moonbitstack/moonurl@0.2.6",
  "moonbitstack/moondate@0.1.7",
  "moonbitstack/moonvar@0.2.2",
}

source = "src"
