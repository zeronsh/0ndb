package osync

import "base:runtime"
import "core:crypto"
import "core:crypto/blake2b"
import "../prim"

File_Sealed_Store :: struct {
	vfs:       prim.Vfs,
	dir:       string,
	allocator: runtime.Allocator,
}

file_sealed_store_init :: proc(s: ^File_Sealed_Store, vfs: prim.Vfs, dir: string, allocator := context.allocator) -> Error {
	s.vfs = vfs
	s.allocator = allocator
	s.dir = _clone_string(dir, allocator) or_return
	return _from_prim(prim.mkdir_all(vfs, dir, 0o700))
}

file_sealed_store_destroy :: proc(s: ^File_Sealed_Store) {
	delete(s.dir, s.allocator)
	s^ = {}
}

file_sealed_store :: proc(s: ^File_Sealed_Store) -> Sealed_Store {
	return Sealed_Store{data = s, get = _fss_get, put = _fss_put, add = _fss_add}
}

@(private)
_fss_path :: proc(s: ^File_Sealed_Store, subject: []u8, suffix: string) -> string {
	h: [16]u8
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, transmute([]u8)string("0ndb subject"))
	blake2b.update(&ctx, subject)
	blake2b.final(&ctx, h[:])
	hx := prim.id_hex(prim.Id(h))
	name, _ := _concat(context.temp_allocator, string(hx[:]), suffix)
	p, _ := prim.path_join(context.temp_allocator, s.dir, name)
	return p
}

@(private)
_fss_get :: proc(data: rawptr, subject: []u8, reply: ^Plug_Reply, done: Plug_Done) -> Error {
	s := cast(^File_Sealed_Store)data
	record := make([dynamic]u8, context.temp_allocator)
	entries := make([dynamic][]u8, context.temp_allocator)
	defer {
		reply.record = record[:]
		reply.entries = entries[:]
	}
	rec, err := prim.read_file(s.vfs, _fss_path(s, subject, ".record"), context.temp_allocator)
	if err == .Not_Found {
		return .Not_Found
	}
	if err != .None {
		return _from_prim(err)
	}
	append(&record, ..rec)
	ents, eerr := prim.read_file(s.vfs, _fss_path(s, subject, ".entries"), context.temp_allocator)
	if eerr != .None && eerr != .Not_Found {
		return _from_prim(eerr)
	}
	pos := 0
	for pos + 4 <= len(ents) {
		n := int(prim.get_u32le(ents[pos:]))
		if pos + 4 + n > len(ents) {
			break
		}
		append(&entries, ents[pos + 4:][:n])
		pos += 4 + n
	}
	return .None
}

@(private)
_fss_put :: proc(data: rawptr, subject: []u8, record: []u8, prev_seq: u64, reply: ^Plug_Reply, done: Plug_Done) -> Error {
	s := cast(^File_Sealed_Store)data
	path := _fss_path(s, subject, ".record")
	lock_path, _ := _concat(context.temp_allocator, path, ".lock")
	lfd, lerr := prim.lock_file(s.vfs, lock_path)
	if lerr != .None {
		return _from_prim(lerr)
	}
	defer prim.close_file(s.vfs, lfd)
	cur, err := prim.read_file(s.vfs, path, context.temp_allocator)
	if err == .None {
		rec: Account_Record
		if account_record_decode(cur, &rec, context.temp_allocator) == .None {
			if rec.seq != prev_seq {
				return .Conflict
			}
		}
	} else if err != .Not_Found {
		return _from_prim(err)
	} else if prev_seq != 0 {
		return .Conflict
	}
	return _from_prim(prim.replace_atomic(s.vfs, path, record))
}

@(private)
_fss_add :: proc(data: rawptr, subject: []u8, entry: []u8, reply: ^Plug_Reply, done: Plug_Done) -> Error {
	s := cast(^File_Sealed_Store)data
	path := _fss_path(s, subject, ".entries")
	fd, oerr := prim.open_file(s.vfs, path, {.Write, .Create}, 0o600)
	if oerr != .None {
		return _from_prim(oerr)
	}
	defer prim.close_file(s.vfs, fd)
	size, serr := prim.file_size(s.vfs, fd)
	if serr != .None {
		return _from_prim(serr)
	}
	hdr: [4]u8
	prim.put_u32le(hdr[:], u32(len(entry)))
	if e := prim.write_at(s.vfs, fd, hdr[:], size); e != .None {
		return _from_prim(e)
	}
	if e := prim.write_at(s.vfs, fd, entry, size + 4); e != .None {
		return _from_prim(e)
	}
	return _from_prim(prim.datasync(s.vfs, fd))
}

Soft_Passkey :: struct {
	vfs:    prim.Vfs,
	local:  string,
	remote: string,
	random: prim.Random,
}

soft_passkey :: proc(k: ^Soft_Passkey) -> Unlock {
	return Unlock{data = k, unlock = _soft_unlock, register = _soft_register}
}

@(private)
_soft_load :: proc(k: ^Soft_Passkey, path: string, cred: ^[16]u8, seed: ^[32]u8) -> Error {
	if len(path) == 0 {
		return .Unsupported
	}
	data, err := prim.read_file(k.vfs, path, context.temp_allocator)
	if err != .None {
		return _from_prim(err)
	}
	defer crypto.zero_explicit(raw_data(data), len(data))
	if len(data) != 48 {
		return .Corrupt
	}
	copy(cred[:], data[:16])
	copy(seed[:], data[16:])
	return .None
}

@(private)
_soft_prf :: proc(seed: ^[32]u8, salt: [32]u8, out: ^[32]u8) {
	s := salt
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, seed[:], 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb soft prf"))
	blake2b.update(&ctx, s[:])
	blake2b.final(&ctx, out[:])
}

@(private)
_soft_unlock :: proc(data: rawptr, rp_user: []u8, options: []Unlock_Option, mode: Unlock_Mode, reply: ^Plug_Reply, done: Plug_Done) -> Error {
	k := cast(^Soft_Passkey)data
	path := k.local if mode == .Local else k.remote
	cred: [16]u8
	seed: [32]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	_soft_load(k, path, &cred, &seed) or_return
	for o in options {
		if string(o.credential) == string(cred[:]) {
			_soft_prf(&seed, o.salt, &reply.prf)
			c := make([]u8, len(cred), context.temp_allocator)
			copy(c, cred[:])
			reply.credential = c
			return .None
		}
	}
	return .Not_Found
}

@(private)
_soft_register :: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, reply: ^Plug_Reply, done: Plug_Done) -> Error {
	k := cast(^Soft_Passkey)data
	if len(k.local) == 0 {
		return .Unsupported
	}
	cred: [16]u8
	seed: [32]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	if _soft_load(k, k.local, &cred, &seed) != .None {
		prim.random_fill(k.random, cred[:])
		prim.random_fill(k.random, seed[:])
		buf: [48]u8
		defer crypto.zero_explicit(&buf, size_of(buf))
		copy(buf[:16], cred[:])
		copy(buf[16:], seed[:])
		if err := prim.mkdir_all(k.vfs, prim.dir_name(k.local), 0o700); err != .None {
			return _from_prim(err)
		}
		_write_private(k.vfs, k.local, buf[:], false, k.random) or_return
	}
	_soft_prf(&seed, salt, &reply.prf)
	c := make([]u8, len(cred), context.temp_allocator)
	copy(c, cred[:])
	reply.credential = c
	reply.ecosystem = .Test
	return .None
}
