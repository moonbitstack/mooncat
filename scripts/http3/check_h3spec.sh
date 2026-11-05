#!/bin/sh
# h3spec, the HTTP/3 conformance tester, against a real server: the "HTTP/3 servers" section of
# h3spec 0.1.14, every case of it. Needs curl and a Linux x86-64 host to run the pinned binary.
#
#     sh scripts/http3/check_h3spec.sh
#
# The transport section belongs to the QUIC layer and is not run here. The server is
# `src/examples/07-http3`, which serves HTTP/1.1, HTTP/2 and HTTP/3 on port 12000 under the
# repository's test certificate; h3spec is told not to validate it.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
cd "$root"

version=0.1.14
case $(uname -s)-$(uname -m) in
  Linux-x86_64) ;;
  *)
    echo "h3spec ships a Linux x86-64 binary only; this host is $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

moon build src/examples/07-http3 --target native
server=$(find _build/native/debug/build -type f \( -name 07-http3 -o -name 07-http3.exe \) | head -1)

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

curl -fsSL -o "$work/h3spec" \
  "https://github.com/kazu-yamamoto/h3spec/releases/download/v$version/h3spec-linux-x86_64"
chmod +x "$work/h3spec"

# The example reads its certificate from the repository, so it starts from the root.
"$server" > /dev/null 2>&1 &
pid=$!
sleep 1

"$work/h3spec" 127.0.0.1 12000 --no-validate -t 4000 --match "HTTP/3 servers"
