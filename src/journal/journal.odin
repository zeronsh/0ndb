package journal

import "core:crypto/blake2b"
import "core:hash/xxhash"
import "core:strconv"
import "../prim"

HEADER :: 20
TRAILER :: 4
OVERHEAD :: HEADER + TRAILER
MAX_BODY :: 64 * 1024 * 1024
WINDOW :: 16 * 1024
PENDING_KEEP :: 64 * 1024
SIG_KIND :: 0xff
HASH_SIZE :: 32

Error :: enum u8 {
	None,
	Eof,
	Corrupt,
	Missing,
	Redacted,
	No_Key,
	Need_Keys,
	Forged,
	Unverified,
	Equivocation,
	Too_Large,
	Bad_Offset,
	Invalid,
	Busy,
	Not_Found,
	Permission,
	No_Space,
	No_Memory,
	Io,
}

Range :: struct {
	from: i64,
	to:   i64,
}

Key :: [32]u8

Tag :: [16]u8

Hash :: [HASH_SIZE]u8

Cell_Run :: struct {
	from: u64,
	to:   u64,
}

Key_Provider :: struct {
	data:   rawptr,
	key:    proc(data: rawptr, off: i64, out: ^Key) -> bool,
	loaded: proc(data: rawptr) -> bool,
	block:  proc(data: rawptr, cell: u64, bits: u8, out: ^Key) -> bool,
	cover:  proc(data: rawptr, lo, hi: u64, out: ^[dynamic]Cell_Run) -> bool,
}

Signer :: struct {
	data: rawptr,
	sign: proc(data: rawptr, msg: []u8, sig: ^[dynamic]u8) -> bool,
}

Verifier :: struct {
	data:   rawptr,
	verify: proc(data: rawptr, msg: []u8, sig: []u8) -> bool,
}

Chain :: struct {
	seed:     Hash,
	keys:     Key_Provider,
	signer:   Signer,
	verifier: Verifier,
}

Sig_Info :: struct {
	off:         i64,
	end:         i64,
	range_start: i64,
	prev_head:   Hash,
	head:        Hash,
}

Link :: struct {
	len:    u32,
	commit: Hash,
}

Record_Kind :: enum u8 {
	Invalid,
	Plain,
	Sealed,
	Redacted,
}

@(private)
REDACT_MAGIC :: [8]u8{'0', 'n', 'd', 'b', '-', 'r', 'd', 'x'}
@(private)
REDACT_SEED :: 0x7265_6461_6374
@(private)
CHAIN_DOMAIN :: "0ndb-chain-v1"
@(private)
SIG_DOMAIN :: "0ndb-sig-v1"
@(private)
COMMIT_DOMAIN :: "0ndb-commit-v1"
@(private)
SIG_TAG_DOMAIN :: "0ndb-sig-tag-v1"

record_size :: proc "contextless" (body_len: int) -> i64 {
	return i64(body_len) + OVERHEAD
}

local_tag :: proc(body: []u8, off: i64) -> (tag: Tag) {
	h := xxhash.XXH3_128_with_seed(body, u64(off))
	prim.put_u64le(tag[0:8], u64(h))
	prim.put_u64le(tag[8:16], u64(h >> 64))
	return
}

redacted_tag :: proc(off: i64, body_len: int) -> (tag: Tag) {
	magic := REDACT_MAGIC
	copy(tag[0:8], magic[:])
	b: [12]u8
	prim.put_u32le(b[0:4], u32(body_len))
	copy(b[4:12], magic[:])
	prim.put_u64le(tag[8:16], xxhash.XXH3_64_with_seed(b[:], u64(off) ~ REDACT_SEED))
	return
}

encode_record :: proc(dst: []u8, body: []u8, off: i64) -> int {
	n := len(body)
	prim.put_u32le(dst[0:4], u32(n))
	copy(dst[HEADER:], body)
	tag := local_tag(body, off)
	copy(dst[4:HEADER], tag[:])
	prim.put_u32le(dst[HEADER + n:], u32(n))
	return n + OVERHEAD
}

record_body :: proc "contextless" (rec: []u8) -> ([]u8, Error) {
	if len(rec) < OVERHEAD {
		return nil, .Corrupt
	}
	n := int(prim.get_u32le(rec[0:4]))
	if n > MAX_BODY || n + OVERHEAD != len(rec) || int(prim.get_u32le(rec[HEADER + n:])) != n {
		return nil, .Corrupt
	}
	return rec[HEADER:][:n], .None
}

classify :: proc(rec: []u8, off: i64) -> Record_Kind {
	body, err := record_body(rec)
	if err != .None {
		return .Invalid
	}
	tag := rec[4:HEADER]
	magic := REDACT_MAGIC
	if _tag_eq(tag[0:8], magic[:]) {
		want := redacted_tag(off, len(body))
		if _tag_eq(tag, want[:]) {
			return .Redacted
		}
	}
	local := local_tag(body, off)
	if _tag_eq(tag, local[:]) {
		return .Plain
	}
	return .Sealed
}

check_record :: proc(rec: []u8, off: i64) -> Error {
	switch classify(rec, off) {
	case .Plain:
		return .None
	case .Redacted:
		return .Redacted
	case .Invalid, .Sealed:
	}
	return .Corrupt
}

is_sig :: proc "contextless" (body: []u8) -> bool {
	return len(body) > 0 && body[0] == SIG_KIND
}

redact_bytes :: proc(rec: []u8, off: i64) -> Error {
	body, err := record_body(rec)
	if err != .None {
		return err
	}
	tag := redacted_tag(off, len(body))
	copy(rec[4:HEADER], tag[:])
	for &b in body {
		b = 0
	}
	return .None
}

sig_tag :: proc(body: []u8, off: i64, keys: Key_Provider) -> (tag: Tag, ok: bool) {
	if keys.key == nil {
		return
	}
	k: Key
	if !keys.key(keys.data, off, &k) {
		return
	}
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, k[:], len(Tag))
	_zero(k[:])
	blake2b.update(&ctx, transmute([]u8)string(SIG_TAG_DOMAIN))
	b: [8]u8
	prim.put_u64le(b[:], u64(off))
	blake2b.update(&ctx, b[:])
	blake2b.update(&ctx, body)
	blake2b.final(&ctx, tag[:])
	return tag, true
}

chain_genesis :: proc(seed: Hash) -> (h: Hash) {
	ctx: blake2b.Context
	blake2b.init(&ctx, HASH_SIZE)
	blake2b.update(&ctx, transmute([]u8)string(CHAIN_DOMAIN))
	s := seed
	blake2b.update(&ctx, s[:])
	blake2b.final(&ctx, h[:])
	return
}

chain_fold :: proc(head: Hash, off: i64, link: Link) -> (h: Hash) {
	ctx: blake2b.Context
	blake2b.init(&ctx, HASH_SIZE)
	prev := head
	blake2b.update(&ctx, prev[:])
	b: [12]u8
	prim.put_u64le(b[0:8], u64(off))
	prim.put_u32le(b[8:12], link.len)
	blake2b.update(&ctx, b[:])
	c := link.commit
	blake2b.update(&ctx, c[:])
	blake2b.final(&ctx, h[:])
	return
}

commitment :: proc(chain: ^Chain, body: []u8, off: i64) -> (c: Hash, err: Error) {
	ctx: blake2b.Context
	if chain.keys.key != nil {
		k: Key
		if !chain.keys.key(chain.keys.data, off, &k) {
			return {}, .No_Key
		}
		ck: Hash
		kctx: blake2b.Context
		blake2b.init_mac(&kctx, k[:], HASH_SIZE)
		blake2b.update(&kctx, transmute([]u8)string(COMMIT_DOMAIN))
		blake2b.final(&kctx, ck[:])
		blake2b.init_mac(&ctx, ck[:], HASH_SIZE)
		_zero(k[:])
		_zero(ck[:])
	} else {
		blake2b.init(&ctx, HASH_SIZE)
	}
	blake2b.update(&ctx, body)
	blake2b.final(&ctx, c[:])
	return c, .None
}

sig_message :: proc(buf: []u8, seed: Hash, info: Sig_Info) -> []u8 {
	n := copy(buf, SIG_DOMAIN)
	s := seed
	n += copy(buf[n:], s[:])
	prim.put_u64le(buf[n:], u64(info.off))
	n += 8
	prim.put_u64le(buf[n:], u64(info.range_start))
	n += 8
	p := info.prev_head
	n += copy(buf[n:], p[:])
	h := info.head
	n += copy(buf[n:], h[:])
	return buf[:n]
}

SIG_MESSAGE_MAX :: len(SIG_DOMAIN) + HASH_SIZE * 3 + 16

parse_sig :: proc(body: []u8, off: i64, links: ^[dynamic]Link) -> (info: Sig_Info, sig: []u8, err: Error) {
	r := prim.reader(body)
	if prim.read_u8(&r) != SIG_KIND || prim.read_u8(&r) != 1 {
		return {}, nil, .Corrupt
	}
	start := prim.read_uvarint(&r)
	count := prim.read_uvarint(&r)
	if r.err != .None || start > u64(off) || count > u64(prim.reader_remaining(&r) / (HASH_SIZE + 1)) {
		return {}, nil, .Corrupt
	}
	clear(links)
	if reserve(links, int(count)) != nil {
		return {}, nil, .No_Memory
	}
	for _ in 0 ..< count {
		l: Link
		n := prim.read_uvarint(&r)
		prim.read_fixed(&r, l.commit[:])
		if r.err != .None || n > MAX_BODY {
			return {}, nil, .Corrupt
		}
		l.len = u32(n)
		append(links, l)
	}
	info.off = off
	info.end = off + i64(len(body)) + OVERHEAD
	info.range_start = i64(start)
	prim.read_fixed(&r, info.prev_head[:])
	prim.read_fixed(&r, info.head[:])
	sig = prim.read_bytes(&r)
	if !prim.reader_done(&r) {
		return {}, nil, .Corrupt
	}
	return info, sig, .None
}

epoch_path :: proc(base: string, epoch: u64, allocator := context.allocator) -> (string, Error) {
	digits: [24]u8
	num := strconv.write_uint(digits[:], epoch, 10)
	out, err := make([]u8, len(base) + 2 + len(num), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, base)
	n += copy(out[n:], ".e")
	copy(out[n:], num)
	return string(out), .None
}

journal_remove :: proc(vfs: prim.Vfs, path: string) -> Error {
	err := prim.remove(vfs, path)
	for suffix in ([]string{".ck", ".have", ".redact", ".have.tmp", ".redact.tmp"}) {
		buf: prim.Path_Buf
		if len(path) + len(suffix) >= len(buf) {
			return .Invalid
		}
		n := copy(buf[:], path)
		n += copy(buf[n:], suffix)
		if e := prim.remove(vfs, string(buf[:n])); e != .None && e != .Not_Found && err == .None {
			err = e
		}
	}
	if err == .Not_Found {
		return .None
	}
	return _err(err)
}

@(private)
_zero :: proc "contextless" (b: []u8) {
	for &x in b {
		x = 0
	}
}

@(private)
_tag_eq :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	d: u8
	for i in 0 ..< len(a) {
		d |= a[i] ~ b[i]
	}
	return d == 0
}

@(private)
_err :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Permission:
		return .Permission
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Busy, .Would_Block:
		return .Busy
	case .Too_Large:
		return .Too_Large
	case .Invalid:
		return .Invalid
	}
	return .Io
}

@(private)
_sidecar :: proc(path: string, suffix: string, allocator := context.allocator) -> (string, Error) {
	out, err := make([]u8, len(path) + len(suffix), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, path)
	copy(out[n:], suffix)
	return string(out), .None
}
