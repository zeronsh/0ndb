package osync

import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/ecdh"
import "core:crypto/ed25519"
import "core:crypto/hkdf"
import "core:hash/xxhash"
import "../journal"
import "../prim"

Device_Id :: prim.Id
Space_Id :: prim.Id
Stream_Id :: distinct [32]u8
Object_Key :: distinct [32]u8
Public_Key :: [32]u8
Secret :: [32]u8

DEVICE_KEY_FILE :: "device.key"
RELAY_KEY_FILE :: "relay.key"
SPACE_FILE :: "space.key"

Device :: struct {
	sign:         ed25519.Private_Key,
	public:       Public_Key,
	id:           Device_Id,
	noise:        ecdh.Private_Key,
	noise_public: Public_Key,
}

Space :: struct {
	secret:      Secret,
	content:     Content_Key,
	auth:        ed25519.Private_Key,
	auth_public: Public_Key,
	id:          Space_Id,
}

Encryption_Mode :: enum u8 {
	End_To_End,
	Transparent,
}

Content_Key :: struct {
	key:   [32]u8,
	epoch: u32,
}

Scope :: struct {
	content:    Content_Key,
	mode:       Encryption_Mode,
	name_key:   [32]u8,
	object_key: [32]u8,
}

Identity :: struct {
	id:   Device_Id,
	sign: Public_Key,
	box:  Public_Key,
}

Relay_Key :: struct {
	private: ecdh.Private_Key,
	public:  Public_Key,
}

Pairing :: struct {
	secret:       Secret,
	relay_public: Public_Key,
	relay_addr:   [MAX_ADDR]u8,
	addr_len:     int,
}

MAX_ADDR :: 255

@(private)
KEY_MAGIC :: "0ndbkey\x01"
@(private)
KEY_SEED :: 0x306e_6462_6b65_79
@(private)
KIND_DEVICE :: 1
@(private)
KIND_RELAY :: 2
@(private)
KIND_SPACE :: 3
@(private)
KDF_SALT :: "0ndb-space-v1"
@(private)
DEVICE_SALT :: "0ndb-device-v1"

device_from_seed :: proc(seed: []u8) -> (d: Device, err: Error) {
	if len(seed) != ed25519.PRIVATE_KEY_SIZE {
		return {}, .Invalid
	}
	if !ed25519.private_key_set_bytes(&d.sign, seed) {
		return {}, .Invalid
	}
	ed25519.private_key_public_bytes(&d.sign, d.public[:])
	d.id = device_id(d.public)
	nk: [32]u8
	defer crypto.zero_explicit(&nk, size_of(nk))
	hkdf.extract_and_expand(.SHA256, transmute([]u8)string(DEVICE_SALT), seed, transmute([]u8)string("noise x25519"), nk[:])
	if !ecdh.private_key_set_bytes(&d.noise, .X25519, nk[:]) {
		return {}, .Invalid
	}
	ecdh.private_key_public_bytes(&d.noise, d.noise_public[:])
	return d, .None
}

device_id :: proc(public: Public_Key) -> (id: Device_Id) {
	digest: [blake2b.DIGEST_SIZE]u8
	ctx: blake2b.Context
	blake2b.init(&ctx)
	p := public
	blake2b.update(&ctx, p[:])
	blake2b.final(&ctx, digest[:])
	copy(id[:], digest[:16])
	return
}

device_load_or_create :: proc(vfs: prim.Vfs, dir: string, random := prim.Random{}) -> (d: Device, err: Error) {
	seed: [32]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	_key_load_or_create(vfs, dir, DEVICE_KEY_FILE, KIND_DEVICE, seed[:], random) or_return
	return device_from_seed(seed[:])
}

device_clear :: proc(d: ^Device) {
	ed25519.private_key_clear(&d.sign)
	ecdh.private_key_clear(&d.noise)
	d^ = {}
}

relay_key_load_or_create :: proc(vfs: prim.Vfs, dir: string, random := prim.Random{}) -> (k: Relay_Key, err: Error) {
	raw: [32]u8
	defer crypto.zero_explicit(&raw, size_of(raw))
	_key_load_or_create(vfs, dir, RELAY_KEY_FILE, KIND_RELAY, raw[:], random) or_return
	if !ecdh.private_key_set_bytes(&k.private, .X25519, raw[:]) {
		return {}, .Corrupt
	}
	ecdh.private_key_public_bytes(&k.private, k.public[:])
	return k, .None
}

relay_key_clear :: proc(k: ^Relay_Key) {
	ecdh.private_key_clear(&k.private)
	k^ = {}
}

space_new :: proc(random := prim.Random{}) -> (s: Space, err: Error) {
	secret: Secret
	defer crypto.zero_explicit(&secret, size_of(secret))
	prim.random_fill(random, secret[:])
	return space_from_secret(secret)
}

space_from_secret :: proc(secret: Secret) -> (s: Space, err: Error) {
	s.secret = secret
	_derive(s.secret[:], "0ndb space content", nil, s.content.key[:])
	seed: [32]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	_derive(s.secret[:], "0ndb relay auth", nil, seed[:])
	if !ed25519.private_key_set_bytes(&s.auth, seed[:]) {
		return {}, .Invalid
	}
	ed25519.private_key_public_bytes(&s.auth, s.auth_public[:])
	s.id = space_id(s.auth_public)
	return s, .None
}

space_id :: proc(auth_public: Public_Key) -> Space_Id {
	return device_id(auth_public)
}

space_clear :: proc(s: ^Space) {
	ed25519.private_key_clear(&s.auth)
	crypto.zero_explicit(s, size_of(Space))
}

space_scope :: proc(s: ^Space, mode := Encryption_Mode.End_To_End) -> Scope {
	return scope_make(s.content, mode)
}

content_key_new :: proc(epoch: u32 = 0, random := prim.Random{}) -> (k: Content_Key) {
	prim.random_fill(random, k.key[:])
	k.epoch = epoch
	return
}

content_key_rotate :: proc(prev: Content_Key, random := prim.Random{}) -> Content_Key {
	return content_key_new(prev.epoch + 1, random)
}

scope_make :: proc(content: Content_Key, mode := Encryption_Mode.End_To_End) -> (sc: Scope) {
	sc.content = content
	sc.mode = mode
	e: [4]u8
	prim.put_u32le(e[:], content.epoch)
	_derive(sc.content.key[:], "0ndb stream name", e[:], sc.name_key[:])
	_derive(sc.content.key[:], "0ndb object index", e[:], sc.object_key[:])
	return
}

scope_clear :: proc(sc: ^Scope) {
	crypto.zero_explicit(sc, size_of(Scope))
}

stream_suffix :: proc(sc: ^Scope, name: string, epoch: u64) -> (suffix: [16]u8) {
	e: [8]u8
	prim.put_u64le(e[:], epoch)
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, sc.name_key[:], 16)
	blake2b.update(&ctx, e[:])
	blake2b.update(&ctx, transmute([]u8)name)
	blake2b.final(&ctx, suffix[:])
	return
}

stream_id :: proc(sc: ^Scope, device: Device_Id, name: string, epoch: u64) -> (id: Stream_Id) {
	dev := device
	copy(id[:16], dev[:])
	suffix := stream_suffix(sc, name, epoch)
	copy(id[16:], suffix[:])
	return
}

stream_id_suffix :: proc "contextless" (id: Stream_Id) -> (suffix: [16]u8) {
	src := id
	copy(suffix[:], src[16:])
	return
}

stream_device :: proc "contextless" (id: Stream_Id) -> (d: Device_Id) {
	src := id
	copy(d[:], src[:16])
	return
}

stream_key :: proc(sc: ^Scope, id: Stream_Id) -> (key: journal.Key) {
	sid := id
	_derive(sc.content.key[:], "0ndb stream key", sid[:], key[:])
	return
}

object_index :: proc(sc: ^Scope, oid: []u8) -> (key: Object_Key) {
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, sc.object_key[:], 32)
	blake2b.update(&ctx, oid)
	blake2b.final(&ctx, key[:])
	return
}

object_content_key :: proc(sc: ^Scope, oid: []u8) -> (key: [32]u8) {
	_derive(sc.content.key[:], "0ndb object key", oid, key[:])
	return
}

device_identity :: proc "contextless" (d: ^Device) -> Identity {
	return Identity{id = d.id, sign = d.public, box = d.noise_public}
}

pairing_make :: proc(s: ^Space, relay_addr: string, relay_public: Public_Key) -> (p: Pairing, err: Error) {
	if len(relay_addr) > MAX_ADDR {
		return {}, .Too_Large
	}
	p.secret = s.secret
	p.relay_public = relay_public
	p.addr_len = copy(p.relay_addr[:], relay_addr)
	return p, .None
}

pairing_addr :: proc "contextless" (p: ^Pairing) -> string {
	return string(p.relay_addr[:p.addr_len])
}

pairing_save :: proc(vfs: prim.Vfs, dir: string, p: ^Pairing, random := prim.Random{}) -> Error {
	buf: [8 + 1 + 32 + 32 + 2 + MAX_ADDR + 8]u8
	n := copy(buf[:], KEY_MAGIC)
	buf[n] = KIND_SPACE
	n += 1
	n += copy(buf[n:], p.secret[:])
	n += copy(buf[n:], p.relay_public[:])
	buf[n] = u8(p.addr_len)
	buf[n + 1] = 0
	n += 2
	n += copy(buf[n:], p.relay_addr[:p.addr_len])
	prim.put_u64le(buf[n:], xxhash.XXH3_64_with_seed(buf[:n], KEY_SEED))
	n += 8
	defer crypto.zero_explicit(&buf, size_of(buf))
	path, perr := prim.path_join(context.temp_allocator, dir, SPACE_FILE)
	if perr != .None {
		return _from_prim(perr)
	}
	if merr := prim.mkdir_all(vfs, dir, 0o700); merr != .None {
		return _from_prim(merr)
	}
	return _write_private(vfs, path, buf[:n], false, random)
}

pairing_load :: proc(vfs: prim.Vfs, dir: string) -> (p: Pairing, err: Error) {
	path, perr := prim.path_join(context.temp_allocator, dir, SPACE_FILE)
	if perr != .None {
		return {}, _from_prim(perr)
	}
	data := _read_private(vfs, path) or_return
	defer {
		crypto.zero_explicit(raw_data(data), len(data))
		delete(data, context.temp_allocator)
	}
	if len(data) < 8 + 1 + 32 + 32 + 2 + 8 || string(data[:8]) != KEY_MAGIC || data[8] != KIND_SPACE {
		return {}, .Corrupt
	}
	body := data[:len(data) - 8]
	if xxhash.XXH3_64_with_seed(body, KEY_SEED) != prim.get_u64le(data[len(data) - 8:]) {
		return {}, .Corrupt
	}
	copy(p.secret[:], data[9:41])
	copy(p.relay_public[:], data[41:73])
	alen := int(data[73])
	if 75 + alen != len(body) {
		return {}, .Corrupt
	}
	p.addr_len = copy(p.relay_addr[:], data[75:75 + alen])
	return p, .None
}

@(private)
_derive :: proc(ikm: []u8, label: string, ctx_bytes: []u8, dst: []u8) {
	info: [128]u8
	n := copy(info[:], label)
	info[n] = 0
	n += 1
	n += copy(info[n:], ctx_bytes)
	hkdf.extract_and_expand(.SHA256, transmute([]u8)string(KDF_SALT), ikm, info[:n], dst)
}

@(private)
_key_load_or_create :: proc(vfs: prim.Vfs, dir: string, file: string, kind: u8, out: []u8, random: prim.Random) -> Error {
	path, perr := prim.path_join(context.temp_allocator, dir, file)
	if perr != .None {
		return _from_prim(perr)
	}
	for _ in 0 ..< 3 {
		err := _key_load(vfs, path, kind, out)
		if err != .Not_Found {
			return err
		}
		if merr := prim.mkdir_all(vfs, dir, 0o700); merr != .None {
			return _from_prim(merr)
		}
		fresh: [32]u8
		prim.random_fill(random, fresh[:])
		buf: [8 + 1 + 32 + 8]u8
		n := copy(buf[:], KEY_MAGIC)
		buf[n] = kind
		n += 1
		n += copy(buf[n:], fresh[:])
		prim.put_u64le(buf[n:], xxhash.XXH3_64_with_seed(buf[:n], KEY_SEED))
		werr := _write_private(vfs, path, buf[:], true, random)
		crypto.zero_explicit(&fresh, size_of(fresh))
		crypto.zero_explicit(&buf, size_of(buf))
		if werr != .None && werr != .Exists {
			return werr
		}
	}
	return .Busy
}

@(private)
_key_load :: proc(vfs: prim.Vfs, path: string, kind: u8, out: []u8) -> Error {
	data := _read_private(vfs, path) or_return
	defer {
		crypto.zero_explicit(raw_data(data), len(data))
		delete(data, context.temp_allocator)
	}
	if len(data) != 8 + 1 + 32 + 8 || string(data[:8]) != KEY_MAGIC || data[8] != kind {
		return .Corrupt
	}
	if xxhash.XXH3_64_with_seed(data[:41], KEY_SEED) != prim.get_u64le(data[41:]) {
		return .Corrupt
	}
	copy(out, data[9:41])
	return .None
}

@(private)
_read_private :: proc(vfs: prim.Vfs, path: string) -> ([]u8, Error) {
	data, err := prim.read_file(vfs, path, context.temp_allocator)
	if err != .None {
		return nil, _from_prim(err)
	}
	if terr := _tighten_mode(vfs, path); terr != .None {
		crypto.zero_explicit(raw_data(data), len(data))
		delete(data, context.temp_allocator)
		return nil, terr
	}
	return data, .None
}

@(private)
_write_private :: proc(vfs: prim.Vfs, path: string, data: []u8, exclusive: bool, random: prim.Random) -> Error {
	suffix: [24]u8
	r: [8]u8
	prim.random_fill(random, r[:])
	copy(suffix[:], ".tmp.")
	prim.hex_encode(suffix[5:21], r[:])
	tmp, perr := _concat(context.temp_allocator, path, string(suffix[:21]))
	if perr != .None {
		return perr
	}
	fd, oerr := prim.open_file(vfs, tmp, {.Write, .Create, .Exclusive}, 0o600)
	if oerr != .None {
		return _from_prim(oerr)
	}
	err := _from_prim(prim.write_at(vfs, fd, data, 0))
	if err == .None {
		err = _from_prim(prim.fullsync(vfs, fd))
	}
	if cerr := prim.close_file(vfs, fd); err == .None {
		err = _from_prim(cerr)
	}
	if err == .None {
		if exclusive {
			lock_path, _ := _concat(context.temp_allocator, path, ".lock")
			lfd, lerr := prim.lock_file(vfs, lock_path)
			if lerr != .None {
				err = _from_prim(lerr)
			} else {
				if prim.exists(vfs, path) {
					err = .Exists
				} else {
					err = _from_prim(prim.rename(vfs, tmp, path))
				}
				prim.close_file(vfs, lfd)
			}
		} else {
			err = _from_prim(prim.rename(vfs, tmp, path))
		}
	}
	prim.remove(vfs, tmp)
	if err != .None {
		return err
	}
	return _from_prim(prim.sync_dir(vfs, prim.dir_name(path)))
}

@(private)
_concat :: proc(allocator := context.allocator, parts: ..string) -> (string, Error) {
	n := 0
	for p in parts {
		n += len(p)
	}
	buf, err := make([]u8, n, allocator)
	if err != nil {
		return "", .No_Memory
	}
	i := 0
	for p in parts {
		i += copy(buf[i:], p)
	}
	return string(buf), .None
}

@(private)
_tighten_mode :: proc(vfs: prim.Vfs, path: string) -> Error {
	st, err := prim.stat(vfs, path)
	if err != .None {
		return _from_prim(err)
	}
	if st.mode & 0o077 == 0 {
		return .None
	}
	fd, oerr := prim.open_file(vfs, path)
	if oerr != .None {
		return _from_prim(oerr)
	}
	defer prim.close_file(vfs, fd)
	return _from_prim(prim.fchmod(vfs, fd, st.mode & 0o700))
}
