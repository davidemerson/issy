//! One-shot keypair generator for issy's auto-update signing.
//!
//! Prints:
//!   1. A PKCS#8 PEM private key — paste into a GitHub Actions Secret
//!      named UPDATE_SIGNING_KEY (the CI signing step reads this).
//!   2. The corresponding 32-byte Ed25519 public key as a Zig array
//!      literal — paste into src/update_key.zig and commit it.
//!
//! The private key is never written to disk. Run with output captured:
//!   zig build keygen > /tmp/keys.txt
//! and delete /tmp/keys.txt after you have saved both halves.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main() !void {
    const kp = Ed25519.KeyPair.generate();

    // Extract the raw 32-byte seed from the secret key. Ed25519 secret_key
    // is seed || public_key (64 bytes total); the first 32 are the seed.
    const sk_bytes = kp.secret_key.toBytes();
    const seed = sk_bytes[0..32].*;
    const pk_bytes = kp.public_key.toBytes();

    // Build the PKCS#8 PrivateKeyInfo DER for Ed25519.
    // See RFC 8410 §7. The full structure is 48 bytes:
    //   30 2e                             SEQUENCE, length 46
    //     02 01 00                        INTEGER 0 (version)
    //     30 05 06 03 2b 65 70            AlgorithmIdentifier { id-Ed25519 }
    //     04 22 04 20 <32 bytes>          OCTET STRING ( OCTET STRING ( seed ) )
    const pkcs8_prefix = [_]u8{
        0x30, 0x2e,
        0x02, 0x01, 0x00,
        0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
        0x04, 0x22, 0x04, 0x20,
    };
    var der: [48]u8 = undefined;
    @memcpy(der[0..16], &pkcs8_prefix);
    @memcpy(der[16..48], &seed);

    var pem_body: [64]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&pem_body, &der);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    try w.writeAll(
        \\issy auto-update signing keypair
        \\================================
        \\
        \\STEP 1: Private key (PKCS#8 PEM)
        \\--------------------------------
        \\Save this as a GitHub Actions Secret in your repository under
        \\Settings → Secrets and variables → Actions → New repository secret.
        \\Name:  UPDATE_SIGNING_KEY
        \\Value: everything between the BEGIN and END lines, inclusive.
        \\
        \\-----BEGIN PRIVATE KEY-----
        \\
    );
    try w.writeAll(&pem_body);
    try w.writeAll(
        \\
        \\-----END PRIVATE KEY-----
        \\
        \\
        \\STEP 2: Public key (Zig array literal)
        \\--------------------------------------
        \\Open src/update_key.zig and replace the `public_key` array with:
        \\
        \\pub const public_key: [32]u8 = .{
        \\
    );
    var i: usize = 0;
    while (i < pk_bytes.len) : (i += 1) {
        if (i % 8 == 0) try w.writeAll("    ");
        try w.print("0x{x:0>2},", .{pk_bytes[i]});
        if ((i + 1) % 8 == 0) {
            try w.writeAll("\n");
        } else {
            try w.writeAll(" ");
        }
    }
    try w.writeAll(
        \\};
        \\
        \\Then commit src/update_key.zig. The private key above never needs
        \\to be stored locally; once it's in the GitHub secret, you can
        \\forget it. To rotate, re-run `zig build keygen`, replace both.
        \\
    );
    try w.flush();
}
