name = "moonbitstack/mooncat"

version = "0.19.2"

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
  "moonbitstack/mooncrypt@0.4.8",
  "moonbitstack/mooncred@0.6.7",
  "moonbitstack/moonlog@0.1.4",
  "moonbitstack/moontls@0.9.12",
  "moonbitstack/moonquic@0.3.9",
  "moonbitstack/moonnet@0.1.8",
  "moonbitstack/moonhttp@0.15.4",
  "moonbitstack/moonurl@0.2.3",
  "moonbitstack/moondate@0.1.2",
  "moonbitstack/moonvar@0.2.0",
}

source = "src"
