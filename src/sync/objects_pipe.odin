#+build linux, darwin, windows
package osync

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "../prim"

PIPE_SPAN :: 127 * OBJECT_SEALED_CHUNK

Object_Source :: struct {
	part:  i64,
	size:  i64,
	data:  []u8,
	path:  string,
	ckey:  [32]u8,
	plain: bool,
}

replicator_get_object_from :: proc(r: ^Replicator, scope: ^Scope, tree: ^Key_Tree, oid: []u8, dest: string, holders: []Device_Id) -> Error {
	_enter(r)
	defer _leave(r)
	j := _obj_new(r, .Get, scope, tree, oid) or_return
	derr: Error
	j.dest, derr = _clone_string(dest, r.allocator)
	if derr != .None {
		_obj_free(r, j)
		return derr
	}
	for h in holders {
		if h != r.cfg.self {
			append(&j.holders, h)
		}
	}
	if o, has := r.objs.owners[j.key]; has && o.op == .Get && o.piping && o.p_tag == 0 && o.dest == j.dest {
		_pipe_merge(o, j)
		_obj_free(r, j)
		clear(&o.refused)
		o.p_unavail = false
		_pipe_pull(r, o)
		_repl_flush(r)
		return .None
	}
	return _obj_add(r, j)
}

@(private)
_pipe_merge :: proc(o: ^Obj_Job, j: ^Obj_Job) {
	outer: for h in j.holders {
		for x in o.holders {
			if x == h {
				continue outer
			}
		}
		append(&o.holders, h)
	}
}

@(private)
_pipe_absorb :: proc(r: ^Replicator, o: ^Obj_Job) {
	for i := 0; i < len(r.objs.jobs); {
		c := r.objs.jobs[i]
		if c == o || c.key != o.key || c.op != .Get || c.sent || _obj_owns(r, c) {
			i += 1
			continue
		}
		_pipe_merge(o, c)
		ordered_remove(&r.objs.jobs, i)
		_obj_free(r, c)
	}
}

replicator_object_holders :: proc(r: ^Replicator, scope: ^Scope, oid: []u8, holders: []Device_Id) {
	_enter(r)
	defer _leave(r)
	key := object_index(scope, oid)
	for j in r.objs.jobs {
		if j.op != .Get || j.key != key {
			continue
		}
		clear(&j.holders)
		for h in holders {
			if h != r.cfg.self {
				append(&j.holders, h)
			}
		}
		clear(&j.refused)
		if j.piping && j.p_tag == 0 {
			j.p_unavail = false
			_pipe_pull(r, j)
		}
	}
	_repl_flush(r)
}

@(private)
_pipe_start :: proc(r: ^Replicator, j: ^Obj_Job) -> bool {
	if j.op != .Get || len(j.holders) == 0 {
		return false
	}
	_pipe_reset(r, j)
	j.piping = true
	_pipe_pull(r, j)
	return true
}

@(private)
_pipe_reset :: proc(r: ^Replicator, j: ^Obj_Job) {
	if j.p_tag != 0 {
		client_pull_end(&r.client, j.p_holder, j.p_tag)
		delete_key(&r.objs.pulls, j.p_tag)
		j.p_tag = 0
	}
	if r.objs.prx == j {
		r.objs.prx = nil
	}
	j.p_part = -1
	j.p_at = 0
	j.p_total = 0
	j.p_open = false
	j.got = 0
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
}

@(private)
_pipe_holder :: proc(r: ^Replicator, j: ^Obj_Job) -> (d: Device_Id, ok: bool) {
	outer: for h in j.holders {
		if h == r.cfg.self {
			continue
		}
		for x in j.refused {
			if x == h {
				continue outer
			}
		}
		if p, has := r.presence[h]; has && p.up {
			return h, true
		}
	}
	return
}

@(private)
_pipe_pull :: proc(r: ^Replicator, j: ^Obj_Job) {
	if r.phase != .Ready || j.p_tag != 0 {
		return
	}
	holder, ok := _pipe_holder(r, j)
	if !ok {
		_pipe_absorb(r, j)
		holder, ok = _pipe_holder(r, j)
	}
	if !ok {
		if !j.p_unavail {
			j.p_unavail = true
			meta := make([]u8, 16 * len(j.holders), context.temp_allocator)
			for h, i in j.holders {
				v := h
				copy(meta[i * 16:], v[:])
			}
			_emit(r, Repl_Event{kind = .Unavailable, oid = j.oid[:j.oid_len], meta = meta})
		}
		return
	}
	r.pull_tag += 1
	tag := r.pull_tag
	key := _part_key(j.key, j.p_part)
	if client_pull(&r.client, holder, tag, Stream_Id(key), j.p_at, j.p_at + PIPE_SPAN) != .None {
		return
	}
	j.p_unavail = false
	j.p_holder = holder
	j.p_tag = tag
	r.objs.pulls[tag] = j
	r.read_reqs += 1
}

@(private)
_pipe_refuse :: proc(r: ^Replicator, j: ^Obj_Job, holder: Device_Id) {
	append(&j.refused, holder)
	_pipe_reset(r, j)
	_pipe_pull(r, j)
}

@(private)
_pipe_on_served :: proc(r: ^Replicator, ev: ^Event) -> bool {
	if ev.first {
		r.objs.prx = nil
		j, ok := r.objs.pulls[ev.tag]
		if !ok || j.p_holder != ev.device || Object_Key(ev.id) != _part_key(j.key, j.p_part) {
			return ok
		}
		if ev.at != j.p_at {
			_pipe_refuse(r, j, ev.device)
			return true
		}
		if !j.p_open {
			if !_pipe_open(r, j, ev.length) {
				_pipe_refuse(r, j, ev.device)
				return true
			}
		}
		r.objs.prx = j
		return true
	}
	j := r.objs.prx
	if j == nil {
		_, ok := r.objs.pulls[ev.tag]
		return ok
	}
	if len(ev.data) > 0 && !j.failed {
		if j.p_at + i64(len(ev.data)) > j.p_total {
			j.failed = true
		} else if j.plain {
			if _obj_sink(j, ev.data) != .None {
				j.failed = true
			}
		} else if object_open_feed(j.opener, ev.data, _obj_sink, j) != .None {
			j.failed = true
		}
		j.p_at += i64(len(ev.data))
	}
	if !ev.last {
		return true
	}
	r.objs.prx = nil
	if j.failed {
		_emit(r, Repl_Event{kind = .Peer_Misbehaving, err = .Corrupt, device = j.p_holder, oid = j.oid[:j.oid_len]})
		_pipe_refuse(r, j, j.p_holder)
		return true
	}
	if !ev.final {
		return true
	}
	delete_key(&r.objs.pulls, j.p_tag)
	j.p_tag = 0
	if j.p_at < j.p_total {
		_pipe_pull(r, j)
		return true
	}
	_pipe_key_done(r, j)
	return true
}

@(private)
_pipe_open :: proc(r: ^Replicator, j: ^Obj_Job, total: i64) -> bool {
	part := j.p_part
	if part >= 0 {
		want := min(OBJECT_PART, j.size - part * OBJECT_PART)
		if total != (want if j.plain else object_sealed_size(want)) {
			return false
		}
	} else if total <= 0 || (!j.plain && !_sealed_ok(total)) {
		return false
	}
	j.p_total = total
	j.p_open = true
	j.sink_part = part
	j.sink_pos = 0
	if part < 0 {
		j.head_have = 0
		j.head_need = OBJECT_HEAD
		j.vpos = 0
	}
	if j.out < 0 && _get_open(r, j) != .None {
		return false
	}
	if j.plain {
		return true
	}
	if j.opener == nil {
		op, aerr := new(Object_Opener, r.allocator)
		if aerr != nil {
			return false
		}
		j.opener = op
	}
	k := _part_ckey(j, part)
	defer crypto.zero_explicit(&k, size_of(k))
	return object_opener_init(j.opener, &k, total) == .None
}

@(private)
_sealed_ok :: proc "contextless" (total: i64) -> bool {
	_, ok := object_plain_size(total)
	return ok
}

@(private)
_pipe_key_done :: proc(r: ^Replicator, j: ^Obj_Job) {
	part := j.p_part
	if !j.plain && !object_open_done(j.opener) || part < 0 && j.head_have < j.head_need {
		_pipe_refuse(r, j, j.p_holder)
		return
	}
	j.p_open = false
	j.p_at = 0
	j.p_total = 0
	if part < 0 {
		if !j.chunked {
			if j.vpos - OBJECT_HEAD < j.size {
				_pipe_refuse(r, j, j.p_holder)
				return
			}
			_get_complete(r, j)
			return
		}
		j.p_part = 0
		_pipe_pull(r, j)
		return
	}
	j.got += 1
	if j.got >= j.parts {
		_get_complete(r, j)
		return
	}
	j.p_part = part + 1
	_pipe_pull(r, j)
}

@(private)
_pipe_on_unserved :: proc(r: ^Replicator, ev: ^Event) -> bool {
	j, ok := r.objs.pulls[ev.tag]
	if !ok || j.p_holder != ev.device {
		return false
	}
	delete_key(&r.objs.pulls, ev.tag)
	j.p_tag = 0
	_pipe_refuse(r, j, ev.device)
	return true
}

@(private)
_pipe_presence :: proc(r: ^Replicator, d: Device_Id, up: bool) {
	for j in r.objs.jobs {
		if !j.piping {
			continue
		}
		if up {
			if j.p_tag == 0 {
				clear(&j.refused)
				_pipe_pull(r, j)
			}
		} else if j.p_tag != 0 && j.p_holder == d {
			_pipe_reset(r, j)
			_pipe_pull(r, j)
		}
	}
}

@(private)
_pipe_on_reset :: proc(r: ^Replicator) {
	clear(&r.objs.pulls)
	r.objs.prx = nil
	for j in r.objs.jobs {
		if j.piping {
			j.p_tag = 0
			j.piping = false
			clear(&j.refused)
		}
	}
}

@(private)
_serve_object :: proc(r: ^Replicator, q: Serve_Req) -> bool {
	if r.cfg.object_source == nil {
		return false
	}
	src, ok := r.cfg.object_source(r.cfg.user, Object_Key(q.id), context.temp_allocator)
	if !ok {
		return false
	}
	defer crypto.zero_explicit(&src.ckey, size_of(src.ckey))
	fd := prim.INVALID_FD
	if src.data == nil {
		f, oerr := prim.open_file(r.vfs, src.path)
		if oerr != .None {
			return false
		}
		fd = f
	}
	defer if fd >= 0 {
		prim.close_file(r.vfs, fd)
	}
	chunked := src.size > OBJECT_INLINE_MAX
	pad := r.cfg.padding && !src.plain
	vsize: i64
	switch {
	case src.part >= 0:
		if src.part * OBJECT_PART >= src.size {
			return false
		}
		vsize = min(OBJECT_PART, src.size - src.part * OBJECT_PART)
	case chunked:
		vsize = OBJECT_MANIFEST
	case:
		vsize = OBJECT_HEAD + src.size
		if pad {
			vsize = padme(vsize)
		}
	}
	total := vsize if src.plain else object_sealed_size(vsize)
	from := q.from
	to := min(q.to, total)
	if from >= to {
		return false
	}
	if src.plain {
		buf := make([]u8, int(to - from), context.temp_allocator)
		if !_vread(r, &src, fd, chunked, from, buf) {
			return false
		}
		_serve_send_raw(r, q, from, buf, total)
		return true
	}
	if from % OBJECT_SEALED_CHUNK != 0 {
		return false
	}
	chunks := (vsize + OBJECT_CHUNK - 1) / OBJECT_CHUNK
	if chunks == 0 {
		chunks = 1
	}
	first := from / OBJECT_SEALED_CHUNK
	end := (to + OBJECT_SEALED_CHUNK - 1) / OBJECT_SEALED_CHUNK
	key := object_part_content_key(&src.ckey, src.part)
	defer crypto.zero_explicit(&key, size_of(key))
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	out := make([dynamic]u8, 0, int(min(to - from, PIPE_SPAN)), context.temp_allocator)
	plain: [OBJECT_CHUNK]u8
	for i := first; i < end && i < chunks; i += 1 {
		n := int(min(OBJECT_CHUNK, vsize - i * OBJECT_CHUNK))
		if !_vread(r, &src, fd, chunked, i * OBJECT_CHUNK, plain[:n]) {
			return false
		}
		at := len(out)
		resize(&out, at + n + OBJECT_TAG)
		iv := _object_iv(u64(i), i + 1 == chunks)
		chacha20poly1305.seal(&ctx, out[at:at + n], out[at + n:at + n + OBJECT_TAG], iv[:], nil, plain[:n])
	}
	crypto.zero_explicit(&plain, size_of(plain))
	_serve_send_raw(r, q, from, out[:], total)
	return true
}

@(private)
_vread :: proc(r: ^Replicator, src: ^Object_Source, fd: prim.Fd, chunked: bool, pos: i64, dst: []u8) -> bool {
	read :: proc(r: ^Replicator, src: ^Object_Source, fd: prim.Fd, at: i64, dst: []u8) -> bool {
		if at < 0 || at + i64(len(dst)) > src.size {
			return false
		}
		if src.data != nil {
			copy(dst, src.data[at:][:len(dst)])
			return true
		}
		got, err := prim.read_at(r.vfs, fd, dst, at)
		return err == .None && got == len(dst)
	}
	if src.part >= 0 {
		return read(r, src, fd, src.part * OBJECT_PART + pos, dst)
	}
	head: [OBJECT_MANIFEST]u8
	head[0] = 1 if chunked else 0
	prim.put_u64le(head[1:9], u64(src.size))
	prim.put_u32le(head[9:13], OBJECT_PART)
	hlen := i64(OBJECT_MANIFEST if chunked else OBJECT_HEAD)
	at := pos
	out := dst
	for len(out) > 0 {
		switch {
		case at < hlen:
			k := int(min(hlen - at, i64(len(out))))
			copy(out[:k], head[at:][:k])
			out = out[k:]
			at += i64(k)
		case !chunked && at - hlen < src.size:
			k := int(min(src.size - (at - hlen), i64(len(out))))
			if !read(r, src, fd, at - hlen, out[:k]) {
				return false
			}
			out = out[k:]
			at += i64(k)
		case:
			for &b in out {
				b = 0
			}
			out = out[len(out):]
		}
	}
	return true
}

@(private)
_serve_send_raw :: proc(r: ^Replicator, q: Serve_Req, at: i64, data: []u8, length: i64) {
	pos := 0
	for {
		n := min(len(data) - pos, SERVE_MAX)
		dst, err := client_serve_reserve(&r.client, q.requester, q.tag, q.id, at + i64(pos), n)
		if err != .None {
			return
		}
		copy(dst, data[pos:pos + n])
		pos += n
		word := u64(max(length, at + i64(pos))) & SERVE_LEN_MASK
		if pos >= len(data) {
			word |= SERVE_FINAL
		}
		client_serve_commit(&r.client, n, n, word)
		r.served_bytes += i64(n)
		if pos >= len(data) {
			return
		}
	}
}
