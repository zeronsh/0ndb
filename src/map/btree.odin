package omap

import "base:runtime"
import "core:hash/xxhash"
import "../obj"
import "../prim"

PAGE :: 4096
ROOTS :: 8
MAX_KEY :: 256
MAX_VALUE :: 16 * 1024 * 1024
INLINE_LIMIT :: 1024
CACHE_PAGES :: 32
COMPACT_SLACK :: 1024

@(private)
DB_MAGIC :: 0x6565_7274_6264_6e30
@(private)
DB_VERSION :: 1
@(private)
TEMP :: u64(1) << 63
@(private)
NODE_HEADER :: 16
@(private)
OVF_DATA :: PAGE - NODE_HEADER
@(private)
KIND_LEAF :: 1
@(private)
KIND_BRANCH :: 2
@(private)
KIND_OVF :: 3
@(private)
META_LEN :: 176
@(private)
WRITE_CHUNK :: 64

Meta :: struct {
	txn:    u64,
	pages:  u64,
	live:   u64,
	roots:  [ROOTS]u64,
	counts: [ROOTS]u64,
}

Db :: struct {
	vfs:       prim.Vfs,
	fd:        prim.Fd,
	path:      string,
	meta:      Meta,
	cache_no:  [CACHE_PAGES]u64,
	cache:     []u8,
	txn:       ^Txn,
	poisoned:  bool,
	allocator: runtime.Allocator,
	tag_of:    proc(data: rawptr) -> u64,
	tag_data:  rawptr,
	pend:      [2]Pend_Meta,
	npend:     int,
	publishing: bool,
}

Pend_Meta :: struct {
	meta: Meta,
	tag:  u64,
}

Txn :: struct {
	db:    ^Db,
	arena: obj.Arena,
	alloc: runtime.Allocator,
	meta:  Meta,
	dirty: [dynamic]^Node,
	clean: map[u64]^Node,
	freed: u64,
}

@(private)
Val :: struct {
	data: []u8,
	ovf:  u64,
	size: u64,
}

@(private)
Node :: struct {
	leaf: bool,
	ref:  u64,
	page: u64,
	keys: [dynamic][]u8,
	vals: [dynamic]Val,
	kids: [dynamic]u64,
}

Visit :: #type proc(data: rawptr, key: []u8, value: []u8) -> bool

db_open :: proc(db: ^Db, vfs: prim.Vfs, path: string, allocator := context.allocator) -> Error {
	tag_of, tag_data := db.tag_of, db.tag_data
	defer if db.tag_of == nil {
		db.tag_of, db.tag_data = tag_of, tag_data
	}
	db^ = {
		vfs       = vfs,
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	_compact_recover(vfs, path) or_return
	fd, oerr := prim.open_file(vfs, path, {.Write})
	if oerr == .None {
		size, serr := prim.file_size(vfs, fd)
		if serr != .None {
			prim.close_file(vfs, fd)
			return obj.perr(serr)
		}
		if size == 0 {
			prim.close_file(vfs, fd)
			oerr = .Not_Found
		}
	}
	if oerr == .Not_Found {
		_db_init(vfs, path) or_return
		fd, oerr = prim.open_file(vfs, path, {.Write})
	}
	if oerr != .None {
		return obj.perr(oerr)
	}
	db.fd = fd
	p, perr := make([]u8, len(path), allocator)
	if perr != nil {
		db_close(db)
		return .No_Memory
	}
	copy(p, path)
	db.path = string(p)
	cache, cerr := make([]u8, CACHE_PAGES * PAGE, allocator)
	if cerr != nil {
		db_close(db)
		return .No_Memory
	}
	db.cache = cache
	if err := _db_load(db); err != .None {
		db_close(db)
		return err
	}
	return .None
}

db_close :: proc(db: ^Db) {
	if db.txn != nil {
		txn_abort(db.txn)
	}
	if db.fd >= 0 {
		if !db.poisoned {
			prim.datasync(db.vfs, db.fd)
		}
		prim.close_file(db.vfs, db.fd)
	}
	delete(db.cache, db.allocator)
	delete(db.path, db.allocator)
	db^ = {
		fd = prim.INVALID_FD,
	}
}

db_count :: proc "contextless" (db: ^Db, root: int) -> u64 {
	return db.meta.counts[root]
}

db_get :: proc(db: ^Db, root: int, key: []u8, allocator := context.allocator) -> (value: []u8, found: bool, err: Error) {
	if db.poisoned {
		return nil, false, .Io
	}
	if db.txn != nil {
		return txn_get(db.txn, root, key, allocator)
	}
	ref := db.meta.roots[root]
	for ref != 0 {
		n := _node_read(db, ref, context.temp_allocator) or_return
		if n.leaf {
			i, hit := _search(n.keys[:], key)
			if !hit {
				return nil, false, .None
			}
			v := _val_bytes(db, n.vals[i], allocator) or_return
			return v, true, .None
		}
		ref = n.kids[_child_index(n.keys[:], key)]
	}
	return nil, false, .None
}

db_scan :: proc(db: ^Db, root: int, start: []u8, prefix: []u8, data: rawptr, visit: Visit) -> Error {
	if db.poisoned {
		return .Io
	}
	ref := db.meta.roots[root]
	if db.txn != nil {
		ref = db.txn.meta.roots[root]
	}
	if ref == 0 {
		return .None
	}
	Frame :: struct {
		n: ^Node,
		i: int,
	}
	stack: [32]Frame
	depth := 0
	from := start
	if _less(from, prefix) {
		from = prefix
	}
	n := _node_get(db, ref, context.temp_allocator) or_return
	for !n.leaf {
		i := _child_index(n.keys[:], from)
		if depth == len(stack) {
			return .Corrupt
		}
		stack[depth] = {n, i}
		depth += 1
		n = _node_get(db, n.kids[i], context.temp_allocator) or_return
	}
	i, _ := _search(n.keys[:], from)
	for {
		for ; i < len(n.keys); i += 1 {
			k := n.keys[i]
			if len(k) < len(prefix) || string(k[:len(prefix)]) != string(prefix) {
				return .None
			}
			v := _val_bytes(db, n.vals[i], context.temp_allocator) or_return
			if !visit(data, k, v) {
				return .None
			}
		}
		for depth > 0 && stack[depth - 1].i + 1 >= len(stack[depth - 1].n.kids) {
			depth -= 1
		}
		if depth == 0 {
			return .None
		}
		stack[depth - 1].i += 1
		f := stack[depth - 1]
		n = _node_get(db, f.n.kids[f.i], context.temp_allocator) or_return
		for !n.leaf {
			if depth == len(stack) {
				return .Corrupt
			}
			stack[depth] = {n, 0}
			depth += 1
			n = _node_get(db, n.kids[0], context.temp_allocator) or_return
		}
		i = 0
	}
}

txn_begin :: proc(db: ^Db) -> (t: ^Txn, err: Error) {
	if db.txn != nil {
		return nil, .Busy
	}
	if db.poisoned {
		return nil, .Io
	}
	t = new(Txn, db.allocator)
	if t == nil {
		return nil, .No_Memory
	}
	if obj.arena_init(&t.arena) != nil {
		free(t, db.allocator)
		return nil, .No_Memory
	}
	t.db = db
	t.alloc = obj.arena_allocator(&t.arena)
	t.meta = db.meta
	t.dirty = make([dynamic]^Node, t.alloc)
	t.clean = make(map[u64]^Node, t.alloc)
	db.txn = t
	return t, .None
}

txn_abort :: proc(t: ^Txn) {
	db := t.db
	obj.arena_destroy(&t.arena)
	db.txn = nil
	free(t, db.allocator)
}

txn_dirty :: proc "contextless" (t: ^Txn) -> int {
	return len(t.dirty)
}

txn_bytes :: proc "contextless" (t: ^Txn) -> int {
	return int(obj.arena_used(&t.arena))
}

txn_get :: proc(t: ^Txn, root: int, key: []u8, allocator := context.allocator) -> (value: []u8, found: bool, err: Error) {
	ref := t.meta.roots[root]
	for ref != 0 {
		n := _txn_node(t, ref) or_return
		if n.leaf {
			i, hit := _search(n.keys[:], key)
			if !hit {
				return nil, false, .None
			}
			v := _val_bytes(t.db, n.vals[i], allocator) or_return
			return v, true, .None
		}
		ref = n.kids[_child_index(n.keys[:], key)]
	}
	return nil, false, .None
}

txn_put :: proc(t: ^Txn, root: int, key: []u8, value: []u8) -> Error {
	if len(key) == 0 || len(key) > MAX_KEY {
		return .Invalid
	}
	if len(value) > MAX_VALUE {
		return .Too_Large
	}
	k := _dup(t, key) or_return
	v := _dup(t, value) or_return
	ref := t.meta.roots[root]
	if ref == 0 {
		n := _new_node(t, true) or_return
		append(&n.keys, k)
		append(&n.vals, Val{data = v, size = u64(len(v))})
		t.meta.roots[root] = n.ref
		t.meta.counts[root] = 1
		return .None
	}
	added := false
	nref, sep, right := _insert(t, ref, k, v, &added) or_return
	if right != 0 {
		top := _new_node(t, false) or_return
		append(&top.kids, nref, right)
		append(&top.keys, sep)
		nref = top.ref
	}
	t.meta.roots[root] = nref
	if added {
		t.meta.counts[root] += 1
	}
	return .None
}

txn_delete :: proc(t: ^Txn, root: int, key: []u8) -> (found: bool, err: Error) {
	ref := t.meta.roots[root]
	if ref == 0 {
		return false, .None
	}
	nref := _remove(t, ref, key, &found) or_return
	if !found {
		return false, .None
	}
	for nref != 0 {
		n := _txn_node(t, nref) or_return
		if n.leaf || len(n.kids) != 1 {
			break
		}
		nref = n.kids[0]
		if n.ref & TEMP == 0 {
			t.freed += 1
		}
	}
	t.meta.roots[root] = nref
	t.meta.counts[root] -= 1
	return true, .None
}

txn_commit :: proc(t: ^Txn) -> Error {
	db := t.db
	if len(t.dirty) == 0 && t.meta == db.meta {
		txn_abort(t)
		return .None
	}
	start := db.meta.pages
	next := start
	for r in 0 ..< ROOTS {
		ref := t.meta.roots[r]
		if ref & TEMP != 0 {
			t.meta.roots[r] = _assign(t, ref, &next)
		}
	}
	written := next - start
	if written > 0 {
		buf, aerr := make([]u8, int(written) * PAGE, t.alloc)
		if aerr != nil {
			txn_abort(t)
			return .No_Memory
		}
		for n in t.dirty {
			if n.page == 0 {
				continue
			}
			_encode_node(t, n, buf, start)
		}
		if err := prim.write_at(db.vfs, db.fd, buf, i64(start) * PAGE); err != .None {
			txn_abort(t)
			db.poisoned = true
			return obj.perr(err)
		}
		if err := prim.barrier(db.vfs, db.fd); err != .None {
			txn_abort(t)
			db.poisoned = true
			return obj.perr(err)
		}
	}
	m := t.meta
	m.txn = db.meta.txn + 1
	m.pages = next
	m.live = db.meta.live + written - min(t.freed, db.meta.live + written)
	if db.tag_of != nil {
		_pend_add(db, m, db.tag_of(db.tag_data))
		db.meta = m
		txn_abort(t)
		return .None
	}
	if err := _meta_write(db.vfs, db.fd, &m); err != .None {
		txn_abort(t)
		db.poisoned = true
		return err
	}
	db.meta = m
	txn_abort(t)
	if db.meta.pages > 2 * db.meta.live + 2 + COMPACT_SLACK {
		return db_compact(db)
	}
	return .None
}

@(private)
_pend_add :: proc(db: ^Db, m: Meta, tag: u64) {
	if db.npend > 0 && db.pend[db.npend - 1].tag == tag {
		db.pend[db.npend - 1].meta = m
		return
	}
	if db.npend < len(db.pend) {
		db.pend[db.npend] = Pend_Meta{meta = m, tag = tag}
		db.npend += 1
		return
	}
	db.pend[len(db.pend) - 1] = Pend_Meta{meta = m, tag = tag}
}

db_pending :: proc "contextless" (db: ^Db) -> bool {
	return db.npend > 0
}

db_publish :: proc(db: ^Db, durable: u64) -> Error {
	if db.publishing || db.npend == 0 || db.poisoned || db.fd < 0 {
		return .None
	}
	db.publishing = true
	defer db.publishing = false
	for {
		idx := -1
		for i in 0 ..< db.npend {
			if db.pend[i].tag <= durable {
				idx = i
			}
		}
		if idx < 0 {
			break
		}
		m := db.pend[idx].meta
		rest := db.npend - idx - 1
		for i in 0 ..< rest {
			db.pend[i] = db.pend[idx + 1 + i]
		}
		db.npend = rest
		if err := _meta_write(db.vfs, db.fd, &m); err != .None {
			db.poisoned = true
			return err
		}
		if err := prim.datasync(db.vfs, db.fd); err != .None {
			db.poisoned = true
			return obj.perr(err)
		}
	}
	if db.npend == 0 && db.meta.pages > 2 * db.meta.live + 2 + COMPACT_SLACK {
		db.publishing = false
		return db_compact(db)
	}
	return .None
}

db_sync :: proc(db: ^Db) -> Error {
	return obj.perr(prim.datasync(db.vfs, db.fd))
}

db_compact :: proc(db: ^Db) -> Error {
	if db.txn != nil || db.npend > 0 {
		return .Busy
	}
	if db.poisoned {
		return .Io
	}
	buf: prim.Path_Buf
	if len(db.path) + 8 >= len(buf) {
		return .Invalid
	}
	n := copy(buf[:], db.path)
	n += copy(buf[n:], ".compact")
	tmp := string(buf[:n])
	fd, oerr := prim.open_file(db.vfs, tmp, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return obj.perr(oerr)
	}
	ok := false
	defer if !ok {
		prim.close_file(db.vfs, fd)
		prim.remove(db.vfs, tmp)
	}
	c := Copier{
		db   = db,
		fd   = fd,
		next = 2,
	}
	if obj.arena_init(&c.arena) != nil {
		return .No_Memory
	}
	defer obj.arena_destroy(&c.arena)
	c.buf = make([dynamic]u8, 0, WRITE_CHUNK * PAGE, obj.arena_allocator(&c.arena))
	m := db.meta
	for r in 0 ..< ROOTS {
		if m.roots[r] != 0 {
			m.roots[r] = _copy_tree(&c, m.roots[r]) or_return
		}
	}
	_copier_flush(&c) or_return
	m.txn += 1
	m.pages = c.next
	m.live = c.next - 2
	_meta_write_slot(db.vfs, fd, &m, 0) or_return
	_meta_write_slot(db.vfs, fd, &m, 1) or_return
	if err := prim.datasync(db.vfs, fd); err != .None {
		return obj.perr(err)
	}
	ok = true
	if err := _zero_file(db.vfs, db.fd); err != .None {
		db.poisoned = true
		return err
	}
	prim.close_file(db.vfs, db.fd)
	db.fd = fd
	if err := prim.rename(db.vfs, tmp, db.path); err != .None {
		db.poisoned = true
		return obj.perr(err)
	}
	db.meta = m
	db.cache_no = {}
	if err := prim.sync_dir(db.vfs, prim.dir_name(db.path)); err != .None {
		db.poisoned = true
		return obj.perr(err)
	}
	return .None
}

@(private)
Copier :: struct {
	db:    ^Db,
	fd:    prim.Fd,
	next:  u64,
	at:    u64,
	buf:   [dynamic]u8,
	arena: obj.Arena,
}

@(private)
_copier_page :: proc(c: ^Copier) -> (page: u64, data: []u8, err: Error) {
	if len(c.buf) == WRITE_CHUNK * PAGE {
		_copier_flush(c) or_return
	}
	if len(c.buf) == 0 {
		c.at = c.next
	}
	n := len(c.buf)
	if e := resize(&c.buf, n + PAGE); e != nil {
		return 0, nil, .No_Memory
	}
	page = c.next
	c.next += 1
	data = c.buf[n:][:PAGE]
	for &b in data {
		b = 0
	}
	return page, data, .None
}

@(private)
_copier_flush :: proc(c: ^Copier) -> Error {
	if len(c.buf) == 0 {
		return .None
	}
	if err := prim.write_at(c.db.vfs, c.fd, c.buf[:], i64(c.at) * PAGE); err != .None {
		return obj.perr(err)
	}
	clear(&c.buf)
	return .None
}

@(private)
_copy_tree :: proc(c: ^Copier, ref: u64) -> (page: u64, err: Error) {
	mark := obj.arena_temp_begin(&c.arena)
	defer obj.arena_temp_end(mark)
	alloc := obj.arena_allocator(&c.arena)
	n := _node_read(c.db, ref, alloc) or_return
	if n.leaf {
		for &v in n.vals {
			if v.ovf == 0 {
				continue
			}
			first: u64
			pages := _ovf_pages(v.size)
			for k in 0 ..< pages {
				src := _read_page(c.db, v.ovf + k) or_return
				p, dst := _copier_page(c) or_return
				if k == 0 {
					first = p
				}
				copy(dst[8:], src[8:])
				prim.put_u64le(dst[0:8], xxhash.XXH3_64_with_seed(dst[8:], p))
			}
			v.ovf = first
		}
	} else {
		for &k in n.kids {
			k = _copy_tree(c, k) or_return
		}
	}
	p, dst := _copier_page(c) or_return
	_encode_into(n, dst, p, alloc)
	return p, .None
}

@(private)
_ovf_pages :: proc "contextless" (size: u64) -> u64 {
	return (size + OVF_DATA - 1) / OVF_DATA
}

@(private)
_db_load :: proc(db: ^Db) -> Error {
	size, serr := prim.file_size(db.vfs, db.fd)
	if serr != .None {
		return obj.perr(serr)
	}
	best: Meta
	found := false
	for slot in 0 ..< 2 {
		m, ok := _meta_read(db.vfs, db.fd, slot)
		if !ok || m.pages < 2 || i64(m.pages) * PAGE > size {
			continue
		}
		if !found || m.txn > best.txn {
			best = m
			found = true
		}
	}
	if !found {
		return .Corrupt
	}
	db.meta = best
	if i64(best.pages) * PAGE < size {
		if err := prim.truncate(db.vfs, db.fd, i64(best.pages) * PAGE); err != .None {
			return obj.perr(err)
		}
	}
	return .None
}

@(private)
_meta_encode :: proc(b: []u8, m: ^Meta) {
	prim.put_u64le(b[0:8], DB_MAGIC)
	prim.put_u32le(b[8:12], DB_VERSION)
	prim.put_u64le(b[16:24], m.txn)
	prim.put_u64le(b[24:32], m.pages)
	prim.put_u64le(b[32:40], m.live)
	for i in 0 ..< ROOTS {
		prim.put_u64le(b[40 + 8 * i:], m.roots[i])
		prim.put_u64le(b[104 + 8 * i:], m.counts[i])
	}
	prim.put_u64le(b[168:176], xxhash.XXH3_64_with_seed(b[0:168], DB_MAGIC))
}

@(private)
_meta_write :: proc(vfs: prim.Vfs, fd: prim.Fd, m: ^Meta) -> Error {
	return _meta_write_slot(vfs, fd, m, int(m.txn & 1))
}

@(private)
_meta_write_slot :: proc(vfs: prim.Vfs, fd: prim.Fd, m: ^Meta, slot: int) -> Error {
	b: [PAGE]u8
	_meta_encode(b[:], m)
	return obj.perr(prim.write_at(vfs, fd, b[:], i64(slot) * PAGE))
}

@(private)
_meta_read :: proc(vfs: prim.Vfs, fd: prim.Fd, slot: int) -> (m: Meta, ok: bool) {
	b: [META_LEN]u8
	n, err := prim.read_at(vfs, fd, b[:], i64(slot) * PAGE)
	if err != .None || n != META_LEN {
		return
	}
	if prim.get_u64le(b[0:8]) != DB_MAGIC || prim.get_u32le(b[8:12]) != DB_VERSION {
		return
	}
	if xxhash.XXH3_64_with_seed(b[0:168], DB_MAGIC) != prim.get_u64le(b[168:176]) {
		return
	}
	m.txn = prim.get_u64le(b[16:24])
	m.pages = prim.get_u64le(b[24:32])
	m.live = prim.get_u64le(b[32:40])
	for i in 0 ..< ROOTS {
		m.roots[i] = prim.get_u64le(b[40 + 8 * i:])
		m.counts[i] = prim.get_u64le(b[104 + 8 * i:])
		if m.roots[i] != 0 && (m.roots[i] < 2 || m.roots[i] >= m.pages) {
			return m, false
		}
	}
	return m, true
}

@(private)
_read_page :: proc(db: ^Db, no: u64) -> (page: []u8, err: Error) {
	if no < 2 || no >= db.meta.pages {
		return nil, .Corrupt
	}
	slot := int(no % CACHE_PAGES)
	buf := db.cache[slot * PAGE:][:PAGE]
	if db.cache_no[slot] == no + 1 {
		return buf, .None
	}
	db.cache_no[slot] = 0
	n, rerr := prim.read_at(db.vfs, db.fd, buf, i64(no) * PAGE)
	if rerr != .None {
		return nil, obj.perr(rerr)
	}
	if n != PAGE || xxhash.XXH3_64_with_seed(buf[8:], no) != prim.get_u64le(buf[0:8]) {
		return nil, .Corrupt
	}
	db.cache_no[slot] = no + 1
	return buf, .None
}

@(private)
_node_get :: proc(db: ^Db, ref: u64, allocator: runtime.Allocator) -> (n: ^Node, err: Error) {
	if db.txn != nil {
		return _txn_node(db.txn, ref)
	}
	return _node_read(db, ref, allocator)
}

@(private)
_txn_node :: proc(t: ^Txn, ref: u64) -> (n: ^Node, err: Error) {
	if ref & TEMP != 0 {
		i := int(ref & ~TEMP)
		if i >= len(t.dirty) {
			return nil, .Corrupt
		}
		return t.dirty[i], .None
	}
	if c, ok := t.clean[ref]; ok {
		return c, .None
	}
	n = _node_read(t.db, ref, t.alloc) or_return
	t.clean[ref] = n
	return n, .None
}

@(private)
_node_read :: proc(db: ^Db, ref: u64, allocator: runtime.Allocator) -> (n: ^Node, err: Error) {
	if ref & TEMP != 0 {
		return nil, .Corrupt
	}
	page := _read_page(db, ref) or_return
	n = new(Node, allocator)
	if n == nil {
		return nil, .No_Memory
	}
	n.ref = ref
	n.page = ref
	count := int(page[10]) | int(page[11]) << 8
	n.keys = make([dynamic][]u8, 0, count, allocator)
	r := prim.reader(page[NODE_HEADER:])
	switch page[8] {
	case KIND_LEAF:
		n.leaf = true
		n.vals = make([dynamic]Val, 0, count, allocator)
		for _ in 0 ..< count {
			k := prim.read_bytes(&r)
			v: Val
			switch prim.read_u8(&r) {
			case 0:
				b := prim.read_bytes(&r)
				v.data = make([]u8, len(b), allocator)
				copy(v.data, b)
				v.size = u64(len(b))
			case 1:
				v.ovf = prim.read_u64le(&r)
				v.size = prim.read_uvarint(&r)
				if v.size == 0 || v.size > MAX_VALUE || v.ovf < 2 || v.ovf + _ovf_pages(v.size) > db.meta.pages {
					return nil, .Corrupt
				}
			case:
				return nil, .Corrupt
			}
			kc := make([]u8, len(k), allocator)
			copy(kc, k)
			append(&n.keys, kc)
			append(&n.vals, v)
		}
	case KIND_BRANCH:
		n.kids = make([dynamic]u64, 0, count + 1, allocator)
		append(&n.kids, prim.read_u64le(&r))
		for _ in 0 ..< count {
			k := prim.read_bytes(&r)
			kc := make([]u8, len(k), allocator)
			copy(kc, k)
			append(&n.keys, kc)
			append(&n.kids, prim.read_u64le(&r))
		}
		for k in n.kids {
			if k < 2 || k >= ref {
				return nil, .Corrupt
			}
		}
	case:
		return nil, .Corrupt
	}
	if r.err != .None {
		return nil, .Corrupt
	}
	return n, .None
}

@(private)
_val_bytes :: proc(db: ^Db, v: Val, allocator: runtime.Allocator) -> (out: []u8, err: Error) {
	if v.ovf == 0 {
		return v.data, .None
	}
	buf, aerr := make([]u8, int(v.size), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	pos := 0
	for k in 0 ..< _ovf_pages(v.size) {
		page := _read_page(db, v.ovf + k) or_return
		if page[8] != KIND_OVF {
			return nil, .Corrupt
		}
		pos += copy(buf[pos:], page[NODE_HEADER:])
	}
	return buf, .None
}

@(private)
_less :: proc "contextless" (a, b: []u8) -> bool {
	return string(a) < string(b)
}

@(private)
_search :: proc "contextless" (keys: [][]u8, key: []u8) -> (int, bool) {
	lo, hi := 0, len(keys)
	for lo < hi {
		mid := (lo + hi) / 2
		if string(keys[mid]) < string(key) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(keys) && string(keys[lo]) == string(key)
}

@(private)
_child_index :: proc "contextless" (keys: [][]u8, key: []u8) -> int {
	lo, hi := 0, len(keys)
	for lo < hi {
		mid := (lo + hi) / 2
		if string(keys[mid]) <= string(key) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
_dup :: proc(t: ^Txn, b: []u8) -> ([]u8, Error) {
	out, err := make([]u8, len(b), t.alloc)
	if err != nil {
		return nil, .No_Memory
	}
	copy(out, b)
	return out, .None
}

@(private)
_new_node :: proc(t: ^Txn, leaf: bool) -> (n: ^Node, err: Error) {
	n = new(Node, t.alloc)
	if n == nil {
		return nil, .No_Memory
	}
	n.leaf = leaf
	n.keys = make([dynamic][]u8, t.alloc)
	if leaf {
		n.vals = make([dynamic]Val, t.alloc)
	} else {
		n.kids = make([dynamic]u64, t.alloc)
	}
	n.ref = TEMP | u64(len(t.dirty))
	append(&t.dirty, n)
	return n, .None
}

@(private)
_mutable :: proc(t: ^Txn, ref: u64) -> (n: ^Node, err: Error) {
	src := _txn_node(t, ref) or_return
	if src.ref & TEMP != 0 {
		return src, .None
	}
	n = _new_node(t, src.leaf) or_return
	append(&n.keys, ..src.keys[:])
	if src.leaf {
		append(&n.vals, ..src.vals[:])
	} else {
		append(&n.kids, ..src.kids[:])
	}
	t.freed += 1
	return n, .None
}

@(private)
_free_val :: proc(t: ^Txn, v: Val) {
	if v.ovf != 0 {
		t.freed += _ovf_pages(v.size)
	}
}

@(private)
_val_cost :: proc "contextless" (v: Val) -> int {
	if v.ovf != 0 || v.size > INLINE_LIMIT {
		return 1 + 8 + prim.uvarint_len(v.size)
	}
	return 1 + prim.uvarint_len(v.size) + int(v.size)
}

@(private)
_size :: proc(n: ^Node) -> int {
	s := NODE_HEADER
	if n.leaf {
		for k, i in n.keys {
			s += prim.uvarint_len(u64(len(k))) + len(k) + _val_cost(n.vals[i])
		}
	} else {
		s += 8
		for k in n.keys {
			s += prim.uvarint_len(u64(len(k))) + len(k) + 8
		}
	}
	return s
}

@(private)
_insert :: proc(t: ^Txn, ref: u64, key: []u8, value: []u8, added: ^bool) -> (nref: u64, sep: []u8, right: u64, err: Error) {
	n := _mutable(t, ref) or_return
	if n.leaf {
		i, hit := _search(n.keys[:], key)
		v := Val{
			data = value,
			size = u64(len(value)),
		}
		if hit {
			_free_val(t, n.vals[i])
			n.vals[i] = v
		} else {
			inject_at(&n.keys, i, key)
			inject_at(&n.vals, i, v)
			added^ = true
		}
	} else {
		i := _child_index(n.keys[:], key)
		c, s, r := _insert(t, n.kids[i], key, value, added) or_return
		n.kids[i] = c
		if r != 0 {
			inject_at(&n.keys, i, s)
			inject_at(&n.kids, i + 1, r)
		}
	}
	if _size(n) <= PAGE {
		return n.ref, nil, 0, .None
	}
	rn := _new_node(t, n.leaf) or_return
	half := _size(n) / 2
	acc := NODE_HEADER
	m := 0
	if n.leaf {
		for m < len(n.keys) - 1 {
			acc += prim.uvarint_len(u64(len(n.keys[m]))) + len(n.keys[m]) + _val_cost(n.vals[m])
			m += 1
			if acc >= half {
				break
			}
		}
		append(&rn.keys, ..n.keys[m:])
		append(&rn.vals, ..n.vals[m:])
		resize(&n.keys, m)
		resize(&n.vals, m)
		sep = rn.keys[0]
	} else {
		for m < len(n.keys) - 2 {
			acc += prim.uvarint_len(u64(len(n.keys[m]))) + len(n.keys[m]) + 8
			m += 1
			if acc >= half {
				break
			}
		}
		m = max(m, 1)
		sep = n.keys[m]
		append(&rn.keys, ..n.keys[m + 1:])
		append(&rn.kids, ..n.kids[m + 1:])
		resize(&n.keys, m)
		resize(&n.kids, m + 1)
	}
	return n.ref, sep, rn.ref, .None
}

@(private)
_remove :: proc(t: ^Txn, ref: u64, key: []u8, found: ^bool) -> (nref: u64, err: Error) {
	cur := _txn_node(t, ref) or_return
	if cur.leaf {
		i, hit := _search(cur.keys[:], key)
		if !hit {
			return ref, .None
		}
		found^ = true
		n := _mutable(t, ref) or_return
		_free_val(t, n.vals[i])
		ordered_remove(&n.keys, i)
		ordered_remove(&n.vals, i)
		if len(n.keys) == 0 {
			return 0, .None
		}
		return n.ref, .None
	}
	i := _child_index(cur.keys[:], key)
	c := _remove(t, cur.kids[i], key, found) or_return
	if !found^ {
		return ref, .None
	}
	n := _mutable(t, ref) or_return
	if c == 0 {
		ordered_remove(&n.kids, i)
		if len(n.keys) > 0 {
			ordered_remove(&n.keys, max(i - 1, 0))
		}
		if len(n.kids) == 0 {
			return 0, .None
		}
		return n.ref, .None
	}
	n.kids[i] = c
	child := _txn_node(t, c) or_return
	if _size(child) < PAGE / 4 && len(n.kids) > 1 {
		j := i + 1 if i + 1 < len(n.kids) else i - 1
		a, b := min(i, j), max(i, j)
		left := _mutable(t, n.kids[a]) or_return
		rnode := _txn_node(t, n.kids[b]) or_return
		extra := _size(rnode) - NODE_HEADER
		if !left.leaf {
			extra += prim.uvarint_len(u64(len(n.keys[a]))) + len(n.keys[a])
		}
		if _size(left) + extra <= PAGE {
			if left.leaf {
				append(&left.keys, ..rnode.keys[:])
				append(&left.vals, ..rnode.vals[:])
			} else {
				append(&left.keys, n.keys[a])
				append(&left.keys, ..rnode.keys[:])
				append(&left.kids, ..rnode.kids[:])
			}
			if rnode.ref & TEMP == 0 {
				t.freed += 1
			}
			n.kids[a] = left.ref
			ordered_remove(&n.kids, b)
			ordered_remove(&n.keys, a)
		} else {
			n.kids[a] = left.ref
		}
	}
	return n.ref, .None
}

@(private)
_assign :: proc(t: ^Txn, ref: u64, next: ^u64) -> u64 {
	if ref & TEMP == 0 {
		return ref
	}
	n := t.dirty[int(ref & ~TEMP)]
	if n.page != 0 {
		return n.page
	}
	if n.leaf {
		for &v in n.vals {
			if v.ovf == 0 && v.size > INLINE_LIMIT {
				v.ovf = next^
				next^ += _ovf_pages(v.size)
			}
		}
	} else {
		for &k in n.kids {
			k = _assign(t, k, next)
		}
	}
	n.page = next^
	next^ += 1
	return n.page
}

@(private)
_encode_node :: proc(t: ^Txn, n: ^Node, buf: []u8, start: u64) {
	if n.leaf {
		for v in n.vals {
			if v.ovf < start || v.data == nil || v.size <= INLINE_LIMIT {
				continue
			}
			pos := 0
			for k in 0 ..< _ovf_pages(v.size) {
				no := v.ovf + k
				dst := buf[(no - start) * PAGE:][:PAGE]
				for &b in dst {
					b = 0
				}
				dst[8] = KIND_OVF
				pos += copy(dst[NODE_HEADER:], v.data[pos:])
				prim.put_u64le(dst[0:8], xxhash.XXH3_64_with_seed(dst[8:], no))
			}
		}
	}
	_encode_into(n, buf[(n.page - start) * PAGE:][:PAGE], n.page, t.alloc)
}

@(private)
_encode_into :: proc(n: ^Node, dst: []u8, no: u64, scratch: runtime.Allocator) {
	for &b in dst {
		b = 0
	}
	body := make([dynamic]u8, 0, PAGE, scratch)
	w := prim.writer(&body)
	if n.leaf {
		dst[8] = KIND_LEAF
		prim.put_u32le(dst[12:16], 0)
		for k, i in n.keys {
			prim.write_bytes(&w, k)
			v := n.vals[i]
			if v.ovf != 0 {
				prim.write_u8(&w, 1)
				prim.write_u64le(&w, v.ovf)
				prim.write_uvarint(&w, v.size)
			} else {
				prim.write_u8(&w, 0)
				prim.write_bytes(&w, v.data)
			}
		}
	} else {
		dst[8] = KIND_BRANCH
		prim.write_u64le(&w, n.kids[0])
		for k, i in n.keys {
			prim.write_bytes(&w, k)
			prim.write_u64le(&w, n.kids[i + 1])
		}
	}
	dst[10] = u8(len(n.keys))
	dst[11] = u8(len(n.keys) >> 8)
	copy(dst[NODE_HEADER:], body[:])
	prim.put_u64le(dst[0:8], xxhash.XXH3_64_with_seed(dst[8:], no))
}

Builder :: struct {
	db:    ^Db,
	c:     Copier,
	tmp:   prim.Path_Buf,
	tlen:  int,
	meta:  Meta,
	trees: [ROOTS]Build_Tree,
	open:  bool,
}

@(private)
Build_Tree :: struct {
	levels: [dynamic]^Build_Level,
	last:      [dynamic]u8,
	count:     u64,
	active:    bool,
	allocator: runtime.Allocator,
}

@(private)
Build_Level :: struct {
	arena:   obj.Arena,
	node:    Node,
	first:   []u8,
	size:    int,
	flushed: int,
}

builder_begin :: proc(b: ^Builder, db: ^Db) -> Error {
	if db.txn != nil {
		return .Busy
	}
	if db.poisoned {
		return .Io
	}
	b^ = {}
	b.db = db
	if len(db.path) + 6 >= len(b.tmp) {
		return .Invalid
	}
	b.tlen = copy(b.tmp[:], db.path)
	b.tlen += copy(b.tmp[b.tlen:], ".build")
	fd, oerr := prim.open_file(db.vfs, string(b.tmp[:b.tlen]), {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return obj.perr(oerr)
	}
	b.c = Copier{
		db   = db,
		fd   = fd,
		next = 2,
	}
	if obj.arena_init(&b.c.arena) != nil {
		prim.close_file(db.vfs, fd)
		prim.remove(db.vfs, string(b.tmp[:b.tlen]))
		return .No_Memory
	}
	b.c.buf = make([dynamic]u8, 0, WRITE_CHUNK * PAGE, obj.arena_allocator(&b.c.arena))
	b.meta = Meta{
		txn = db.meta.txn,
	}
	b.open = true
	return .None
}

builder_abort :: proc(b: ^Builder) {
	if !b.open {
		return
	}
	_builder_free(b)
	prim.close_file(b.db.vfs, b.c.fd)
	prim.remove(b.db.vfs, string(b.tmp[:b.tlen]))
	b.open = false
}

builder_add :: proc(b: ^Builder, root: int, key: []u8, value: []u8) -> Error {
	if root < 0 || root >= ROOTS || b.meta.roots[root] != 0 {
		return .Invalid
	}
	if len(key) == 0 || len(key) > MAX_KEY {
		return .Invalid
	}
	if len(value) > MAX_VALUE {
		return .Too_Large
	}
	t := &b.trees[root]
	if t.active && string(key) <= string(t.last[:]) {
		return .Invalid
	}
	if !t.active {
		t.levels = make([dynamic]^Build_Level, b.db.allocator)
		t.last = make([dynamic]u8, b.db.allocator)
		t.allocator = b.db.allocator
		t.active = true
	}
	clear(&t.last)
	append(&t.last, ..key)
	t.count += 1
	if len(t.levels) == 0 {
		_level_push(b, t) or_return
	}
	l := t.levels[0]
	v := Val{
		size = u64(len(value)),
	}
	cost := prim.uvarint_len(u64(len(key))) + len(key) + _val_cost(v)
	if len(l.node.keys) > 0 && l.size + cost > PAGE {
		_level_flush(b, t, 0) or_return
	}
	a := obj.arena_allocator(&l.arena)
	if v.size > INLINE_LIMIT {
		v.ovf = b.c.next
		pos := 0
		for _ in 0 ..< _ovf_pages(v.size) {
			p, dst := _copier_page(&b.c) or_return
			dst[8] = KIND_OVF
			pos += copy(dst[NODE_HEADER:], value[pos:])
			prim.put_u64le(dst[0:8], xxhash.XXH3_64_with_seed(dst[8:], p))
		}
	} else {
		d, e := make([]u8, len(value), a)
		if e != nil {
			return .No_Memory
		}
		copy(d, value)
		v.data = d
	}
	k, ke := make([]u8, len(key), a)
	if ke != nil {
		return .No_Memory
	}
	copy(k, key)
	if len(l.node.keys) == 0 {
		l.first = k
	}
	append(&l.node.keys, k)
	append(&l.node.vals, v)
	l.size += cost
	return .None
}

builder_end :: proc(b: ^Builder, root: int) -> Error {
	if root < 0 || root >= ROOTS || b.meta.roots[root] != 0 {
		return .Invalid
	}
	t := &b.trees[root]
	if !t.active {
		return .None
	}
	for i := 0; i < len(t.levels); i += 1 {
		l := t.levels[i]
		if i == len(t.levels) - 1 && l.flushed == 0 {
			if !l.node.leaf && len(l.node.kids) == 1 {
				b.meta.roots[root] = l.node.kids[0]
				break
			}
			p, dst := _copier_page(&b.c) or_return
			_encode_into(&l.node, dst, p, obj.arena_allocator(&l.arena))
			b.meta.roots[root] = p
			break
		}
		_level_flush(b, t, i) or_return
	}
	b.meta.counts[root] = t.count
	_tree_free(t)
	return .None
}

builder_commit :: proc(b: ^Builder) -> Error {
	if !b.open {
		return .Invalid
	}
	for r in 0 ..< ROOTS {
		if b.trees[r].active {
			builder_end(b, r) or_return
		}
	}
	_copier_flush(&b.c) or_return
	m := b.meta
	m.txn += 1
	m.pages = b.c.next
	m.live = b.c.next - 2
	db := b.db
	fd := b.c.fd
	_meta_write_slot(db.vfs, fd, &m, 0) or_return
	_meta_write_slot(db.vfs, fd, &m, 1) or_return
	if err := prim.datasync(db.vfs, fd); err != .None {
		return obj.perr(err)
	}
	if err := prim.rename(db.vfs, string(b.tmp[:b.tlen]), db.path); err != .None {
		return obj.perr(err)
	}
	_builder_free(b)
	b.open = false
	prim.close_file(db.vfs, db.fd)
	db.fd = fd
	db.meta = m
	db.cache_no = {}
	if err := prim.sync_dir(db.vfs, prim.dir_name(db.path)); err != .None {
		db.poisoned = true
		return obj.perr(err)
	}
	return .None
}

@(private)
_builder_free :: proc(b: ^Builder) {
	for &t in b.trees {
		_tree_free(&t)
	}
	obj.arena_destroy(&b.c.arena)
}

@(private)
_tree_free :: proc(t: ^Build_Tree) {
	if !t.active {
		return
	}
	for l in t.levels {
		obj.arena_destroy(&l.arena)
		free(l, t.allocator)
	}
	delete(t.levels)
	delete(t.last)
	t^ = {}
}

@(private)
_level_push :: proc(b: ^Builder, t: ^Build_Tree) -> Error {
	l := new(Build_Level, t.allocator)
	if l == nil {
		return .No_Memory
	}
	if obj.arena_init(&l.arena) != nil {
		free(l, t.allocator)
		return .No_Memory
	}
	_level_reset(l, len(t.levels) == 0)
	if _, e := append(&t.levels, l); e != nil {
		obj.arena_destroy(&l.arena)
		free(l, t.allocator)
		return .No_Memory
	}
	return .None
}

@(private)
_level_reset :: proc(l: ^Build_Level, leaf: bool) {
	obj.arena_free_all(&l.arena)
	a := obj.arena_allocator(&l.arena)
	l.node = Node{
		leaf = leaf,
		keys = make([dynamic][]u8, a),
	}
	if leaf {
		l.node.vals = make([dynamic]Val, a)
		l.size = NODE_HEADER
	} else {
		l.node.kids = make([dynamic]u64, a)
		l.size = NODE_HEADER + 8
	}
	l.first = nil
}

@(private)
_level_flush :: proc(b: ^Builder, t: ^Build_Tree, i: int) -> Error {
	l := t.levels[i]
	p, dst := _copier_page(&b.c) or_return
	_encode_into(&l.node, dst, p, obj.arena_allocator(&l.arena))
	if i + 1 == len(t.levels) {
		_level_push(b, t) or_return
	}
	_level_add_kid(b, t, i + 1, l.first, p) or_return
	l.flushed += 1
	_level_reset(l, i == 0)
	return .None
}

@(private)
_level_add_kid :: proc(b: ^Builder, t: ^Build_Tree, i: int, first: []u8, page: u64) -> Error {
	l := t.levels[i]
	cost := prim.uvarint_len(u64(len(first))) + len(first) + 8
	if len(l.node.kids) > 0 && l.size + cost > PAGE {
		_level_flush(b, t, i) or_return
	}
	a := obj.arena_allocator(&l.arena)
	k, e := make([]u8, len(first), a)
	if e != nil {
		return .No_Memory
	}
	copy(k, first)
	if len(l.node.kids) == 0 {
		l.first = k
		append(&l.node.kids, page)
		return .None
	}
	append(&l.node.keys, k)
	append(&l.node.kids, page)
	l.size += cost
	return .None
}

db_poisoned :: proc "contextless" (db: ^Db) -> bool {
	return db.poisoned
}

@(private)
_db_init :: proc(vfs: prim.Vfs, path: string) -> Error {
	buf: prim.Path_Buf
	if len(path) + 5 >= len(buf) {
		return .Invalid
	}
	n := copy(buf[:], path)
	n += copy(buf[n:], ".init")
	tmp := string(buf[:n])
	fd, oerr := prim.open_file(vfs, tmp, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return obj.perr(oerr)
	}
	m := Meta{
		pages = 2,
	}
	err := _meta_write_slot(vfs, fd, &m, 0)
	if err == .None {
		m.txn = 1
		err = _meta_write_slot(vfs, fd, &m, 1)
	}
	if err == .None {
		err = obj.perr(prim.datasync(vfs, fd))
	}
	prim.close_file(vfs, fd)
	if err == .None {
		err = obj.perr(prim.rename(vfs, tmp, path))
	}
	if err != .None {
		prim.remove(vfs, tmp)
		return err
	}
	return obj.perr(prim.sync_dir(vfs, prim.dir_name(path)))
}

@(private)
_zero_file :: proc(vfs: prim.Vfs, fd: prim.Fd) -> Error {
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		return obj.perr(serr)
	}
	zeros := make([]u8, WRITE_CHUNK * PAGE, context.temp_allocator)
	head := min(size, 2 * PAGE)
	if head > 0 {
		obj.perr(prim.write_at(vfs, fd, zeros[:head], 0)) or_return
		obj.perr(prim.datasync(vfs, fd)) or_return
	}
	for off := head; off < size; {
		n := min(size - off, i64(len(zeros)))
		obj.perr(prim.write_at(vfs, fd, zeros[:n], off)) or_return
		off += n
	}
	return obj.perr(prim.datasync(vfs, fd))
}

@(private)
_file_valid :: proc(vfs: prim.Vfs, path: string) -> bool {
	fd, oerr := prim.open_file(vfs, path, {})
	if oerr != .None {
		return false
	}
	defer prim.close_file(vfs, fd)
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		return false
	}
	for slot in 0 ..< 2 {
		if m, ok := _meta_read(vfs, fd, slot); ok && m.pages >= 2 && i64(m.pages) * PAGE <= size {
			return true
		}
	}
	return false
}

@(private)
_compact_recover :: proc(vfs: prim.Vfs, path: string) -> Error {
	buf: prim.Path_Buf
	if len(path) + 8 >= len(buf) {
		return .None
	}
	n := copy(buf[:], path)
	n += copy(buf[n:], ".compact")
	tmp := string(buf[:n])
	if !prim.exists(vfs, tmp) {
		return .None
	}
	if !_file_valid(vfs, path) && _file_valid(vfs, tmp) {
		obj.perr(prim.rename(vfs, tmp, path)) or_return
		return obj.perr(prim.sync_dir(vfs, prim.dir_name(path)))
	}
	fd, oerr := prim.open_file(vfs, tmp, {.Write})
	if oerr == .None {
		zerr := _zero_file(vfs, fd)
		prim.close_file(vfs, fd)
		zerr or_return
	}
	if err := prim.remove(vfs, tmp); err != .None && err != .Not_Found {
		return obj.perr(err)
	}
	return .None
}
