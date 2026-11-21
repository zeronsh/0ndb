package keystore

import "base:runtime"
import "core:crypto"
import "core:crypto/sha2"

Kind :: enum u8 {
	File,
	Secure_Enclave,
	Keychain,
	Tpm,
	Dpapi,
}

Error :: enum u8 {
	None,
	Invalid,
	Not_Found,
	Unavailable,
	Denied,
	Corrupt,
	Io,
	No_Memory,
}

Options :: struct {
	user_presence: bool,
}

Keystore :: struct {
	data:   rawptr,
	kind:   Kind,
	seal:   proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error,
	unseal: proc(data: rawptr, payload: []u8, out: []u8) -> (int, Error),
	forget: proc(data: rawptr, payload: []u8) -> Error,
	close:  proc(data: rawptr),
}

MAX_LABEL :: 48
MAX_SECRET :: 64
MAX_INNER :: 1 + MAX_LABEL + MAX_SECRET

@(private)
MAGIC :: "0ndbks"
@(private)
VERSION :: 1
@(private)
HEADER :: len(MAGIC) + 2
@(private)
FILE_CHECK :: 8

@(private)
State :: struct {
	opts:      Options,
	allocator: runtime.Allocator,
}

open_default :: proc(opts := Options{}, allocator := context.allocator) -> (Keystore, Error) {
	last := Error.Unavailable
	for kind in _PREFERENCE {
		ks, err := _open(kind, opts, true, allocator)
		if err == .None {
			return ks, .None
		}
		if err == .No_Memory {
			return {}, err
		}
		last = err
	}
	return {}, last
}

open :: proc(kind: Kind, opts := Options{}, allocator := context.allocator) -> (Keystore, Error) {
	return _open(kind, opts, false, allocator)
}

close :: proc(ks: ^Keystore) {
	if ks.close != nil {
		ks.close(ks.data)
	}
	ks^ = {}
}

seal :: proc(ks: Keystore, label: string, secret: []u8, out: ^[dynamic]u8) -> Error {
	if !_label_ok(label) || len(secret) == 0 || len(secret) > MAX_SECRET {
		return .Invalid
	}
	if ks.seal == nil {
		return .Unavailable
	}
	inner: [MAX_INNER]u8
	defer crypto.zero_explicit(&inner, size_of(inner))
	n := _inner_pack(inner[:], label, secret)
	start := len(out)
	header := [HEADER]u8{'0', 'n', 'd', 'b', 'k', 's', VERSION, u8(ks.kind)}
	if _, aerr := append(out, ..header[:]); aerr != nil {
		resize(out, start)
		return .No_Memory
	}
	if err := ks.seal(ks.data, label, inner[:n], out); err != .None {
		_wipe_tail(out, start)
		return err
	}
	return .None
}

unseal :: proc(ks: Keystore, label: string, sealed: []u8, out: []u8) -> Error {
	if !_label_ok(label) || len(out) == 0 || len(out) > MAX_SECRET {
		return .Invalid
	}
	kind, payload := _header(sealed) or_return
	if kind != ks.kind || ks.unseal == nil {
		return .Unavailable
	}
	inner: [MAX_INNER]u8
	defer crypto.zero_explicit(&inner, size_of(inner))
	n := ks.unseal(ks.data, payload, inner[:]) or_return
	if n < 1 || n > MAX_INNER {
		return .Corrupt
	}
	l := int(inner[0])
	if 1 + l > n || string(inner[1:1 + l]) != label {
		return .Corrupt
	}
	if n - 1 - l != len(out) {
		return .Corrupt
	}
	copy(out, inner[1 + l:n])
	return .None
}

forget :: proc(ks: Keystore, sealed: []u8) -> Error {
	kind, payload := _header(sealed) or_return
	if kind != ks.kind || ks.forget == nil {
		return .Unavailable
	}
	return ks.forget(ks.data, payload)
}

sealed_kind :: proc(sealed: []u8) -> (Kind, Error) {
	kind, _, err := _header(sealed)
	return kind, err
}

@(private)
_open :: proc(kind: Kind, opts: Options, probe: bool, allocator: runtime.Allocator) -> (ks: Keystore, err: Error) {
	if kind == .File {
		if opts.user_presence {
			return {}, .Unavailable
		}
	} else {
		_available(kind, opts, probe) or_return
	}
	st, aerr := new(State, allocator)
	if aerr != nil {
		return {}, .No_Memory
	}
	st.opts = opts
	st.allocator = allocator
	ks.data = st
	ks.kind = kind
	ks.close = _state_close
	switch kind {
	case .File:
		ks.seal = _file_seal
		ks.unseal = _file_unseal
		ks.forget = _nothing_to_forget
	case .Secure_Enclave, .Keychain, .Tpm, .Dpapi:
		_bind(&ks)
	}
	return ks, .None
}

@(private)
_state_close :: proc(data: rawptr) {
	st := (^State)(data)
	if st == nil {
		return
	}
	a := st.allocator
	free(st, a)
}

@(private)
_nothing_to_forget :: proc(data: rawptr, payload: []u8) -> Error {
	return .None
}

@(private)
_file_seal :: proc(data: rawptr, label: string, inner: []u8, out: ^[dynamic]u8) -> Error {
	sum := _file_sum(inner)
	if _, err := append(out, ..inner); err != nil {
		return .No_Memory
	}
	if _, err := append(out, ..sum[:]); err != nil {
		return .No_Memory
	}
	return .None
}

@(private)
_file_unseal :: proc(data: rawptr, payload: []u8, out: []u8) -> (int, Error) {
	if len(payload) <= FILE_CHECK || len(payload) - FILE_CHECK > len(out) {
		return 0, .Corrupt
	}
	n := len(payload) - FILE_CHECK
	sum := _file_sum(payload[:n])
	if crypto.compare_constant_time(sum[:], payload[n:]) != 1 {
		return 0, .Corrupt
	}
	copy(out, payload[:n])
	return n, .None
}

@(private)
_file_sum :: proc(b: []u8) -> (sum: [FILE_CHECK]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)string("0ndb keystore file"))
	sha2.update(&ctx, b)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	copy(sum[:], digest[:FILE_CHECK])
	return
}

@(private)
_header :: proc(sealed: []u8) -> (kind: Kind, payload: []u8, err: Error) {
	if len(sealed) <= HEADER || string(sealed[:len(MAGIC)]) != MAGIC {
		return {}, nil, .Corrupt
	}
	if sealed[len(MAGIC)] != VERSION || sealed[len(MAGIC) + 1] > u8(max(Kind)) {
		return {}, nil, .Corrupt
	}
	return Kind(sealed[len(MAGIC) + 1]), sealed[HEADER:], .None
}

@(private)
_inner_pack :: proc(buf: []u8, label: string, secret: []u8) -> int {
	buf[0] = u8(len(label))
	n := 1 + copy(buf[1:], label)
	n += copy(buf[n:], secret)
	return n
}

@(private)
_label_ok :: proc(label: string) -> bool {
	if len(label) == 0 || len(label) > MAX_LABEL {
		return false
	}
	for ch in transmute([]u8)label {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
		case:
			return false
		}
	}
	return true
}

@(private)
_wipe_tail :: proc(out: ^[dynamic]u8, start: int) {
	if len(out) > start {
		crypto.zero_explicit(raw_data(out[start:]), len(out) - start)
	}
	resize(out, start)
}

@(private)
_item_name :: proc(buf: []u8, label: string) -> int {
	nonce: [8]u8
	crypto.rand_bytes(nonce[:])
	n := copy(buf, "0ndb.")
	n += copy(buf[n:], label)
	buf[n] = '.'
	n += 1
	hex := "0123456789abcdef"
	for b in nonce {
		buf[n] = hex[b >> 4]
		buf[n + 1] = hex[b & 15]
		n += 2
	}
	return n
}

@(private)
MAX_NAME :: 5 + MAX_LABEL + 1 + 16

@(private)
_name_ok :: proc(name: []u8) -> bool {
	if len(name) < 6 || len(name) > MAX_NAME || string(name[:5]) != "0ndb." {
		return false
	}
	return _label_ok(string(name[5:]))
}
