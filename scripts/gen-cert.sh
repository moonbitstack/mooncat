#!/usr/bin/env bash
# Regenerate the self-signed localhost test certificate used by the HTTPS
# integration tests (certs/). Emits both forms the moonbitlang/async TLS layer
# needs across platforms: PEM (OpenSSL backend, Linux/macOS) and PKCS#12
# (SChannel backend, Windows). Throwaway localhost material — not a secret.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs
export MSYS_NO_PATHCONV=1

openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem \
  -days 3650 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

# Empty export password: the test loads the bundle with no passphrase.
openssl pkcs12 -export -inkey certs/key.pem -in certs/cert.pem \
  -out certs/dev.pfx -passout pass:

echo "wrote certs/cert.pem certs/key.pem certs/dev.pfx"
