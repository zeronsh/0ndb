const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Aegis = std.crypto.aead.aegis.Aegis256;
const Blake3 = std.crypto.hash.Blake3;

pub const Key = [Aegis.key_length]u8;
pub const Nonce = [Aegis.nonce_length]u8;
pub const Tag = [Aegis.tag_length]u8;
pub const Hash = [32]u8;
pub const Mac = [32]u8;

pub const ENVELOPE_OVERHEAD: usize = Aegis.nonce_length + Aegis.tag_length;

pub fn hashBytes(data: []const u8) Hash {
    var out: Hash = undefined;
    Blake3.hash(data, &out, .{});
    return out;
}

pub fn deriveTopicKey(master: Key, topic_id: Hash) Key {
    var h = Blake3.init(.{ .key = master });
    h.update("0ndb-e2ee-topic-v2");
    h.update(&topic_id);
    var full: Hash = undefined;
    h.final(&full);
    return full;
}

pub fn deriveBlobLookupId(master: Key, topic_id: Hash, local_oid: Hash) Hash {
    var h = Blake3.init(.{ .key = master });
    h.update("0ndb-relay-blob-v2");
    h.update(&topic_id);
    h.update(&local_oid);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub fn deriveCapabilityToken(secret: [32]u8, topic_id: Hash, perms: u8, expires_ms: u64) Mac {
    var h = Blake3.init(.{ .key = secret });
    h.update("0ndb-cap-v1");
    h.update(&topic_id);
    h.update(&[_]u8{perms});
    var exp_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &exp_bytes, expires_ms, .little);
    h.update(&exp_bytes);
    var mac: Mac = undefined;
    h.final(&mac);
    return mac;
}

pub fn verifyCapabilityToken(secret: [32]u8, topic_id: Hash, perms: u8, expires_ms: u64, provided: Mac, now_ms: u64) bool {
    if (expires_ms != 0 and now_ms > expires_ms) return false;
    const expected = deriveCapabilityToken(secret, topic_id, perms, expires_ms);
    return std.crypto.timing_safe.eql(Mac, expected, provided);
}

pub fn randomNonce(io: Io) Nonce {
    var nonce: Nonce = undefined;
    io.random(&nonce);
    return nonce;
}

pub fn seal(
    allocator: Allocator,
    key: Key,
    aad: []const u8,
    plaintext: []const u8,
    nonce: Nonce,
) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, ENVELOPE_OVERHEAD + plaintext.len);
    @memcpy(out[0..Aegis.nonce_length], &nonce);
    var tag: Tag = undefined;
    Aegis.encrypt(
        out[ENVELOPE_OVERHEAD..],
        &tag,
        plaintext,
        aad,
        nonce,
        key,
    );
    @memcpy(out[Aegis.nonce_length..ENVELOPE_OVERHEAD], &tag);
    return out;
}

pub fn sealRandom(
    allocator: Allocator,
    io: Io,
    key: Key,
    aad: []const u8,
    plaintext: []const u8,
) Allocator.Error![]u8 {
    return seal(allocator, key, aad, plaintext, randomNonce(io));
}

pub fn open(
    allocator: Allocator,
    key: Key,
    aad: []const u8,
    envelope: []const u8,
) (Allocator.Error || error{ InvalidEnvelope, AuthenticationFailed })![]u8 {
    if (envelope.len < ENVELOPE_OVERHEAD) return error.InvalidEnvelope;
    const nonce: Nonce = envelope[0..Aegis.nonce_length].*;
    const tag: Tag = envelope[Aegis.nonce_length..ENVELOPE_OVERHEAD].*;
    const ciphertext = envelope[ENVELOPE_OVERHEAD..];
    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    Aegis.decrypt(plaintext, ciphertext, tag, aad, nonce, key) catch return error.AuthenticationFailed;
    return plaintext;
}
