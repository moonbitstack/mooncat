name = "moonbitstack/mooncat"

version = "0.18.6"

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

description = "A native ASGI server for MoonBit."

preferred_target = "native"

import {
  "moonbitstack/moonasgi@0.10.0",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonbase@0.4.0",
  "moonbitstack/mooncrypt@0.4.3",
  "moonbitstack/mooncred@0.6.4",
  "moonbitstack/moonlog@0.1.0",
  "moonbitstack/moontls@0.9.3",
  "moonbitstack/moonquic@0.3.3",
  "moonbitstack/moonnet@0.1.3",
  "moonbitstack/moonhttp@0.15.1",
  "moonbitstack/moonurl@0.2.0",
  "moonbitstack/moondate@0.1.0",
  "moonbitstack/moonvar@0.2.0",
}

source = "src"
