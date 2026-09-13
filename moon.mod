name = "Lfan-ke/mooncat"

version = "0.8.1"

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
  "Lfan-ke/moonasgi@0.8.0",
  "moonbitlang/async@0.20.3",
  "Lfan-ke/moonapi@0.7.0",
  "Lfan-ke/moonrpc@0.9.0",
}
