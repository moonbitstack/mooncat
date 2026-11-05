name = "moonbitstack/mooncat"

version = "0.19.5"

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
  "moonbitstack/moonasgi@0.10.6",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonbase@0.4.3",
  "moonbitstack/mooncrypt@0.4.11",
  "moonbitstack/mooncred@0.6.9",
  "moonbitstack/moonlog@0.1.6",
  "moonbitstack/moontls@0.9.14",
  "moonbitstack/moonquic@0.3.11",
  "moonbitstack/moonnet@0.1.10",
  "moonbitstack/moonhttp@0.15.8",
  "moonbitstack/moonurl@0.2.5",
  "moonbitstack/moondate@0.1.4",
  "moonbitstack/moonvar@0.2.1",
}

source = "src"
