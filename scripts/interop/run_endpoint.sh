#!/usr/bin/env bash
# What the interoperability runner starts inside the image. It sets ROLE, TESTCASE, REQUESTS,
# DOWNLOADS and WWW; this turns them into the knobs the server reads, and says plainly which role
# it cannot be.
#
#   docker run --rm -e ROLE=server -e TESTCASE=retry ... mooncat-interop
set -euo pipefail

if [ "${ROLE:-}" != "server" ]; then
  echo "mooncat is a server: the client role is not offered by this image" >&2
  exit 1
fi

export MOONCAT_PORT=443
export MOONCAT_RETRY=0
export MOONCAT_EARLY=off
export DOWNLOADS="${DOWNLOADS:-${DOWNLOAD:-/downloads}}"
export SSLKEYLOGFILE="${SSLKEYLOGFILE:-/logs/keys.log}"

case "${TESTCASE:-}" in
  # A client that has just been sent a Retry may not send 0-RTT under a token it has not been
  # given (RFC 9000 §8.1), so these two cases cannot be the same run.
  retry) export MOONCAT_RETRY=1 ;;
  # 0-RTT is off by default: only the case whose point is early data turns it on.
  zerortt) export MOONCAT_EARLY=accept ;;
  # An unknown case is not answered at all, as the runner's contract asks.
  handshake | transfer | resumption | chacha20 | keyupdate | v2 | migration | http3) ;;
  *) echo "unsupported test case: ${TESTCASE:-}" >&2; exit 127 ;;
esac

if [ -n "${SSLKEYLOGFILE:-}" ]; then
  mkdir -p "$(dirname "$SSLKEYLOGFILE")"
  : >"$SSLKEYLOGFILE"
fi

exec mooncat-interop
