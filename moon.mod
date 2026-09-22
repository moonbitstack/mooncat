name = "moonbitstack/mooncat"

version = "0.10.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/mooncat"

license = "Apache-2.0"

keywords = [
  "asgi",
  "server",
  "uvicorn",
  "http",
  "websocket",
  "moonbit",
  "native",
]

description = "mooncat — a native ASGI 3.0 server for MoonBit (← uvicorn), built on moonbitlang/async and the moonasgi SEAM."

preferred_target = "native"

import {
  "moonbitstack/moonasgi@0.10.0",
  "moonbitlang/async@0.20.3",
  "moonbitstack/moonbase@0.4.0",
  "moonbitstack/mooncrypt@0.3.0",
  "moonbitstack/mooncred@0.6.0",
  "moonbitstack/moonlog@0.1.0",
  "moonbitstack/moontls@0.5.0",
  "moonbitstack/moonapi@0.11.0",
  "moonbitstack/moonrpc@0.14.0",
}
