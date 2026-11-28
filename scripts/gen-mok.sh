#!/usr/bin/env bash
# Creates the Machine Owner Key (MOK) used to sign GRUB and the kernel for Secure Boot.
#   ./scripts/gen-mok.sh [directory]     default: ./secureboot
# MOK.key  private key (keep it secret, never commit it)
# MOK.crt  certificate (PEM), used by sbsign
# MOK.cer  certificate (DER), the one you enroll from MokManager ("Enroll key from disk")
# RSA 2048: shim does not reliably accept bigger keys in the MOK list.
set -euo pipefail

DIR=${1:-secureboot}
CN=${CN:-AstroArch Machine Owner Key}

mkdir -p "$DIR"
if [ -e "$DIR/MOK.key" ]; then
  echo "$DIR/MOK.key already exists: not overwritten" >&2
  exit 1
fi

openssl req -newkey rsa:2048 -nodes -keyout "$DIR/MOK.key" -new -x509 -sha256 -days 3650 \
  -subj "/CN=${CN}/" -out "$DIR/MOK.crt"
openssl x509 -outform DER -in "$DIR/MOK.crt" -out "$DIR/MOK.cer"
chmod 600 "$DIR/MOK.key"
echo "Keys written in $DIR/ (MOK.key stays secret)."
