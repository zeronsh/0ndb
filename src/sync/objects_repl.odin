#+build linux, darwin
package osync

import "core:crypto"
import "../prim"

OBJECT_WINDOW :: 8

Obj_Op :: enum u8 {
	Put,
	Get,
	Shred,
}

Obj_Job :: struct {
	op:        Obj_Op,
	oid:       [32]u8,
	oid_len:   int,
	key:       Object_Key,
	ckey:      [32]u8,
	plain:     bool,
	pad:       bool,
	vfs:       prim.Vfs,
	data:      []u8,
	path:      string,
	fd:        prim.Fd,
	size:      i64,
	chunked:   bool,
	parts:     i64,
	next:      i64,
	flying:    [dynamic]i64,
	acked:     [dynamic]u64,
	nacked:    i64,
	part:      i64,
	part_pos:  i64,
	part_size: i64,
	sealer:    Object_Sealer,
	dest:      string,
	tmp:       string,
	out:       prim.Fd,
	head:      [OBJECT_MANIFEST]u8,
	head_have: int,
	head_need: int,
	vpos:      i64,
	got:       i64,
	req_next:  i64,
	req_out:   int,
	forgets:   int,
	opener:    ^Object_Opener,
	sink_part: i64,
	sink_pos:  i64,
	failed:    bool,
	sent:      bool,
}

Objects :: struct {
	jobs:   [dynamic]^Obj_Job,
	keys:   map[Object_Key]Part_Ref,
	active: ^Obj_Job,
	rx:     ^Obj_Job,
	rx_part: i64,
	flying: int,
}

Part_Ref :: struct {
	job:  ^Obj_Job,
	part: i64,
}

replicator_put_object :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, oid: []u8, data: []u8) -> Error {
	_enter(r)
	defer _leave(r)
	return _obj_put(r, scope, tree, oid, data, "")
}

replicator_put_object_file :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, oid: []u8, path: string) -> Error {
	_enter(r)
	defer _leave(r)
	return _obj_put(r, scope, tree, oid, nil, path)
}

replicator_get_object :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, oid: []u8, dest: string) -> Error {
	_enter(r)
	defer _leave(r)
	j := _obj_new(r, .Get, scope, tree, oid) or_return
	derr: Error
	j.dest, derr = _clone_string(dest, r.allocator)
	if derr != .None {
		_obj_free(r, j)
		return derr
	}
	return _obj_add(r, j)
}

replicator_shred_object :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, oid: []u8) -> Error {
	_enter(r)
	defer _leave(r)
	j, err := _obj_new(r, .Shred, scope, tree, oid)
	if err == .Permission {
		j, err = _obj_new(r, .Shred, scope, nil, oid)
		if err != .None {
			return err
		}
		j.failed = true
	} else if err != .None {
		return err
	}
	if tree != nil && scope.mode != .Transparent {
		if perr := object_tree_shred(tree, scope, oid); perr != .None {
			_obj_free(r, j)
			return perr
		}
	}
	return _obj_add(r, j)
}

@(private)
_obj_new :: proc(r: ^Replicator, op: Obj_Op, scope: ^Scope, tree: ^Key_Tree, oid: []u8) -> (j: ^Obj_Job, err: Error) {
	if len(oid) == 0 || len(oid) > 32 {
		return nil, .Invalid
	}
	plain := scope.mode == .Transparent
	ckey: [32]u8
	if !plain {
		if tree == nil {
			if op != .Shred {
				return nil, .Invalid
			}
		} else {
			k, ok := object_tree_key(tree, scope, oid)
			if !ok {
				return nil, .Permission
			}
			ckey = k
		}
	}
	nj, aerr := new(Obj_Job, r.allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	nj.op = op
	nj.oid_len = copy(nj.oid[:], oid)
	nj.key = object_index(scope, oid)
	nj.ckey = ckey
	nj.plain = plain
	nj.pad = r.cfg.padding && !plain
	nj.vfs = r.vfs
	nj.fd = prim.INVALID_FD
	nj.out = prim.INVALID_FD
	nj.next = -1
	nj.flying = make([dynamic]i64, r.allocator)
	nj.acked = make([dynamic]u64, r.allocator)
	crypto.zero_explicit(&ckey, size_of(ckey))
	return nj, .None
}

@(private)
_obj_put :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, oid: []u8, data: []u8, path: string) -> Error {
	j := _obj_new(r, .Put, scope, tree, oid) or_return
	if len(path) > 0 {
		st, serr := prim.stat(r.vfs, path)
		if serr != .None {
			_obj_free(r, j)
			return _from_prim(serr)
		}
		j.size = st.size
		perr: Error
		j.path, perr = _clone_string(path, r.allocator)
		if perr != .None {
			_obj_free(r, j)
			return perr
		}
	} else {
		b, berr := make([]u8, len(data), r.allocator)
		if berr != nil {
			_obj_free(r, j)
			return .No_Memory
		}
		copy(b, data)
		j.data = b
		j.size = i64(len(data))
	}
	j.chunked = j.size > OBJECT_INLINE_MAX
	if j.chunked {
		j.parts = (j.size + OBJECT_PART - 1) / OBJECT_PART
	}
	if e := resize(&j.acked, int((j.parts + 1 + 63) / 64)); e != nil {
		_obj_free(r, j)
		return .No_Memory
	}
	return _obj_add(r, j)
}

@(private)
_obj_add :: proc(r: ^Replicator, j: ^Obj_Job) -> Error {
	if _, e := append(&r.objs.jobs, j); e != nil {
		_obj_free(r, j)
		return .No_Memory
	}
	_repl_pump(r)
	return .None
}

@(private)
_objs_init :: proc(r: ^Replicator) {
	r.objs.jobs = make([dynamic]^Obj_Job, r.allocator)
	r.objs.keys = make(map[Object_Key]Part_Ref, r.allocator)
}

@(private)
_objs_destroy :: proc(r: ^Replicator) {
	for j in r.objs.jobs {
		_obj_free(r, j)
	}
	delete(r.objs.jobs)
	delete(r.objs.keys)
	r.objs = {}
}

@(private)
_obj_free :: proc(r: ^Replicator, j: ^Obj_Job) {
	if j.fd >= 0 {
		prim.close_file(j.vfs, j.fd)
	}
	if j.out >= 0 {
		prim.close_file(j.vfs, j.out)
	}
	if len(j.tmp) > 0 {
		prim.remove(j.vfs, j.tmp)
		delete(j.tmp, r.allocator)
	}
	if len(j.dest) > 0 {
		delete(j.dest, r.allocator)
	}
	if len(j.path) > 0 {
		delete(j.path, r.allocator)
	}
	if j.data != nil {
		delete(j.data, r.allocator)
	}
	if j.opener != nil {
		object_opener_reset(j.opener)
		free(j.opener, r.allocator)
	}
	object_sealer_reset(&j.sealer)
	crypto.zero_explicit(&j.ckey, size_of(j.ckey))
	delete(j.flying)
	delete(j.acked)
	free(j, r.allocator)
}

@(private)
_obj_finish :: proc(r: ^Replicator, j: ^Obj_Job, kind: Repl_Event_Kind, err: Error, path: string = "") {
	gone := make([dynamic]Object_Key, context.temp_allocator)
	for k, ref in r.objs.keys {
		if ref.job == j {
			append(&gone, k)
		}
	}
	for k in gone {
		delete_key(&r.objs.keys, k)
	}
	r.objs.flying -= len(j.flying)
	if r.objs.active == j {
		r.objs.active = nil
	}
	if r.objs.rx == j {
		r.objs.rx = nil
	}
	for i := 0; i < len(r.objs.jobs); i += 1 {
		if r.objs.jobs[i] == j {
			ordered_remove(&r.objs.jobs, i)
			break
		}
	}
	key := j.key
	_emit(r, Repl_Event{kind = kind, err = err, oid = j.oid[:j.oid_len], path = path})
	if kind == .Object_Fetched || kind == .Object_Missing || kind == .Object_Failed {
		_fetch_object_done(r, key, kind, err, path)
	}
	_obj_free(r, j)
}

@(private)
_part_key :: proc(key: Object_Key, part: i64) -> Object_Key {
	return object_part_index(key, part)
}

@(private)
_part_ckey :: proc(j: ^Obj_Job, part: i64) -> (k: [32]u8) {
	return object_part_content_key(&j.ckey, part)
}

@(private)
_part_vsize :: proc(j: ^Obj_Job, part: i64) -> i64 {
	if part >= 0 {
		return min(OBJECT_PART, j.size - part * OBJECT_PART)
	}
	if j.chunked {
		return OBJECT_MANIFEST
	}
	n := OBJECT_HEAD + j.size
	return padme(n) if j.pad else n
}

@(private)
_part_read :: proc(j: ^Obj_Job, part: i64, pos: i64, dst: []u8) -> Error {
	if part >= 0 {
		return _src_read(j, part * OBJECT_PART + pos, dst)
	}
	head: [OBJECT_MANIFEST]u8
	head[0] = 1 if j.chunked else 0
	prim.put_u64le(head[1:9], u64(j.size))
	prim.put_u32le(head[9:13], OBJECT_PART)
	hlen := i64(OBJECT_MANIFEST if j.chunked else OBJECT_HEAD)
	at := pos
	out := dst
	for len(out) > 0 {
		switch {
		case at < hlen:
			k := int(min(hlen - at, i64(len(out))))
			copy(out[:k], head[at:][:k])
			out = out[k:]
			at += i64(k)
		case !j.chunked && at - hlen < j.size:
			k := int(min(j.size - (at - hlen), i64(len(out))))
			_src_read(j, at - hlen, out[:k]) or_return
			out = out[k:]
			at += i64(k)
		case:
			for &b in out {
				b = 0
			}
			out = out[len(out):]
		}
	}
	return .None
}

@(private)
_src_read :: proc(j: ^Obj_Job, at: i64, dst: []u8) -> Error {
	if j.data != nil {
		copy(dst, j.data[at:][:len(dst)])
		return .None
	}
	got, err := prim.read_at(j.vfs, j.fd, dst, at)
	if err != .None || got != len(dst) {
		return .Io
	}
	return .None
}

@(private)
_bit :: proc "contextless" (bits: []u64, part: i64) -> bool {
	i := u64(part + 1)
	return bits[i / 64] & (u64(1) << (i % 64)) != 0
}

@(private)
_set_bit :: proc "contextless" (bits: []u64, part: i64) {
	i := u64(part + 1)
	bits[i / 64] |= u64(1) << (i % 64)
}

@(private)
_objs_pump :: proc(r: ^Replicator) {
	if r.phase != .Ready {
		return
	}
	_objs_fill(r)
	gets := make([dynamic]Object_Key, context.temp_allocator)
	for j in r.objs.jobs {
		switch j.op {
		case .Put:
		case .Get, .Shred:
			if j.op == .Shred && j.failed && !j.sent {
				j.sent = true
				_shred_forget(r, j)
				continue
			}
			if !j.sent {
				j.sent = true
				append(&gets, j.key)
				r.objs.keys[j.key] = Part_Ref{j, -1}
			}
			for j.op == .Get && j.chunked && j.req_next < j.parts && j.req_out < OBJECT_WINDOW {
				k := _part_key(j.key, j.req_next)
				r.objs.keys[k] = Part_Ref{j, j.req_next}
				append(&gets, k)
				j.req_next += 1
				j.req_out += 1
			}
		}
	}
	if len(gets) > 0 {
		client_get(&r.client, gets[:])
	}
}

@(private)
_objs_fill :: proc(r: ^Replicator) {
	for r.phase == .Ready {
		j := r.objs.active
		if j == nil {
			if r.objs.flying >= OBJECT_WINDOW || client_streaming(&r.client) {
				return
			}
			for c in r.objs.jobs {
				if c.op != .Put {
					continue
				}
				for c.next < c.parts && c.next >= -1 && _bit(c.acked[:], c.next) {
					c.next += 1
				}
				if c.next < c.parts || (c.next == -1) {
					j = c
					break
				}
			}
			if j == nil {
				return
			}
			if len(j.path) > 0 && j.fd < 0 {
				fd, err := prim.open_file(j.vfs, j.path)
				if err != .None {
					_obj_finish(r, j, .Object_Failed, _from_prim(err))
					continue
				}
				j.fd = fd
			}
			part := j.next
			j.next += 1
			j.part = part
			j.part_pos = 0
			j.part_size = _part_vsize(j, part)
			total := j.part_size if j.plain else object_sealed_size(j.part_size)
			if !j.plain {
				k := _part_ckey(j, part)
				object_sealer_init(&j.sealer, &k, j.part_size)
				crypto.zero_explicit(&k, size_of(k))
			}
			pk := _part_key(j.key, part)
			if client_put_begin(&r.client, pk, total) != .None {
				object_sealer_reset(&j.sealer)
				j.next -= 1
				return
			}
			r.objs.keys[pk] = Part_Ref{j, part}
			append(&j.flying, part)
			r.objs.flying += 1
			r.objs.active = j
		}
		for j.part_pos < j.part_size || (!j.plain && !object_sealer_done(&j.sealer)) {
			if client_queued(&r.client) >= OUT_HIGH {
				return
			}
			k := int(min(j.part_size - j.part_pos, OBJECT_CHUNK))
			if j.plain {
				dst, rerr := client_put_reserve(&r.client, k)
				if rerr != .None {
					return
				}
				if err := _part_read(j, j.part, j.part_pos, dst); err != .None {
					_repl_fail(r, err)
					return
				}
				j.part_pos += i64(k)
				continue
			}
			dst, rerr := client_put_reserve(&r.client, k + OBJECT_TAG)
			if rerr != .None {
				return
			}
			if err := _part_read(j, j.part, j.part_pos, dst[:k]); err != .None {
				_repl_fail(r, err)
				return
			}
			if _, err := object_seal_next(&j.sealer, dst[:k], dst); err != .None {
				_repl_fail(r, err)
				return
			}
			j.part_pos += i64(k)
		}
		client_put_end(&r.client)
		object_sealer_reset(&j.sealer)
		r.objs.active = nil
	}
}

@(private)
_objs_on_stored :: proc(r: ^Replicator, key: Object_Key) {
	ref, ok := r.objs.keys[key]
	if !ok {
		return
	}
	delete_key(&r.objs.keys, key)
	j := ref.job
	for i := 0; i < len(j.flying); i += 1 {
		if j.flying[i] == ref.part {
			unordered_remove(&j.flying, i)
			r.objs.flying -= 1
			break
		}
	}
	if !_bit(j.acked[:], ref.part) {
		_set_bit(j.acked[:], ref.part)
		j.nacked += 1
	}
	if j.nacked == j.parts + 1 {
		_obj_finish(r, j, .Object_Stored, .None)
	}
}

@(private)
_objs_on_refused :: proc(r: ^Replicator, key: Object_Key, code: Code) -> bool {
	ref, ok := r.objs.keys[key]
	if !ok {
		return false
	}
	_obj_finish(r, ref.job, .Object_Failed, .Quota if code == .Quota else .Refused)
	return true
}

@(private)
_objs_on_missing :: proc(r: ^Replicator, key: Object_Key) {
	ref, ok := r.objs.keys[key]
	if !ok {
		return
	}
	j := ref.job
	delete_key(&r.objs.keys, key)
	if j.op == .Shred {
		_shred_forget(r, j)
		return
	}
	_obj_finish(r, j, .Object_Missing, .Not_Found)
}

@(private)
_objs_on_forgotten :: proc(r: ^Replicator, key: Object_Key) {
	ref, ok := r.objs.keys[key]
	if !ok {
		return
	}
	delete_key(&r.objs.keys, key)
	j := ref.job
	j.forgets -= 1
	if j.forgets == 0 {
		_obj_finish(r, j, .Object_Shredded, .None)
	}
}

@(private)
_shred_forget :: proc(r: ^Replicator, j: ^Obj_Job) {
	keys := make([dynamic]Object_Key, context.temp_allocator)
	append(&keys, j.key)
	for i in 0 ..< j.parts {
		append(&keys, _part_key(j.key, i))
	}
	for k in keys {
		r.objs.keys[k] = Part_Ref{j, -2}
	}
	j.forgets = len(keys)
	crypto.zero_explicit(&j.ckey, size_of(j.ckey))
	client_forget(&r.client, keys[:])
}

@(private)
_objs_on_object :: proc(r: ^Replicator, ev: ^Event) {
	if ev.first {
		r.objs.rx = nil
		ref, ok := r.objs.keys[Object_Key(ev.id)]
		if !ok || ref.part < -1 {
			return
		}
		delete_key(&r.objs.keys, Object_Key(ev.id))
		j := ref.job
		r.objs.rx = j
		r.objs.rx_part = ref.part
		j.sink_part = ref.part
		j.sink_pos = 0
		if ref.part < 0 {
			j.head_have = 0
			j.head_need = OBJECT_HEAD
			j.vpos = 0
		}
		if j.op == .Get && j.out < 0 {
			if err := _get_open(r, j); err != .None {
				j.failed = true
			}
		}
		if !j.plain && !j.failed {
			if j.opener == nil {
				op, aerr := new(Object_Opener, r.allocator)
				if aerr != nil {
					j.failed = true
					return
				}
				j.opener = op
			}
			k := _part_ckey(j, ref.part)
			if object_opener_init(j.opener, &k, ev.total) != .None {
				j.failed = true
			}
			crypto.zero_explicit(&k, size_of(k))
		}
		return
	}
	j := r.objs.rx
	if j == nil {
		return
	}
	if len(ev.data) > 0 && !j.failed {
		if j.plain {
			if _obj_sink(j, ev.data) != .None {
				j.failed = true
			}
		} else if j.ckey == {} || object_open_feed(j.opener, ev.data, _obj_sink, j) != .None {
			j.failed = true
		}
	}
	if !ev.last {
		return
	}
	r.objs.rx = nil
	part := r.objs.rx_part
	if !j.plain && !j.failed && !object_open_done(j.opener) {
		j.failed = true
	}
	if part < 0 && !j.failed && j.head_have < j.head_need {
		j.failed = true
	}
	if j.op == .Shred {
		if j.failed {
			j.parts = 0
		}
		_shred_forget(r, j)
		return
	}
	if j.failed {
		_obj_finish(r, j, .Object_Failed, .Corrupt)
		return
	}
	if part < 0 {
		if !j.chunked {
			if j.vpos - OBJECT_HEAD < j.size {
				_obj_finish(r, j, .Object_Failed, .Corrupt)
				return
			}
			_get_complete(r, j)
			return
		}
		_repl_pump(r)
		return
	}
	j.got += 1
	j.req_out -= 1
	if j.got == j.parts {
		_get_complete(r, j)
		return
	}
	_repl_pump(r)
}

@(private)
_get_open :: proc(r: ^Replicator, j: ^Obj_Job) -> Error {
	suffix: [21]u8
	rb: [8]u8
	prim.random_fill(r.cfg.random, rb[:])
	copy(suffix[:], ".tmp.")
	prim.hex_encode(suffix[5:], rb[:])
	tmp := _concat(r.allocator, j.dest, string(suffix[:])) or_return
	j.tmp = tmp
	fd, err := prim.open_file(j.vfs, tmp, {.Write, .Create, .Exclusive}, 0o600)
	if err != .None {
		return _from_prim(err)
	}
	j.out = fd
	return .None
}

@(private)
_get_complete :: proc(r: ^Replicator, j: ^Obj_Job) {
	err := _from_prim(prim.truncate(j.vfs, j.out, j.size))
	if err == .None {
		err = _from_prim(prim.datasync(j.vfs, j.out))
	}
	prim.close_file(j.vfs, j.out)
	j.out = prim.INVALID_FD
	if err == .None {
		err = _from_prim(prim.rename(j.vfs, j.tmp, j.dest))
	}
	if err == .None {
		delete(j.tmp, r.allocator)
		j.tmp = ""
		err = _from_prim(prim.sync_dir(j.vfs, prim.dir_name(j.dest)))
	}
	dest, _ := _clone_string(j.dest, context.temp_allocator)
	_obj_finish(r, j, .Object_Fetched if err == .None else .Object_Failed, err, dest)
}

@(private)
_obj_sink :: proc(user: rawptr, plain: []u8) -> Error {
	j := cast(^Obj_Job)user
	data := plain
	if j.sink_part >= 0 {
		if j.op != .Get {
			return .None
		}
		if err := prim.write_at(j.vfs, j.out, data, j.sink_part * OBJECT_PART + j.sink_pos); err != .None {
			return _from_prim(err)
		}
		j.sink_pos += i64(len(data))
		return .None
	}
	if j.head_have < j.head_need {
		k := min(j.head_need - j.head_have, len(data))
		copy(j.head[j.head_have:], data[:k])
		j.head_have += k
		j.vpos += i64(k)
		data = data[k:]
		if j.head_have == OBJECT_HEAD {
			kind := j.head[0]
			j.size = i64(prim.get_u64le(j.head[1:9]))
			if kind > 1 || j.size < 0 {
				return .Corrupt
			}
			if kind == 1 {
				j.chunked = true
				j.head_need = OBJECT_MANIFEST
				k2 := min(j.head_need - j.head_have, len(data))
				copy(j.head[j.head_have:], data[:k2])
				j.head_have += k2
				j.vpos += i64(k2)
				data = data[k2:]
			}
		}
		if j.chunked && j.head_have == OBJECT_MANIFEST && j.parts == 0 {
			if prim.get_u32le(j.head[9:13]) != OBJECT_PART {
				return .Corrupt
			}
			j.parts = (j.size + OBJECT_PART - 1) / OBJECT_PART
		}
	}
	if len(data) == 0 || j.op != .Get || j.chunked {
		j.vpos += i64(len(data))
		return .None
	}
	at := j.vpos - OBJECT_HEAD
	keep := int(clamp(j.size - at, 0, i64(len(data))))
	j.vpos += i64(len(data))
	if keep == 0 {
		return .None
	}
	return _from_prim(prim.write_at(j.vfs, j.out, data[:keep], at))
}

@(private)
_objs_reset :: proc(r: ^Replicator) {
	if j := r.objs.active; j != nil {
		object_sealer_reset(&j.sealer)
	}
	r.objs.active = nil
	r.objs.rx = nil
	clear(&r.objs.keys)
	r.objs.flying = 0
	for j in r.objs.jobs {
		switch j.op {
		case .Put:
			lowest := j.next
			for p in j.flying {
				lowest = min(lowest, p)
			}
			j.next = lowest
			clear(&j.flying)
		case .Get:
			j.sent = false
			j.got = 0
			j.req_next = 0
			j.req_out = 0
			j.chunked = false
			j.parts = 0
			j.failed = false
			if j.out >= 0 {
				prim.close_file(j.vfs, j.out)
				j.out = prim.INVALID_FD
			}
			if len(j.tmp) > 0 {
				prim.remove(j.vfs, j.tmp)
				delete(j.tmp, r.allocator)
				j.tmp = ""
			}
		case .Shred:
			j.sent = false
			j.forgets = 0
		}
	}
}
