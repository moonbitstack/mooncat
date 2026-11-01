name = "moonbitstack/mooncat"

version = "0.19.0"

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
  "moonbitstack/moonasgi@0.10.4",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moonbase@0.4.2",
  "moonbitstack/mooncrypt@0.4.6",
  "moonbitstack/mooncred@0.6.7",
  "moonbitstack/moonlog@0.1.3",
  "moonbitstack/moontls@0.9.7",
  "moonbitstack/moonquic@0.3.8",
  "moonbitstack/moonnet@0.1.7",
  "moonbitstack/moonhttp@0.15.3",
  "moonbitstack/moonurl@0.2.3",
  "moonbitstack/moondate@0.1.0",
  "moonbitstack/moonvar@0.2.0",
}

source = "src"
