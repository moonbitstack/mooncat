#!/usr/bin/env bash
# Regenerate the self-signed localhost test certificate used by the HTTPS
# integration tests (src/certs/). Throwaway localhost material — not a secret.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p src/certs
export MSYS_NO_PATHCONV=1

openssl req -x509 -newkey rsa:2048 -keyout src/certs/key.pem -out src/certs/cert.pem \
  -days 3650 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "wrote src/certs/cert.pem src/certs/key.pem"

# The same pair in the other two forms a server is handed: the key encrypted under a password
# (PKCS#8, PBES2), and both in one PKCS#12 file. The password is "moon" for both.
openssl pkcs8 -topk8 -in src/certs/key.pem -out src/certs/key.enc.pem -v2 aes-256-cbc -passout pass:moon
openssl pkcs12 -export -in src/certs/cert.pem -inkey src/certs/key.pem -out src/certs/server.p12   -name localhost -passout pass:moon
echo "wrote src/certs/key.enc.pem src/certs/server.p12"
