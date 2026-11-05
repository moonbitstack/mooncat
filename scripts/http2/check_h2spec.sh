#!/bin/sh
# h2spec, the HTTP/2 conformance tester, against a real server: in the clear, over TLS, and in clear
# again with its strict checks on. Every case has to pass. Needs Docker and openssl.
#
#     sh scripts/http2/check_h2spec.sh
#
# The server is `src/examples/14-http2-server`. The container shares the host's network so that
# 127.0.0.1:12000 reaches it.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
cd "$root"

moon build src/examples/14-http2-server --target native
server=$(find _build/native/debug/build -type f \( -name 14-http2-server -o -name 14-http2-server.exe \) | head -1)

work=$(mktemp -d)
pid=
stop() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=
  fi
}
trap 'stop; rm -rf "$work"' EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$work/key.pem" \
  -out "$work/cert.pem" -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null

spec() {
  docker run --rm --network host summerwind/h2spec:2.6.0 -h 127.0.0.1 -p 12000 -o 3 "$@"
}

"$server" > /dev/null 2>&1 &
pid=$!
sleep 1
spec
spec --strict
stop

"$server" "$work/cert.pem" "$work/key.pem" > /dev/null 2>&1 &
pid=$!
sleep 1
spec -t -k
stop
