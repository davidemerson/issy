#!/usr/bin/env sh
# Dump the Ed25519 update-signing public key as PEM.
#
# Reads the 32 raw key bytes from src/update_key.zig and wraps them in the
# standard SubjectPublicKeyInfo DER encoding for Ed25519 (OID 1.3.101.112),
# then base64 + PEM headers.
#
# Use this after rotating UPDATE_SIGNING_KEY / src/update_key.zig to
# regenerate the PEM block embedded in install.sh.
#
#   sh tools/dump_pubkey.sh > /tmp/pubkey.pem
#   openssl pkey -pubin -in /tmp/pubkey.pem -text -noout   # sanity-check

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_FILE="$SCRIPT_DIR/../src/update_key.zig"

if [ ! -f "$KEY_FILE" ]; then
    echo "error: $KEY_FILE not found" >&2
    exit 1
fi

python3 - "$KEY_FILE" <<'PY'
import base64, re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
m = re.search(r"public_key:\s*\[32\]u8\s*=\s*\.\{([^}]*)\}", src, re.S)
if not m:
    sys.exit("could not find public_key array in " + path)
hex_bytes = re.findall(r"0x([0-9a-fA-F]{2})", m.group(1))
if len(hex_bytes) != 32:
    sys.exit(f"expected 32 bytes, found {len(hex_bytes)}")
raw = bytes(int(h, 16) for h in hex_bytes)
if raw == bytes(32):
    sys.exit("public key is all zeros — run `zig build keygen` first")
der_prefix = bytes.fromhex("302a300506032b6570032100")
der = der_prefix + raw
b64 = base64.b64encode(der).decode()
print("-----BEGIN PUBLIC KEY-----")
print(b64)
print("-----END PUBLIC KEY-----")
PY
