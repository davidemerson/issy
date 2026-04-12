//! Ed25519 public key used to verify sha256sums.txt on auto-update.
//!
//! Bootstrap (one-time, per repo):
//!   zig build keygen
//! Follow the printed instructions to:
//!   1. Save the printed PEM private key as a GitHub Actions Secret named
//!      UPDATE_SIGNING_KEY.
//!   2. Replace the `public_key` bytes below with the printed array and
//!      commit this file.
//!
//! An all-zero key is treated as "not configured": notify-only mode still
//! works, but auto-apply refuses to stage any binary. This is the default
//! state of a fresh checkout.
//!
//! Rotation: generate a new key with `zig build keygen`, replace the
//! secret, replace the bytes here, commit. Old releases remain verifiable
//! against the old key — but since auto-update only compares against
//! sha256sums.txt from the latest release, there is no backward
//! compatibility window to manage.

pub const public_key: [32]u8 = .{
    0xd3, 0xe0, 0x5f, 0x42, 0x90, 0x18, 0xa4, 0xbe,
    0x84, 0xf1, 0x8a, 0xa7, 0x9f, 0x83, 0x43, 0xeb,
    0x11, 0xae, 0xde, 0xa1, 0xc6, 0xe1, 0x46, 0x75,
    0x79, 0x66, 0x74, 0x4c, 0x24, 0xec, 0xb5, 0xb1,
};

pub fn isConfigured() bool {
    for (public_key) |b| {
        if (b != 0) return true;
    }
    return false;
}
