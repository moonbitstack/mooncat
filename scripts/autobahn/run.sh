#!/bin/sh
# The Autobahn conformance run against mooncat's WebSocket bridge: framing, fragments, UTF-8, close
# handling, limits and permessage-deflate. Needs Docker.
#
#     sh scripts/autobahn/run.sh
#
# The endpoint is `src/examples/05-websocket-echo`. The container shares the host's network so that
# ws://127.0.0.1:9001 reaches it.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
cd "$root"

# Release, or the compressed cases take hours: deflate is an order of magnitude slower in a debug build.
moon build src/examples/05-websocket-echo --target native --release
./_build/native/release/build/examples/05-websocket-echo/05-websocket-echo.exe &
endpoint=$!
trap 'kill $endpoint 2>/dev/null || true' EXIT
sleep 1

mkdir -p _build/autobahn
docker run --rm --network host \
  -v "$here:/config:ro" \
  -v "$root/_build/autobahn:/reports" \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/fuzzingclient.json

python3 "$here/summary.py" _build/autobahn/clients/index.json
