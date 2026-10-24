#!/usr/bin/env bash
# Regenerate the self-signed localhost test certificate used by the HTTPS
# integration tests (certs/). Throwaway localhost material — not a secret.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs
export MSYS_NO_PATHCONV=1

openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem \
  -days 3650 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "wrote certs/cert.pem certs/key.pem"
