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
pub const CommitTag = [32]u8;

pub const ENVELOPE_VERSION: u8 = 2;
pub const COMMIT_TAG_LEN: usize = 32;
pub const ENVELOPE_OVERHEAD: usize = 1 + Aegis.nonce_length + COMMIT_TAG_LEN + Aegis.tag_length;

pub fn zeroize(buf: []u8) void {
    std.crypto.secureZero(u8, buf);
}

pub fn hashBytes(data: []const u8) Hash {
    var out: Hash = undefined;
    Blake3.hash(data, &out, .{});
    return out;
}

pub fn deriveKeyId(key: Key) Hash {
    var h = Blake3.init(.{ .key = key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-key-id-v2");
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub fn deriveTopicKey(master: Key, topic_id: Hash) Key {
    var h = Blake3.init(.{ .key = master });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-e2ee-topic-v2");
    h.update(&topic_id);
    var full: Hash = undefined;
    h.final(&full);
    return full;
}

pub fn deriveBlobLookupId(master: Key, topic_id: Hash, local_oid: Hash) Hash {
    var h = Blake3.init(.{ .key = master });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-relay-blob-v2");
    h.update(&topic_id);
    h.update(&local_oid);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub fn deriveCapabilityToken(secret: [32]u8, topic_id: Hash, perms: u8, expires_ms: u64) Mac {
    var h = Blake3.init(.{ .key = secret });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-cap-v1");
    h.update(&topic_id);
    h.update(&[_]u8{perms});
    var exp_bytes: [8]u8 = undefined;
    defer zeroize(&exp_bytes);
    std.mem.writeInt(u64, &exp_bytes, expires_ms, .little);
    h.update(&exp_bytes);
    var mac: Mac = undefined;
    h.final(&mac);
    return mac;
}

pub fn verifyCapabilityToken(secret: [32]u8, topic_id: Hash, perms: u8, expires_ms: u64, provided: Mac, now_ms: u64) bool {
    if (expires_ms != 0 and now_ms > expires_ms) return false;
    var expected = deriveCapabilityToken(secret, topic_id, perms, expires_ms);
    defer zeroize(&expected);
    return std.crypto.timing_safe.eql(Mac, expected, provided);
}

pub fn randomNonce(io: Io) Nonce {
    var nonce: Nonce = undefined;
    io.random(&nonce);
    return nonce;
}

fn deriveEnvelopeSubkey(key: Key, version: u8, nonce: Nonce) Key {
    var h = Blake3.init(.{ .key = key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-aegis256-enc-v2");
    h.update(&[_]u8{version});
    h.update(&nonce);
    var out: Key = undefined;
    h.final(&out);
    return out;
}

fn computeBoundAad(key_id: Hash, version: u8, aad: []const u8) Hash {
    var h = Blake3.init(.{});
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-aegis256-aad-v2");
    h.update(&[_]u8{version});
    h.update(&key_id);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, aad.len, .little);
    h.update(&len_buf);
    h.update(aad);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

fn computeCommitment(key: Key, version: u8, nonce: Nonce, tag: Tag, aad: []const u8) CommitTag {
    var aad_hash = hashBytes(aad);
    defer zeroize(&aad_hash);
    var h = Blake3.init(.{ .key = key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-aegis256-cmt-v2");
    h.update(&[_]u8{version});
    h.update(&nonce);
    h.update(&tag);
    h.update(&aad_hash);
    var out: CommitTag = undefined;
    h.final(&out);
    return out;
}

fn sealInternal(
    allocator: Allocator,
    key: Key,
    aad: []const u8,
    plaintext: []const u8,
    nonce: Nonce,
) Allocator.Error![]u8 {
    var enc_key = deriveEnvelopeSubkey(key, ENVELOPE_VERSION, nonce);
    defer zeroize(&enc_key);
    var key_id = deriveKeyId(key);
    defer zeroize(&key_id);
    var bound_aad = computeBoundAad(key_id, ENVELOPE_VERSION, aad);
    defer zeroize(&bound_aad);

    const out = try allocator.alloc(u8, ENVELOPE_OVERHEAD + plaintext.len);
    out[0] = ENVELOPE_VERSION;
    const nonce_end = 1 + Aegis.nonce_length;
    const commit_end = nonce_end + COMMIT_TAG_LEN;
    @memcpy(out[1..nonce_end], &nonce);

    var tag: Tag = undefined;
    defer zeroize(&tag);
    Aegis.encrypt(
        out[ENVELOPE_OVERHEAD..],
        &tag,
        plaintext,
        &bound_aad,
        nonce,
        enc_key,
    );

    var commit_tag = computeCommitment(key, ENVELOPE_VERSION, nonce, tag, aad);
    defer zeroize(&commit_tag);
    @memcpy(out[nonce_end..commit_end], &commit_tag);
    @memcpy(out[commit_end..ENVELOPE_OVERHEAD], &tag);
    return out;
}

pub fn sealRandom(
    allocator: Allocator,
    io: Io,
    key: Key,
    aad: []const u8,
    plaintext: []const u8,
) Allocator.Error![]u8 {
    var nonce = randomNonce(io);
    defer zeroize(&nonce);
    return sealInternal(allocator, key, aad, plaintext, nonce);
}

pub fn sealWithDerivedNonce(
    allocator: Allocator,
    key: Key,
    context: []const u8,
    aad: []const u8,
    plaintext: []const u8,
) Allocator.Error![]u8 {
    var h = Blake3.init(.{ .key = key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-derived-nonce-v1");
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, context.len, .little);
    h.update(&len_buf);
    h.update(context);
    std.mem.writeInt(u64, &len_buf, aad.len, .little);
    h.update(&len_buf);
    h.update(aad);
    var nonce: Nonce = undefined;
    defer zeroize(&nonce);
    h.final(&nonce);
    return sealInternal(allocator, key, aad, plaintext, nonce);
}

pub fn sealDeterministicForTest(
    allocator: Allocator,
    key: Key,
    aad: []const u8,
    plaintext: []const u8,
    nonce: Nonce,
) Allocator.Error![]u8 {
    return sealInternal(allocator, key, aad, plaintext, nonce);
}

pub fn open(
    allocator: Allocator,
    key: Key,
    aad: []const u8,
    envelope: []const u8,
) (Allocator.Error || error{ InvalidEnvelope, AuthenticationFailed })![]u8 {
    if (envelope.len < ENVELOPE_OVERHEAD) return error.InvalidEnvelope;
    const version = envelope[0];
    if (version != ENVELOPE_VERSION) return error.InvalidEnvelope;

    const nonce_end = 1 + Aegis.nonce_length;
    const commit_end = nonce_end + COMMIT_TAG_LEN;
    const nonce: Nonce = envelope[1..nonce_end].*;
    const provided_commit: CommitTag = envelope[nonce_end..commit_end].*;
    const tag: Tag = envelope[commit_end..ENVELOPE_OVERHEAD].*;
    const ciphertext = envelope[ENVELOPE_OVERHEAD..];

    var expected_commit = computeCommitment(key, version, nonce, tag, aad);
    defer zeroize(&expected_commit);
    if (!std.crypto.timing_safe.eql(CommitTag, expected_commit, provided_commit)) {
        return error.AuthenticationFailed;
    }

    var enc_key = deriveEnvelopeSubkey(key, version, nonce);
    defer zeroize(&enc_key);
    var key_id = deriveKeyId(key);
    defer zeroize(&key_id);
    var bound_aad = computeBoundAad(key_id, version, aad);
    defer zeroize(&bound_aad);

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer {
        zeroize(plaintext);
        allocator.free(plaintext);
    }
    Aegis.decrypt(plaintext, ciphertext, tag, &bound_aad, nonce, enc_key) catch return error.AuthenticationFailed;
    return plaintext;
}
