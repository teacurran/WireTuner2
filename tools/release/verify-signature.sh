#!/usr/bin/env bash
# `verify-signature.sh FILE SIGNATURE PUBLIC_KEY`: checks a Sparkle EdDSA signature (base64) of FILE
# against a base64 Ed25519 public key -- the SUPublicEDKey an installed app will check it with --
# using an OpenSSL that has Ed25519 (Homebrew's; macOS's LibreSSL is tried too).  Exit 0 when it
# verifies, 1 when it does not, 2 when no such OpenSSL is available (the caller decides).
set -euo pipefail
file="$1" signature="$2" public_key="$3"
work="$(mktemp -d "${TMPDIR:-/tmp}/verify-signature.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# SubjectPublicKeyInfo for Ed25519 is a fixed 12-byte prefix and the raw 32-byte key.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; printf '%s' "$public_key" | base64 -d; } >"$work/key.der"
[ "$(stat -f %z "$work/key.der")" = 44 ] || { echo "verify-signature: the public key is not 32 bytes" >&2; exit 1; }
printf '%s' "$signature" | base64 -d >"$work/signature"

for openssl in "${WT_OPENSSL:-}" /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
    [ -n "$openssl" ] && [ -x "$openssl" ] || continue
    "$openssl" pkey -pubin -inform DER -in "$work/key.der" -noout >/dev/null 2>&1 || continue
    if "$openssl" pkeyutl -verify -pubin -inkey "$work/key.der" -keyform DER -rawin -in "$file" -sigfile "$work/signature" >/dev/null 2>&1; then
        exit 0
    fi
    exit 1
done
echo "verify-signature: no OpenSSL with Ed25519 (brew install openssl@3)" >&2
exit 2
