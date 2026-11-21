const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Aegis = std.crypto.aead.aegis.Aegis256;
const Blake3 = std.crypto.hash.Blake3;
const X25519 = std.crypto.dh.X25519;

pub const Key = [Aegis.key_length]u8;
pub const Nonce = [Aegis.nonce_length]u8;
pub const Tag = [Aegis.tag_length]u8;
pub const Hash = [32]u8;
pub const Mac = [32]u8;
pub const CommitTag = [32]u8;

pub const ENVELOPE_VERSION: u8 = 2;
pub const DEVICE_SEAL_VERSION: u8 = 3;
pub const COMMIT_TAG_LEN: usize = 32;
pub const ENVELOPE_OVERHEAD: usize = 1 + Aegis.nonce_length + COMMIT_TAG_LEN + Aegis.tag_length;
pub const DEVICE_SEAL_OVERHEAD: usize = 1 + X25519.public_length + ENVELOPE_OVERHEAD;

pub fn zeroize(buf: []u8) void {
    std.crypto.secureZero(u8, buf);
}

fn isAllZero(buf: []const u8) bool {
    var acc: u8 = 0;
    for (buf) |b| acc |= b;
    return acc == 0;
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

pub fn deriveCapabilityTokenV3(secret: [32]u8, topic_id: Hash, perms: u32, expires_ms: u64) Mac {
    var h = Blake3.init(.{ .key = secret });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-cap-v3");
    h.update(&topic_id);
    var perm_bytes: [4]u8 = undefined;
    defer zeroize(&perm_bytes);
    std.mem.writeInt(u32, &perm_bytes, perms, .little);
    h.update(&perm_bytes);
    var exp_bytes: [8]u8 = undefined;
    defer zeroize(&exp_bytes);
    std.mem.writeInt(u64, &exp_bytes, expires_ms, .little);
    h.update(&exp_bytes);
    var mac: Mac = undefined;
    h.final(&mac);
    return mac;
}

pub fn verifyCapabilityTokenV3(secret: [32]u8, topic_id: Hash, perms: u32, expires_ms: u64, provided: Mac, now_ms: u64) bool {
    if (expires_ms != 0 and now_ms > expires_ms) return false;
    var expected = deriveCapabilityTokenV3(secret, topic_id, perms, expires_ms);
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

pub const AccountRootKey = struct {
    bytes: [32]u8,

    pub fn generate(io: Io) AccountRootKey {
        var out: [32]u8 = undefined;
        io.random(&out);
        return .{ .bytes = out };
    }

    pub fn fromBytes(bytes: [32]u8) AccountRootKey {
        return .{ .bytes = bytes };
    }

    pub fn zeroize(self: *AccountRootKey) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
};

pub const DeviceKeypair = struct {
    secret_key: [32]u8,
    public_key: [32]u8,

    pub fn generate(io: Io) DeviceKeypair {
        var kp = X25519.KeyPair.generate(io);
        defer std.crypto.secureZero(u8, &kp.secret_key);
        return .{
            .secret_key = kp.secret_key,
            .public_key = kp.public_key,
        };
    }

    pub fn fromSecret(secret_key: [32]u8) DeviceKeypair {
        return .{
            .secret_key = secret_key,
            .public_key = X25519.recoverPublicKey(secret_key),
        };
    }

    pub fn zeroize(self: *DeviceKeypair) void {
        std.crypto.secureZero(u8, &self.secret_key);
        std.crypto.secureZero(u8, &self.public_key);
    }
};

pub const EntityKey = struct {
    key: [32]u8,
    epoch: u32,

    pub fn generate(io: Io, epoch: u32) EntityKey {
        var out: [32]u8 = undefined;
        io.random(&out);
        return .{ .key = out, .epoch = epoch };
    }

    pub fn zeroize(self: *EntityKey) void {
        std.crypto.secureZero(u8, &self.key);
        self.epoch = 0;
    }
};

pub fn deriveStreamKeyV3(entity_key: *const EntityKey, topic_id: [32]u8) [32]u8 {
    var h = Blake3.init(.{ .key = entity_key.key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-stream-v3");
    var epoch_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &epoch_buf, entity_key.epoch, .little);
    h.update(&epoch_buf);
    h.update(&topic_id);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn deriveBlobLookupIdV3(entity_key: *const EntityKey, topic_id: [32]u8, local_oid: [32]u8) [32]u8 {
    var h = Blake3.init(.{ .key = entity_key.key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-blob-v3");
    var epoch_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &epoch_buf, entity_key.epoch, .little);
    h.update(&epoch_buf);
    h.update(&topic_id);
    h.update(&local_oid);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn deriveSnapshotKeyV3(entity_key: *const EntityKey, topic_id: [32]u8) [32]u8 {
    var h = Blake3.init(.{ .key = entity_key.key });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-snapshot-v3");
    var epoch_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &epoch_buf, entity_key.epoch, .little);
    h.update(&epoch_buf);
    h.update(&topic_id);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

const WRAP_ACCOUNT_V3_SUFFIX = "wrap-account-v3";

fn buildAccountWrapAad(topic_id: [32]u8) [32 + WRAP_ACCOUNT_V3_SUFFIX.len]u8 {
    var aad: [32 + WRAP_ACCOUNT_V3_SUFFIX.len]u8 = undefined;
    @memcpy(aad[0..32], &topic_id);
    @memcpy(aad[32..], WRAP_ACCOUNT_V3_SUFFIX);
    return aad;
}

pub fn wrapEntityKeyForAccount(
    allocator: Allocator,
    io: Io,
    root_key: *const AccountRootKey,
    topic_id: [32]u8,
    entity_key: *const EntityKey,
) Allocator.Error![]u8 {
    const aad = buildAccountWrapAad(topic_id);
    var plain: [36]u8 = undefined;
    defer zeroize(&plain);
    std.mem.writeInt(u32, plain[0..4], entity_key.epoch, .little);
    @memcpy(plain[4..36], &entity_key.key);
    return sealRandom(allocator, io, root_key.bytes, &aad, &plain);
}

pub fn unwrapEntityKeyForAccount(
    allocator: Allocator,
    root_key: *const AccountRootKey,
    topic_id: [32]u8,
    wrapped: []const u8,
) (Allocator.Error || error{ InvalidEnvelope, AuthenticationFailed })!EntityKey {
    const aad = buildAccountWrapAad(topic_id);
    const plain = try open(allocator, root_key.bytes, &aad, wrapped);
    defer {
        zeroize(plain);
        allocator.free(plain);
    }
    if (plain.len != 36) return error.InvalidEnvelope;
    const epoch = std.mem.readInt(u32, plain[0..4], .little);
    const key: [32]u8 = plain[4..36].*;
    return .{ .key = key, .epoch = epoch };
}

fn deriveDeviceWrapKey(shared: [32]u8, ephem_pub: [32]u8, recipient_pub: [32]u8, aad: []const u8) Key {
    var h = Blake3.init(.{ .key = shared });
    defer zeroize(std.mem.asBytes(&h));
    h.update("0ndb-device-wrap-v3");
    h.update(&ephem_pub);
    h.update(&recipient_pub);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, aad.len, .little);
    h.update(&len_buf);
    h.update(aad);
    var out: Key = undefined;
    h.final(&out);
    return out;
}

pub fn sealToDevicePubkey(
    allocator: Allocator,
    io: Io,
    recipient_pubkey: [32]u8,
    aad: []const u8,
    plaintext: []const u8,
) (Allocator.Error || error{ InvalidPublicKey, WeakSharedSecret })![]u8 {
    if (isAllZero(&recipient_pubkey)) return error.InvalidPublicKey;
    var ephem = DeviceKeypair.generate(io);
    defer ephem.zeroize();

    var shared = X25519.scalarmult(ephem.secret_key, recipient_pubkey) catch return error.WeakSharedSecret;
    defer zeroize(&shared);
    if (isAllZero(&shared)) return error.WeakSharedSecret;

    var wrap_key = deriveDeviceWrapKey(shared, ephem.public_key, recipient_pubkey, aad);
    defer zeroize(&wrap_key);

    const env = try sealRandom(allocator, io, wrap_key, aad, plaintext);
    defer allocator.free(env);

    const out = try allocator.alloc(u8, 1 + X25519.public_length + env.len);
    out[0] = DEVICE_SEAL_VERSION;
    @memcpy(out[1 .. 1 + X25519.public_length], &ephem.public_key);
    @memcpy(out[1 + X25519.public_length ..], env);
    return out;
}

pub fn openWithDeviceSecret(
    allocator: Allocator,
    recipient_secret: [32]u8,
    aad: []const u8,
    sealed: []const u8,
) (Allocator.Error || error{ InvalidEnvelope, AuthenticationFailed, WeakSharedSecret })![]u8 {
    if (sealed.len < DEVICE_SEAL_OVERHEAD) return error.InvalidEnvelope;
    if (sealed[0] != DEVICE_SEAL_VERSION) return error.InvalidEnvelope;

    const ephem_pub: [32]u8 = sealed[1 .. 1 + X25519.public_length].*;
    if (isAllZero(&ephem_pub)) return error.WeakSharedSecret;

    var recipient_pub = X25519.recoverPublicKey(recipient_secret);
    defer zeroize(&recipient_pub);

    var shared = X25519.scalarmult(recipient_secret, ephem_pub) catch return error.WeakSharedSecret;
    defer zeroize(&shared);
    if (isAllZero(&shared)) return error.WeakSharedSecret;

    var wrap_key = deriveDeviceWrapKey(shared, ephem_pub, recipient_pub, aad);
    defer zeroize(&wrap_key);

    return open(allocator, wrap_key, aad, sealed[1 + X25519.public_length ..]);
}

pub const DelegationGrant = struct {
    topic_id: [32]u8,
    entity_key: EntityKey,
    perms: u32,
    expires_ms: u64,
    token: []u8,

    pub fn deinit(self: *DelegationGrant, allocator: Allocator) void {
        self.entity_key.zeroize();
        if (self.token.len > 0) {
            zeroize(self.token);
            allocator.free(self.token);
        }
        self.token = &.{};
    }
};

pub const DelegationBundle = struct {
    issued_by_runner: u128,
    target_runner: u128,
    issued_ms: u64,
    expires_ms: u64,
    grants: []DelegationGrant,

    pub const MAGIC: [4]u8 = .{ '0', 'D', 'B', 'G' };
    pub const FORMAT_VERSION: u8 = 3;
    pub const HEADER_LEN: usize = 4 + 1 + 16 + 16 + 8 + 8 + 4;
    pub const GRANT_FIXED_LEN: usize = 32 + 32 + 4 + 4 + 8 + 4;
    pub const MAX_GRANTS: usize = 4096;
    pub const MAX_TOKEN_LEN: usize = 65536;

    pub fn deinit(self: *DelegationBundle, allocator: Allocator) void {
        for (self.grants) |*g| g.deinit(allocator);
        if (self.grants.len > 0) allocator.free(self.grants);
        self.grants = &.{};
    }

    pub fn encode(self: *const DelegationBundle, allocator: Allocator) Allocator.Error![]u8 {
        var total_len: usize = HEADER_LEN;
        for (self.grants) |g| {
            total_len += GRANT_FIXED_LEN + g.token.len;
        }
        const out = try allocator.alloc(u8, total_len);
        errdefer {
            zeroize(out);
            allocator.free(out);
        }

        var pos: usize = 0;
        @memcpy(out[pos..][0..4], &MAGIC);
        pos += 4;
        out[pos] = FORMAT_VERSION;
        pos += 1;
        std.mem.writeInt(u128, out[pos..][0..16], self.issued_by_runner, .little);
        pos += 16;
        std.mem.writeInt(u128, out[pos..][0..16], self.target_runner, .little);
        pos += 16;
        std.mem.writeInt(u64, out[pos..][0..8], self.issued_ms, .little);
        pos += 8;
        std.mem.writeInt(u64, out[pos..][0..8], self.expires_ms, .little);
        pos += 8;
        std.mem.writeInt(u32, out[pos..][0..4], @intCast(self.grants.len), .little);
        pos += 4;

        for (self.grants) |g| {
            @memcpy(out[pos..][0..32], &g.topic_id);
            pos += 32;
            @memcpy(out[pos..][0..32], &g.entity_key.key);
            pos += 32;
            std.mem.writeInt(u32, out[pos..][0..4], g.entity_key.epoch, .little);
            pos += 4;
            std.mem.writeInt(u32, out[pos..][0..4], g.perms, .little);
            pos += 4;
            std.mem.writeInt(u64, out[pos..][0..8], g.expires_ms, .little);
            pos += 8;
            std.mem.writeInt(u32, out[pos..][0..4], @intCast(g.token.len), .little);
            pos += 4;
            if (g.token.len > 0) {
                @memcpy(out[pos .. pos + g.token.len], g.token);
                pos += g.token.len;
            }
        }
        return out;
    }

    pub fn decode(allocator: Allocator, data: []const u8) (Allocator.Error || error{InvalidBundle})!DelegationBundle {
        if (data.len < HEADER_LEN) return error.InvalidBundle;
        if (!std.mem.eql(u8, data[0..4], &MAGIC)) return error.InvalidBundle;
        if (data[4] != FORMAT_VERSION) return error.InvalidBundle;

        var pos: usize = 5;
        const issued_by_runner = std.mem.readInt(u128, data[pos..][0..16], .little);
        pos += 16;
        const target_runner = std.mem.readInt(u128, data[pos..][0..16], .little);
        pos += 16;
        const issued_ms = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        const expires_ms = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        const grant_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (grant_count > MAX_GRANTS) return error.InvalidBundle;

        const grants = try allocator.alloc(DelegationGrant, grant_count);
        var initialized: usize = 0;
        errdefer {
            for (grants[0..initialized]) |*g| g.deinit(allocator);
            allocator.free(grants);
        }

        for (0..grant_count) |i| {
            if (data.len - pos < GRANT_FIXED_LEN) return error.InvalidBundle;
            const topic_id: [32]u8 = data[pos..][0..32].*;
            pos += 32;
            const ek_bytes: [32]u8 = data[pos..][0..32].*;
            pos += 32;
            const ek_epoch = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            const perms = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            const g_exp = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
            const tok_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;
            if (tok_len > MAX_TOKEN_LEN or data.len - pos < tok_len) return error.InvalidBundle;
            const tok: []u8 = if (tok_len > 0) try allocator.dupe(u8, data[pos .. pos + tok_len]) else &.{};
            pos += tok_len;

            grants[i] = .{
                .topic_id = topic_id,
                .entity_key = .{ .key = ek_bytes, .epoch = ek_epoch },
                .perms = perms,
                .expires_ms = g_exp,
                .token = tok,
            };
            initialized += 1;
        }
        if (pos != data.len) return error.InvalidBundle;

        return .{
            .issued_by_runner = issued_by_runner,
            .target_runner = target_runner,
            .issued_ms = issued_ms,
            .expires_ms = expires_ms,
            .grants = grants,
        };
    }

    fn buildAad(target_runner: u128) [19 + 16]u8 {
        var aad: [19 + 16]u8 = undefined;
        @memcpy(aad[0..19], "0ndb-delegation-v3:");
        std.mem.writeInt(u128, aad[19..35], target_runner, .little);
        return aad;
    }

    pub fn sealForDevice(
        self: *const DelegationBundle,
        allocator: Allocator,
        io: Io,
        recipient_pubkey: [32]u8,
    ) (Allocator.Error || error{ InvalidPublicKey, WeakSharedSecret })![]u8 {
        const plain = try self.encode(allocator);
        defer {
            zeroize(plain);
            allocator.free(plain);
        }
        const aad = buildAad(self.target_runner);
        return sealToDevicePubkey(allocator, io, recipient_pubkey, &aad, plain);
    }

    pub fn openForDevice(
        allocator: Allocator,
        recipient_secret: [32]u8,
        expected_target_runner: u128,
        sealed: []const u8,
    ) (Allocator.Error || error{ InvalidEnvelope, AuthenticationFailed, WeakSharedSecret, InvalidBundle })!DelegationBundle {
        const aad = buildAad(expected_target_runner);
        const plain = try openWithDeviceSecret(allocator, recipient_secret, &aad, sealed);
        defer {
            zeroize(plain);
            allocator.free(plain);
        }
        var bundle = try DelegationBundle.decode(allocator, plain);
        if (bundle.target_runner != expected_target_runner) {
            bundle.deinit(allocator);
            return error.AuthenticationFailed;
        }
        return bundle;
    }
};
