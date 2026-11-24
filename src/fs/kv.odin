package fs

import "base:runtime"
import "core:hash/xxhash"
import "core:strconv"
import "core:sync"
import "../prim"

KV_MAGIC :: u64(0x3167_6f6c_7662_6430)
KV_IDX_MAGIC :: u64(0x3178_6469_7662_6430)
KV_HEADER :: 4096
KV_LOG_HEADER :: 16
KV_SLOT :: 16
KV_MIN_CAP :: u64(256)
KV_MAX_RECORD :: 64 << 20
KV_LOG_MARKED :: u32(1)

Kv :: struct {
	vfs:       prim.Vfs,
	dir:       string,
	name:      string,
	allocator: runtime.Allocator,
	gen:       u64,
	log_fd:    prim.Fd,
	idx_fd:    prim.Fd,
	cap:       u64,
	used:      u64,
	live:      u64,
	live_bytes: u64,
	log_end:   u64,
	covered:   u64,
	idx_owed:  bool,
	marked:    bool,
	clean_disk: bool,
	pending:   map[string]Kv_Pending,
	order:     [dynamic]string,
	groups:    [dynamic]Kv_Group,
	buf:       [dynamic]u8,
	probe:     [dynamic]u8,
	out:       [dynamic]u8,
	mapped:    []u8,
	map_lock:  ^sync.Mutex,
}

@(private = "file")
Kv_Pending :: struct {
	value: []u8,
	del:   bool,
}

@(private)
Kv_Group :: struct {
	mark:    u64,
	pending: map[string]Kv_Pending,
	order:   [dynamic]string,
}

@(private = "file")
Kv_Rec :: struct {
	off:    u64,
	size:   u64,
	del:    bool,
	commit: bool,
	key:    []u8,
	value:  []u8,
}

kv_open :: proc(kv: ^Kv, vfs: prim.Vfs, dir: string, name: string, allocator := context.allocator) -> Error {
	kv^ = {
		vfs       = vfs,
		allocator = allocator,
		log_fd    = prim.INVALID_FD,
		idx_fd    = prim.INVALID_FD,
	}
	d, e1 := clone_string(dir, allocator)
	n, e2 := clone_string(name, allocator)
	if e1 != nil || e2 != nil {
		delete(d, allocator)
		delete(n, allocator)
		return .No_Memory
	}
	kv.dir = d
	kv.name = n
	if err := from_prim(prim.mkdir_all(kv.vfs, dir, 0o700)); err != .None {
		kv_close(kv)
		return err
	}
	kv.gen = kv_read_gen(kv)
	if err := kv_attach(kv); err != .None {
		kv_close(kv)
		return err
	}
	return .None
}

kv_attach :: proc(kv: ^Kv) -> Error {
	if kv.log_fd >= 0 {
		return .None
	}
	kv.pending = make(map[string]Kv_Pending, kv.allocator)
	kv.order = make([dynamic]string, kv.allocator)
	kv.buf = make([dynamic]u8, kv.allocator)
	kv.probe = make([dynamic]u8, kv.allocator)
	kv.out = make([dynamic]u8, kv.allocator)
	err := kv_open_gen(kv)
	if err != .None {
		kv_detach(kv)
	}
	return err
}

kv_detach :: proc(kv: ^Kv) {
	kv_unmap(kv)
	if kv.idx_fd >= 0 && kv.log_fd >= 0 && len(kv.order) == 0 {
		if kv.covered == kv.log_end || kv_checkpoint(kv) == .None {
			kv_write_header(kv, true)
		}
	}
	prim.close_file(kv.vfs, kv.log_fd)
	prim.close_file(kv.vfs, kv.idx_fd)
	kv.log_fd = prim.INVALID_FD
	kv.idx_fd = prim.INVALID_FD
	kv_pending_clear(kv)
	kv_groups_free(kv, &kv.groups, kv.allocator)
	delete(kv.pending)
	delete(kv.order)
	delete(kv.buf)
	delete(kv.probe)
	delete(kv.out)
	kv.pending = nil
	kv.order = nil
	kv.buf = nil
	kv.probe = nil
	kv.out = nil
}

kv_close :: proc(kv: ^Kv) {
	kv_detach(kv)
	delete(kv.dir, kv.allocator)
	delete(kv.name, kv.allocator)
	kv.dir = ""
	kv.name = ""
}

kv_dirty :: proc "contextless" (kv: ^Kv) -> bool {
	return len(kv.order) > 0
}

kv_get :: proc(kv: ^Kv, key: []u8, allocator := context.allocator) -> (value: []u8, found: bool, err: Error) {
	if p, ok := kv_queued(kv, key); ok {
		if p.del {
			return nil, false, .None
		}
		out, aerr := make([]u8, len(p.value), allocator)
		if aerr != nil {
			return nil, false, .No_Memory
		}
		copy(out, p.value)
		return out, true, .None
	}
	_, off, ok := kv_find(kv, key) or_return
	if !ok {
		return nil, false, .None
	}
	r := kv_read(kv, off, &kv.buf) or_return
	if r.del {
		return nil, false, .None
	}
	out, aerr := make([]u8, len(r.value), allocator)
	if aerr != nil {
		return nil, false, .No_Memory
	}
	copy(out, r.value)
	return out, true, .None
}

kv_put :: proc(kv: ^Kv, key: []u8, value: []u8) -> Error {
	return kv_set(kv, key, value, false)
}

kv_del :: proc(kv: ^Kv, key: []u8) -> Error {
	return kv_set(kv, key, nil, true)
}

kv_commit :: proc(kv: ^Kv) -> Error {
	if len(kv.order) == 0 {
		return .None
	}
	if kv.log_fd < 0 {
		return .Invalid
	}
	want := kv_cap_for(kv.used + u64(len(kv.order)) + 1)
	if want > kv.cap {
		kv_rebuild(kv, want) or_return
	}
	if kv.clean_disk {
		kv_write_header(kv, false)
		from_prim(prim.datasync(kv.vfs, kv.idx_fd)) or_return
		kv.clean_disk = false
	}
	clear(&kv.out)
	start := kv.log_end
	for k in kv.order {
		p := kv.pending[k]
		if kv_encode(&kv.out, start + u64(len(kv.out)), transmute([]u8)k, p.value, p.del) == 0 {
			return .Too_Large
		}
	}
	if kv.marked {
		kv_encode_commit(&kv.out, start + u64(len(kv.out)))
	}
	if err := prim.write_at(kv.vfs, kv.log_fd, kv.out[:], i64(start)); err != .None {
		prim.truncate(kv.vfs, kv.log_fd, i64(start))
		return from_prim(err)
	}
	if err := prim.datasync(kv.vfs, kv.log_fd); err != .None {
		prim.truncate(kv.vfs, kv.log_fd, i64(start))
		return from_prim(err)
	}
	kv.log_end = start + u64(len(kv.out))
	kv_map(kv)
	pos := 0
	for pos < len(kv.out) {
		n := int(prim.get_u32le(kv.out[pos:pos + 4]))
		r := kv_decode(kv.out[pos + 8:][:n]) or_return
		r.off = start + u64(pos)
		r.size = u64(n + 8)
		if r.commit {
			pos += n + 8
			continue
		}
		if err := kv_apply(kv, r); err != .None {
			kv_unmap(kv)
			return err
		}
		pos += n + 8
	}
	kv_unmap(kv)
	kv_pending_clear(kv)
	if cap(kv.out) > 1 << 20 {
		delete(kv.out)
		kv.out = make([dynamic]u8, kv.allocator)
	}
	if kv.log_end - kv.covered >= 1 << 20 {
		kv_checkpoint(kv) or_return
	} else {
		kv_write_header(kv, false)
	}
	if kv.log_end > 8 << 20 && kv.live_bytes < kv.log_end / 2 {
		return kv_compact(kv)
	}
	return .None
}

kv_each :: proc(kv: ^Kv, data: rawptr, visit: proc(data: rawptr, key: []u8, value: []u8) -> bool) -> Error {
	if len(kv.groups) == 0 {
		if len(kv.order) > 0 {
			kv_commit(kv) or_return
		}
		return kv_each_committed(kv, data, visit)
	}
	seen := make(map[string]bool, 64, context.temp_allocator)
	visit_one :: proc(seen: ^map[string]bool, k: string, p: Kv_Pending, data: rawptr, visit: proc(data: rawptr, key: []u8, value: []u8) -> bool) -> bool {
		if k in seen {
			return true
		}
		seen[k] = true
		if p.del {
			return true
		}
		return visit(data, transmute([]u8)k, p.value)
	}
	#reverse for k in kv.order {
		if !visit_one(&seen, k, kv.pending[k], data, visit) {
			return .None
		}
	}
	#reverse for &g in kv.groups {
		#reverse for k in g.order {
			if !visit_one(&seen, k, g.pending[k], data, visit) {
				return .None
			}
		}
	}
	Wrap :: struct {
		seen:  ^map[string]bool,
		data:  rawptr,
		visit: proc(data: rawptr, key: []u8, value: []u8) -> bool,
	}
	wr := Wrap{&seen, data, visit}
	return kv_each_committed(kv, &wr, proc(data: rawptr, key: []u8, value: []u8) -> bool {
		w := (^Wrap)(data)
		if string(key) in w.seen {
			return true
		}
		return w.visit(w.data, key, value)
	})
}

@(private)
kv_queued :: proc(kv: ^Kv, key: []u8) -> (p: Kv_Pending, ok: bool) {
	if x, has := kv.pending[string(key)]; has {
		return x, true
	}
	#reverse for &g in kv.groups {
		if x, has := g.pending[string(key)]; has {
			return x, true
		}
	}
	return {}, false
}

kv_seal :: proc(kv: ^Kv, mark: u64) {
	if len(kv.order) == 0 {
		return
	}
	n := len(kv.groups)
	if n > 0 && kv.groups[n - 1].mark == mark {
		g := &kv.groups[n - 1]
		for k in kv.order {
			p := kv.pending[k]
			if old, has := &g.pending[k]; has {
				delete(old.value, kv.allocator)
				old^ = p
				delete(k, kv.allocator)
			} else {
				g.pending[k] = p
				append(&g.order, k)
			}
		}
		clear(&kv.pending)
		clear(&kv.order)
		return
	}
	append(&kv.groups, Kv_Group{mark, kv.pending, kv.order})
	kv.pending = make(map[string]Kv_Pending, kv.allocator)
	kv.order = make([dynamic]string, kv.allocator)
}

kv_commit_upto :: proc(kv: ^Kv, mark: u64) -> Error {
	if len(kv.groups) == 0 || kv.groups[0].mark > mark {
		return .None
	}
	cur_p, cur_o := kv.pending, kv.order
	defer {
		kv.pending, kv.order = cur_p, cur_o
	}
	for len(kv.groups) > 0 && kv.groups[0].mark <= mark {
		kv.pending, kv.order = kv.groups[0].pending, kv.groups[0].order
		if err := kv_commit(kv); err != .None {
			kv.groups[0].pending, kv.groups[0].order = kv.pending, kv.order
			return err
		}
		delete(kv.pending)
		delete(kv.order)
		ordered_remove(&kv.groups, 0)
	}
	return .None
}

kv_groups_take :: proc(kv: ^Kv) -> (groups: [dynamic]Kv_Group) {
	groups = kv.groups
	kv.groups = nil
	return
}

kv_groups_give :: proc(kv: ^Kv, groups: [dynamic]Kv_Group) {
	kv.groups = groups
}

kv_groups_free :: proc(kv: ^Kv, groups: ^[dynamic]Kv_Group, allocator: runtime.Allocator) {
	for &g in groups {
		for k in g.order {
			p := g.pending[k]
			delete(p.value, allocator)
			delete(k, allocator)
		}
		delete(g.pending)
		delete(g.order)
	}
	delete(groups^)
	groups^ = nil
}

@(private = "file")
kv_each_committed :: proc(kv: ^Kv, data: rawptr, visit: proc(data: rawptr, key: []u8, value: []u8) -> bool) -> Error {
	off := u64(KV_LOG_HEADER)
	for off < kv.log_end {
		r := kv_read(kv, off, &kv.buf) or_return
		off += r.size
		if r.del {
			continue
		}
		key := make([]u8, len(r.key), context.temp_allocator)
		copy(key, r.key)
		_, cur, ok := kv_find(kv, key) or_return
		if !ok || cur != r.off {
			continue
		}
		r2 := kv_read(kv, r.off, &kv.buf) or_return
		if !visit(data, key, r2.value) {
			return .None
		}
	}
	return .None
}

kv_compact :: proc(kv: ^Kv) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if len(kv.order) > 0 {
		kv_commit(kv) or_return
	}
	n := Kv {
		vfs       = kv.vfs,
		dir       = kv.dir,
		name      = kv.name,
		allocator = kv.allocator,
		gen       = kv.gen + 1,
		log_fd    = prim.INVALID_FD,
		idx_fd    = prim.INVALID_FD,
	}
	log_path := kv_path(kv, n.gen, "log", context.temp_allocator)
	idx_path := kv_path(kv, n.gen, "idx", context.temp_allocator)
	prim.remove(kv.vfs, log_path)
	prim.remove(kv.vfs, idx_path)
	n.pending = make(map[string]Kv_Pending, kv.allocator)
	n.order = make([dynamic]string, kv.allocator)
	n.buf = make([dynamic]u8, kv.allocator)
	n.probe = make([dynamic]u8, kv.allocator)
	n.out = make([dynamic]u8, kv.allocator)
	ok := false
	defer if !ok {
		kv_detach(&n)
		prim.remove(kv.vfs, log_path)
		prim.remove(kv.vfs, idx_path)
	}
	kv_create(&n, kv_cap_for(kv.live + 1)) or_return
	Copy :: struct {
		dst: ^Kv,
		err: Error,
	}
	c := Copy{&n, .None}
	kv_each_committed(kv, &c, proc(data: rawptr, key: []u8, value: []u8) -> bool {
		c := (^Copy)(data)
		c.err = kv_put(c.dst, key, value)
		if c.err == .None && len(c.dst.order) >= 4096 {
			c.err = kv_commit(c.dst)
		}
		return c.err == .None
	}) or_return
	c.err or_return
	kv_commit(&n) or_return
	kv_checkpoint(&n) or_return
	kv_write_header(&n, true)
	from_prim(prim.datasync(kv.vfs, n.idx_fd)) or_return
	kv_write_gen(kv, n.gen) or_return
	ok = true
	kv_detach(&n)
	old_log := kv_path(kv, kv.gen, "log", context.temp_allocator)
	old_idx := kv_path(kv, kv.gen, "idx", context.temp_allocator)
	held := kv_groups_take(kv)
	kv_detach(kv)
	prim.remove(kv.vfs, old_log)
	prim.remove(kv.vfs, old_idx)
	kv.gen = n.gen
	err := kv_attach(kv)
	kv_groups_give(kv, held)
	return err
}

@(private = "file")
kv_set :: proc(kv: ^Kv, key: []u8, value: []u8, del: bool) -> Error {
	v: []u8
	if !del {
		aerr: runtime.Allocator_Error
		v, aerr = make([]u8, len(value), kv.allocator)
		if aerr != nil {
			return .No_Memory
		}
		copy(v, value)
	}
	if p, ok := &kv.pending[string(key)]; ok {
		delete(p.value, kv.allocator)
		p.value = v
		p.del = del
		return .None
	}
	k, aerr := clone_string(string(key), kv.allocator)
	if aerr != nil {
		delete(v, kv.allocator)
		return .No_Memory
	}
	kv.pending[k] = Kv_Pending{v, del}
	append(&kv.order, k)
	return .None
}

@(private = "file")
kv_pending_clear :: proc(kv: ^Kv) {
	for k in kv.order {
		p := kv.pending[k]
		delete(p.value, kv.allocator)
		delete(k, kv.allocator)
	}
	clear(&kv.pending)
	clear(&kv.order)
	if cap(kv.order) > 1024 {
		delete(kv.order)
		delete(kv.pending)
		kv.order = make([dynamic]string, kv.allocator)
		kv.pending = make(map[string]Kv_Pending, kv.allocator)
	}
}

@(private = "file")
kv_hash :: proc(key: []u8) -> u64 {
	if len(key) == 0 {
		return 0x9e37_79b9_7f4a_7c15
	}
	h := xxhash.XXH3_64_with_seed(key, 0x6b76)
	return h if h != 0 else 1
}

@(private = "file")
kv_cap_for :: proc "contextless" (n: u64) -> u64 {
	c := KV_MIN_CAP
	for c * 5 < n * 8 {
		c *= 2
	}
	return c
}

@(private = "file")
kv_slot_read :: proc(kv: ^Kv, i: u64) -> (h: u64, off: u64, err: Error) {
	b: [KV_SLOT]u8
	pos := KV_HEADER + i * KV_SLOT
	if kv.mapped != nil {
		if pos + KV_SLOT > u64(len(kv.mapped)) {
			return 0, 0, .Corrupt
		}
		copy(b[:], kv.mapped[pos:])
	} else {
		got, rerr := prim.read_at(kv.vfs, kv.idx_fd, b[:], i64(pos))
		if rerr != .None {
			return 0, 0, from_prim(rerr)
		}
		if got != KV_SLOT {
			return 0, 0, .Corrupt
		}
	}
	return prim.get_u64le(b[0:8]), prim.get_u64le(b[8:16]), .None
}

@(private = "file")
kv_slot_write :: proc(kv: ^Kv, i: u64, h: u64, off: u64) -> Error {
	b: [KV_SLOT]u8
	prim.put_u64le(b[0:8], h)
	prim.put_u64le(b[8:16], off)
	pos := KV_HEADER + i * KV_SLOT
	if kv.mapped != nil {
		if pos + KV_SLOT > u64(len(kv.mapped)) {
			return .Corrupt
		}
		copy(kv.mapped[pos:], b[:])
		return .None
	}
	return from_prim(prim.write_at(kv.vfs, kv.idx_fd, b[:], i64(pos)))
}

@(private = "file")
kv_find :: proc(kv: ^Kv, key: []u8) -> (index: u64, off: u64, found: bool, err: Error) {
	if kv.idx_fd < 0 || kv.cap == 0 {
		return 0, 0, false, .Invalid
	}
	h := kv_hash(key)
	mask := kv.cap - 1
	i := h & mask
	for _ in 0 ..< kv.cap {
		sh, so := kv_slot_read(kv, i) or_return
		if sh == 0 {
			return i, 0, false, .None
		}
		if sh == h {
			r, rerr := kv_read(kv, so, &kv.probe)
			if rerr == .None && string(r.key) == string(key) {
				return i, so, true, .None
			}
		}
		i = (i + 1) & mask
	}
	return 0, 0, false, .Corrupt
}

@(private = "file")
kv_apply :: proc(kv: ^Kv, r: Kv_Rec) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	key := make([]u8, len(r.key), context.temp_allocator)
	copy(key, r.key)
	i, off, found := kv_find(kv, key) or_return
	if found && off >= r.off {
		return .None
	}
	if found {
		old := kv_read(kv, off, &kv.buf) or_return
		if !old.del {
			kv.live -= 1
			kv.live_bytes -= min(kv.live_bytes, old.size)
		}
	} else {
		kv.used += 1
	}
	if !r.del {
		kv.live += 1
		kv.live_bytes += r.size
	}
	return kv_slot_write(kv, i, kv_hash(key), r.off)
}

@(private = "file")
kv_encode :: proc(out: ^[dynamic]u8, off: u64, key: []u8, value: []u8, del: bool) -> int {
	start := len(out)
	resize(out, start + 8)
	w := prim.writer(out)
	prim.write_u8(&w, 2 if del else 1)
	prim.write_bytes(&w, key)
	if !del {
		prim.write_bytes(&w, value)
	}
	n := len(out) - start - 8
	if w.err != .None || n > KV_MAX_RECORD {
		resize(out, start)
		return 0
	}
	prim.put_u32le(out[start:start + 4], u32(n))
	prim.put_u32le(out[start + 4:start + 8], u32(xxhash.XXH3_64_with_seed(out[start + 8:], off)))
	return n + 8
}

@(private = "file")
kv_encode_commit :: proc(out: ^[dynamic]u8, off: u64) {
	start := len(out)
	resize(out, start + 9)
	out[start + 8] = 3
	prim.put_u32le(out[start:start + 4], 1)
	prim.put_u32le(out[start + 4:start + 8], u32(xxhash.XXH3_64_with_seed(out[start + 8:], off)))
}

@(private = "file")
kv_decode :: proc(body: []u8) -> (r: Kv_Rec, err: Error) {
	if len(body) == 1 && body[0] == 3 {
		r.commit = true
		return r, .None
	}
	rd := prim.reader(body)
	kind := prim.read_u8(&rd)
	r.key = prim.read_bytes(&rd)
	switch kind {
	case 1:
		r.value = prim.read_bytes(&rd)
	case 2:
		r.del = true
	case:
		return {}, .Corrupt
	}
	if !prim.reader_ok(&rd) || !prim.reader_done(&rd) {
		return {}, .Corrupt
	}
	return r, .None
}

@(private = "file")
kv_read :: proc(kv: ^Kv, off: u64, buf: ^[dynamic]u8) -> (r: Kv_Rec, err: Error) {
	if off < KV_LOG_HEADER || off + 8 > kv.log_end {
		return {}, .Corrupt
	}
	want := min(u64(4096), kv.log_end - off)
	if len(buf) < int(want) {
		resize(buf, int(want))
	}
	got, rerr := prim.read_at(kv.vfs, kv.log_fd, buf[:want], i64(off))
	if rerr != .None {
		return {}, from_prim(rerr)
	}
	if got < 8 {
		return {}, .Corrupt
	}
	n := u64(prim.get_u32le(buf[0:4]))
	if n > KV_MAX_RECORD || off + 8 + n > kv.log_end {
		return {}, .Corrupt
	}
	if 8 + n > u64(got) {
		if len(buf) < int(8 + n) {
			resize(buf, int(8 + n))
		}
		got, rerr = prim.read_at(kv.vfs, kv.log_fd, buf[:8 + n], i64(off))
		if rerr != .None {
			return {}, from_prim(rerr)
		}
		if u64(got) != 8 + n {
			return {}, .Corrupt
		}
	}
	body := buf[8:][:n]
	if u32(xxhash.XXH3_64_with_seed(body, off)) != prim.get_u32le(buf[4:8]) {
		return {}, .Corrupt
	}
	r = kv_decode(body) or_return
	r.off = off
	r.size = 8 + n
	return r, .None
}

@(private = "file")
kv_path :: proc(kv: ^Kv, gen: u64, ext: string, allocator: runtime.Allocator) -> string {
	digits: [24]u8
	num := strconv.write_uint(digits[:], gen, 10)
	buf := make([]u8, len(kv.dir) + 1 + len(kv.name) + 1 + len(num) + 1 + len(ext), allocator)
	n := copy(buf, kv.dir)
	buf[n] = '/'
	n += 1
	n += copy(buf[n:], kv.name)
	buf[n] = '.'
	n += 1
	n += copy(buf[n:], num)
	buf[n] = '.'
	copy(buf[n + 1:], ext)
	return string(buf)
}

@(private = "file")
kv_read_gen :: proc(kv: ^Kv) -> u64 {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := kv_path(kv, 0, "gen", context.temp_allocator)
	fd, err := prim.open_file(kv.vfs, p)
	if err != .None {
		return 0
	}
	defer prim.close_file(kv.vfs, fd)
	b: [16]u8
	n, _ := prim.read_at(kv.vfs, fd, b[:], 0)
	if n != 16 || u32(xxhash.XXH3_64_default(b[0:8])) != prim.get_u32le(b[8:12]) {
		return 0
	}
	return prim.get_u64le(b[0:8])
}

@(private = "file")
kv_write_gen :: proc(kv: ^Kv, gen: u64) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := kv_path(kv, 0, "gen", context.temp_allocator)
	b: [16]u8
	prim.put_u64le(b[0:8], gen)
	prim.put_u32le(b[8:12], u32(xxhash.XXH3_64_default(b[0:8])))
	return from_prim(prim.replace_atomic(kv.vfs, p, b[:]))
}

@(private = "file")
kv_open_gen :: proc(kv: ^Kv) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log_path := kv_path(kv, kv.gen, "log", context.temp_allocator)
	idx_path := kv_path(kv, kv.gen, "idx", context.temp_allocator)
	fd, err := prim.open_file(kv.vfs, log_path, {.Write, .Group_Visible}, 0o600)
	if err == .Not_Found {
		prim.remove(kv.vfs, idx_path)
		return kv_create(kv, KV_MIN_CAP)
	}
	if err != .None {
		return from_prim(err)
	}
	kv.log_fd = fd
	size, serr := prim.file_size(kv.vfs, fd)
	if serr != .None {
		return from_prim(serr)
	}
	hdr: [KV_LOG_HEADER]u8
	got, rerr := prim.read_at(kv.vfs, fd, hdr[:], 0)
	if rerr != .None {
		return from_prim(rerr)
	}
	if got != KV_LOG_HEADER || prim.get_u64le(hdr[0:8]) != KV_MAGIC {
		return .Corrupt
	}
	kv.marked = prim.get_u32le(hdr[8:12]) == KV_LOG_MARKED
	kv.log_end = u64(size)
	ifd, ierr := prim.open_file(kv.vfs, idx_path, {.Write, .Group_Visible}, 0o600)
	if ierr == .None {
		kv.idx_fd = ifd
		if clean, valid := kv_load_header(kv); valid {
			if clean && kv.covered == kv.log_end {
				kv.clean_disk = true
				return .None
			}
			return kv_recover(kv)
		}
		prim.close_file(kv.vfs, ifd)
		kv.idx_fd = prim.INVALID_FD
	} else if ierr != .Not_Found {
		return from_prim(ierr)
	}
	return kv_rebuild(kv, KV_MIN_CAP)
}

@(private = "file")
kv_create :: proc(kv: ^Kv, capacity: u64) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log_path := kv_path(kv, kv.gen, "log", context.temp_allocator)
	idx_path := kv_path(kv, kv.gen, "idx", context.temp_allocator)
	fd, oerr := prim.open_file(kv.vfs, log_path, {.Write, .Create, .Truncate, .Group_Visible}, 0o600)
	if oerr != .None {
		return from_prim(oerr)
	}
	kv.log_fd = fd
	hdr: [KV_LOG_HEADER]u8
	prim.put_u64le(hdr[0:8], KV_MAGIC)
	prim.put_u32le(hdr[8:12], KV_LOG_MARKED)
	kv.marked = true
	from_prim(prim.write_at(kv.vfs, fd, hdr[:], 0)) or_return
	from_prim(prim.datasync(kv.vfs, fd)) or_return
	kv.log_end = KV_LOG_HEADER
	ifd, ierr := prim.open_file(kv.vfs, idx_path, {.Write, .Create, .Truncate, .Group_Visible}, 0o600)
	if ierr != .None {
		return from_prim(ierr)
	}
	kv.idx_fd = ifd
	kv.cap = capacity
	kv.used = 0
	kv.live = 0
	kv.live_bytes = 0
	kv.covered = KV_LOG_HEADER
	kv_zero(kv, ifd, i64(KV_HEADER + capacity * KV_SLOT)) or_return
	kv_write_header(kv, false)
	from_prim(prim.datasync(kv.vfs, ifd)) or_return
	from_prim(prim.sync_dir(kv.vfs, kv.dir)) or_return
	if kv.gen == 0 {
		kv_write_gen(kv, 0) or_return
	}
	return .None
}

@(private = "file")
kv_zero :: proc(kv: ^Kv, fd: prim.Fd, size: i64) -> Error {
	from_prim(prim.truncate(kv.vfs, fd, 0)) or_return
	zeros: [64 * 1024]u8
	pos: i64
	for pos < size {
		n := min(i64(len(zeros)), size - pos)
		from_prim(prim.write_at(kv.vfs, fd, zeros[:n], pos)) or_return
		pos += n
	}
	return .None
}

@(private = "file")
kv_load_header :: proc(kv: ^Kv) -> (clean: bool, valid: bool) {
	b: [64]u8
	got, err := prim.read_at(kv.vfs, kv.idx_fd, b[:], 0)
	if err != .None || got != len(b) {
		return
	}
	if prim.get_u64le(b[0:8]) != KV_IDX_MAGIC || xxhash.XXH3_64_default(b[0:56]) != prim.get_u64le(b[56:64]) {
		return
	}
	kv.cap = prim.get_u64le(b[8:16])
	kv.used = prim.get_u64le(b[16:24])
	kv.live = prim.get_u64le(b[24:32])
	kv.live_bytes = prim.get_u64le(b[32:40])
	kv.covered = prim.get_u64le(b[40:48])
	clean = prim.get_u64le(b[48:56]) == 1
	if kv.cap < KV_MIN_CAP || kv.cap & (kv.cap - 1) != 0 || kv.cap > 1 << 40 || kv.covered < KV_LOG_HEADER || kv.covered > kv.log_end {
		return false, false
	}
	size, serr := prim.file_size(kv.vfs, kv.idx_fd)
	if serr != .None || u64(size) < KV_HEADER + kv.cap * KV_SLOT {
		return false, false
	}
	return clean, true
}

@(private = "file")
kv_write_header :: proc(kv: ^Kv, clean: bool) {
	b: [64]u8
	prim.put_u64le(b[0:8], KV_IDX_MAGIC)
	prim.put_u64le(b[8:16], kv.cap)
	prim.put_u64le(b[16:24], kv.used)
	prim.put_u64le(b[24:32], kv.live)
	prim.put_u64le(b[32:40], kv.live_bytes)
	prim.put_u64le(b[40:48], kv.covered)
	prim.put_u64le(b[48:56], 1 if clean else 0)
	prim.put_u64le(b[56:64], xxhash.XXH3_64_default(b[0:56]))
	prim.write_at(kv.vfs, kv.idx_fd, b[:], 0)
}

@(private = "file")
kv_checkpoint :: proc(kv: ^Kv) -> Error {
	from_prim(prim.sync_owed(kv.vfs, kv.idx_fd, &kv.idx_owed)) or_return
	kv.covered = kv.log_end
	kv_write_header(kv, false)
	return .None
}

@(private = "file")
kv_recover :: proc(kv: ^Kv) -> Error {
	return kv_rebuild(kv, kv.cap)
}

@(private = "file")
kv_rebuild :: proc(kv: ^Kv, capacity: u64) -> Error {
	c := max(capacity, KV_MIN_CAP)
	for {
		full, err := kv_rebuild_into(kv, c)
		if err != .None {
			return err
		}
		if !full {
			return .None
		}
		c *= 2
	}
}

@(private = "file")
kv_rebuild_into :: proc(kv: ^Kv, capacity: u64) -> (full: bool, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	idx_path := kv_path(kv, kv.gen, "idx", context.temp_allocator)
	tmp_path := kv_path(kv, kv.gen, "idx.tmp", context.temp_allocator)
	ifd, oerr := prim.open_file(kv.vfs, tmp_path, {.Write, .Create, .Truncate, .Group_Visible}, 0o600)
	if oerr != .None {
		return false, from_prim(oerr)
	}
	saved := kv^
	kv.idx_fd = ifd
	kv.cap = capacity
	kv.used = 0
	kv.live = 0
	kv.live_bytes = 0
	ok := false
	defer if !ok {
		kv_unmap(kv)
		prim.close_file(kv.vfs, ifd)
		prim.remove(kv.vfs, tmp_path)
		kv.idx_fd = saved.idx_fd
		kv.cap = saved.cap
		kv.used = saved.used
		kv.live = saved.live
		kv.live_bytes = saved.live_bytes
		kv.covered = saved.covered
	}
	kv_zero(kv, ifd, i64(KV_HEADER + capacity * KV_SLOT)) or_return
	kv_map(kv)
	end := kv.log_end
	off := u64(KV_LOG_HEADER)
	good := off
	held := make([dynamic]Kv_Rec, context.temp_allocator)
	win := make([dynamic]u8, context.temp_allocator)
	win_off := off
	win_len := u64(0)
	rot: Kv_Rot
	scan: for off < end {
		if off + 8 > win_off + win_len || off + 8 + u64(prim.get_u32le(win[off - win_off:][:4])) > win_off + win_len {
			want := min(u64(1 << 20), end - off)
			if off + 8 <= win_off + win_len {
				n := u64(prim.get_u32le(win[off - win_off:][:4]))
				if n > KV_MAX_RECORD || 8 + n > end - off {
					off = kv_rot_skip(kv, &rot, off, end) or_return
					if off == 0 {
						break scan
					}
					continue scan
				}
				want = min(max(want, 8 + n), end - off)
			}
			resize(&win, int(want))
			got, rerr := prim.read_at(kv.vfs, kv.log_fd, win[:want], i64(off))
			if rerr != .None {
				return false, from_prim(rerr)
			}
			win_off = off
			win_len = u64(got)
			if win_len < 8 {
				break scan
			}
			n := u64(prim.get_u32le(win[0:4]))
			if n > KV_MAX_RECORD || 8 + n > end - off {
				off = kv_rot_skip(kv, &rot, off, end) or_return
				if off == 0 {
					break scan
				}
				continue scan
			}
			if 8 + n > win_len {
				if want == min(u64(1 << 20), end - off) && 8 + n > want {
					continue scan
				}
				break scan
			}
		}
		rec := win[off - win_off:]
		n := u64(prim.get_u32le(rec[0:4]))
		body := rec[8:][:n]
		r: Kv_Rec
		derr: Error
		if n > 0 && u32(xxhash.XXH3_64_with_seed(body, off)) == prim.get_u32le(rec[4:8]) {
			r, derr = kv_decode(body)
		} else {
			derr = .Corrupt
		}
		if derr != .None {
			off = kv_rot_skip(kv, &rot, off, end) or_return
			if off == 0 {
				break scan
			}
			continue scan
		}
		r.off = off
		r.size = 8 + n
		off += r.size
		if !kv.marked {
			kv_apply(kv, r) or_return
			good = off
		} else if r.commit {
			for x in held {
				kv_apply(kv, x) or_return
			}
			clear(&held)
			good = off
		} else {
			x := r
			x.key = make([]u8, len(r.key), context.temp_allocator)
			copy(x.key, r.key)
			x.value = nil
			append(&held, x)
		}
		if kv.used * 8 > kv.cap * 7 {
			return true, .None
		}
	}
	if good < end {
		from_prim(prim.truncate(kv.vfs, kv.log_fd, i64(good))) or_return
		from_prim(prim.datasync(kv.vfs, kv.log_fd)) or_return
		kv.log_end = good
	}
	kv_unmap(kv)
	from_prim(prim.datasync(kv.vfs, ifd)) or_return
	kv.covered = kv.log_end
	kv_write_header(kv, false)
	from_prim(prim.rename(kv.vfs, tmp_path, idx_path)) or_return
	kv.clean_disk = false
	ok = true
	if saved.idx_fd >= 0 {
		prim.close_file(kv.vfs, saved.idx_fd)
	}
	return false, .None
}

@(private = "file")
Kv_Rot :: struct {
	scanned:     bool,
	last:        u64,
	before_last: u64,
}

@(private = "file")
kv_valid_at :: proc(kv: ^Kv, off, end: u64, buf: ^[dynamic]u8) -> (size: u64, commit: bool, err: Error) {
	if off + 8 > end {
		return 0, false, .None
	}
	head: [8]u8
	got, rerr := prim.read_at(kv.vfs, kv.log_fd, head[:], i64(off))
	if rerr != .None {
		return 0, false, from_prim(rerr)
	}
	n := u64(prim.get_u32le(head[0:4]))
	if got != 8 || n == 0 || n > KV_MAX_RECORD || 8 + n > end - off {
		return 0, false, .None
	}
	if resize(buf, int(n)) != nil {
		return 0, false, .No_Memory
	}
	got, rerr = prim.read_at(kv.vfs, kv.log_fd, buf[:], i64(off) + 8)
	if rerr != .None {
		return 0, false, from_prim(rerr)
	}
	if u64(got) != n || u32(xxhash.XXH3_64_with_seed(buf[:], off)) != prim.get_u32le(head[4:8]) {
		return 0, false, .None
	}
	r, derr := kv_decode(buf[:])
	if derr != .None {
		return 0, false, .None
	}
	return 8 + n, r.commit, .None
}

@(private = "file")
kv_commits_after :: proc(kv: ^Kv, from, end: u64, rot: ^Kv_Rot) -> Error {
	rot.scanned = true
	buf := make([]u8, 1 << 16, context.temp_allocator)
	pos := from
	for pos + 9 <= end {
		got, rerr := prim.read_at(kv.vfs, kv.log_fd, buf[:min(u64(len(buf)), end - pos)], i64(pos))
		if rerr != .None {
			return from_prim(rerr)
		}
		if got < 9 {
			break
		}
		for k in 0 ..= got - 9 {
			if buf[k] != 1 || buf[k + 8] != 3 || prim.get_u32le(buf[k:k + 4]) != 1 {
				continue
			}
			at := pos + u64(k)
			if u32(xxhash.XXH3_64_with_seed(buf[k + 8:k + 9], at)) == prim.get_u32le(buf[k + 4:k + 8]) {
				rot.before_last = rot.last
				rot.last = at
			}
		}
		pos += u64(got - 8)
	}
	return .None
}

@(private = "file")
kv_next_commit :: proc(kv: ^Kv, from, end: u64) -> (at: u64, err: Error) {
	buf := make([]u8, 1 << 16, context.temp_allocator)
	pos := from
	for pos + 9 <= end {
		got, rerr := prim.read_at(kv.vfs, kv.log_fd, buf[:min(u64(len(buf)), end - pos)], i64(pos))
		if rerr != .None {
			return 0, from_prim(rerr)
		}
		if got < 9 {
			break
		}
		for k in 0 ..= got - 9 {
			if buf[k] != 1 || buf[k + 8] != 3 || prim.get_u32le(buf[k:k + 4]) != 1 {
				continue
			}
			c := pos + u64(k)
			if u32(xxhash.XXH3_64_with_seed(buf[k + 8:k + 9], c)) == prim.get_u32le(buf[k + 4:k + 8]) {
				return c, .None
			}
		}
		pos += u64(got - 8)
	}
	return 0, .None
}

@(private = "file")
kv_rot_skip :: proc(kv: ^Kv, rot: ^Kv_Rot, off, end: u64) -> (next: u64, err: Error) {
	if !kv.marked {
		return 0, .None
	}
	if !rot.scanned {
		kv_commits_after(kv, off, end, rot) or_return
	}
	if rot.last <= off {
		return 0, .None
	}
	buf := make([dynamic]u8, context.temp_allocator)
	if size, _ := kv_valid_at(kv, off + 9, end, &buf) or_return; size > 0 {
		return off + 9, .None
	}
	if rot.before_last <= off {
		return 0, .None
	}
	head: [4]u8
	got, rerr := prim.read_at(kv.vfs, kv.log_fd, head[:], i64(off))
	if rerr != .None {
		return 0, from_prim(rerr)
	}
	n := u64(prim.get_u32le(head[:]))
	if got == 4 && n <= KV_MAX_RECORD && 8 + n < end - off {
		if size, _ := kv_valid_at(kv, off + 8 + n, end, &buf) or_return; size > 0 {
			return off + 8 + n, .None
		}
	}
	return kv_next_commit(kv, off + 1, end)
}

@(private = "file")
kv_map :: proc(kv: ^Kv) {
	if kv.mapped != nil || kv.idx_fd < 0 || kv.vfs.procs != prim.os_vfs().procs {
		return
	}
	size := KV_HEADER + kv.cap * KV_SLOT
	if kv.map_lock != nil {
		sync.mutex_lock(kv.map_lock)
	}
	p, merr := prim.map_file(kv.idx_fd, int(size), true)
	if merr != .None {
		if kv.map_lock != nil {
			sync.mutex_unlock(kv.map_lock)
		}
		return
	}
	kv.mapped = p
}

@(private = "file")
kv_unmap :: proc(kv: ^Kv) {
	if kv.mapped == nil {
		return
	}
	prim.unmap_file(kv.mapped)
	kv.mapped = nil
	if kv.map_lock != nil {
		sync.mutex_unlock(kv.map_lock)
	}
}
