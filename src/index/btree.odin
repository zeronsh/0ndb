package index

import "base:runtime"
import "core:hash/xxhash"
import "core:mem/virtual"
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
	fd:        prim.Fd,
	path:      string,
	meta:      Meta,
	cache_no:  [CACHE_PAGES]u64,
	cache:     []u8,
	txn:       ^Txn,
	allocator: runtime.Allocator,
}

Txn :: struct {
	db:    ^Db,
	arena: virtual.Arena,
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

db_open :: proc(db: ^Db, path: string, allocator := context.allocator) -> Error {
	db^ = {
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	fd, oerr := prim.open_file(path, {.Write, .Create}, 0o600)
	if oerr != .None {
		return _perr(oerr)
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
		prim.datasync(db.fd)
		prim.close(db.fd)
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
	t = new(Txn, db.allocator)
	if t == nil {
		return nil, .No_Memory
	}
	if virtual.arena_init_growing(&t.arena) != nil {
		free(t, db.allocator)
		return nil, .No_Memory
	}
	t.db = db
	t.alloc = virtual.arena_allocator(&t.arena)
	t.meta = db.meta
	t.dirty = make([dynamic]^Node, t.alloc)
	t.clean = make(map[u64]^Node, t.alloc)
	db.txn = t
	return t, .None
}

txn_abort :: proc(t: ^Txn) {
	db := t.db
	virtual.arena_destroy(&t.arena)
	db.txn = nil
	free(t, db.allocator)
}

txn_dirty :: proc "contextless" (t: ^Txn) -> int {
	return len(t.dirty)
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
		if err := prim.write_at(db.fd, buf, i64(start) * PAGE); err != .None {
			txn_abort(t)
			return _perr(err)
		}
		if err := prim.datasync(db.fd); err != .None {
			txn_abort(t)
			return _perr(err)
		}
	}
	m := t.meta
	m.txn = db.meta.txn + 1
	m.pages = next
	m.live = db.meta.live + written - min(t.freed, db.meta.live + written)
	if err := _meta_write(db.fd, &m); err != .None {
		txn_abort(t)
		return err
	}
	db.meta = m
	txn_abort(t)
	if db.meta.pages > 2 * db.meta.live + 2 + COMPACT_SLACK {
		return db_compact(db)
	}
	return .None
}

db_sync :: proc(db: ^Db) -> Error {
	return _perr(prim.datasync(db.fd))
}

db_compact :: proc(db: ^Db) -> Error {
	if db.txn != nil {
		return .Busy
	}
	buf: prim.Path_Buf
	if len(db.path) + 8 >= len(buf) {
		return .Invalid
	}
	n := copy(buf[:], db.path)
	n += copy(buf[n:], ".compact")
	tmp := string(buf[:n])
	fd, oerr := prim.open_file(tmp, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	ok := false
	defer if !ok {
		prim.close(fd)
		prim.remove(tmp)
	}
	c := Copier{
		db   = db,
		fd   = fd,
		next = 2,
	}
	if virtual.arena_init_growing(&c.arena) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&c.arena)
	c.buf = make([dynamic]u8, 0, WRITE_CHUNK * PAGE, virtual.arena_allocator(&c.arena))
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
	_meta_write_slot(fd, &m, 0) or_return
	_meta_write_slot(fd, &m, 1) or_return
	if err := prim.datasync(fd); err != .None {
		return _perr(err)
	}
	if err := prim.rename(tmp, db.path); err != .None {
		return _perr(err)
	}
	ok = true
	prim.close(db.fd)
	db.fd = fd
	db.meta = m
	db.cache_no = {}
	return _perr(prim.sync_dir(prim.dir_name(db.path)))
}

@(private)
Copier :: struct {
	db:    ^Db,
	fd:    prim.Fd,
	next:  u64,
	at:    u64,
	buf:   [dynamic]u8,
	arena: virtual.Arena,
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
	if err := prim.write_at(c.fd, c.buf[:], i64(c.at) * PAGE); err != .None {
		return _perr(err)
	}
	clear(&c.buf)
	return .None
}

@(private)
_copy_tree :: proc(c: ^Copier, ref: u64) -> (page: u64, err: Error) {
	mark := virtual.arena_temp_begin(&c.arena)
	defer virtual.arena_temp_end(mark)
	alloc := virtual.arena_allocator(&c.arena)
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
	size, serr := prim.file_size(db.fd)
	if serr != .None {
		return _perr(serr)
	}
	if size == 0 {
		m := Meta{
			pages = 2,
		}
		_meta_write_slot(db.fd, &m, 0) or_return
		m.txn = 1
		_meta_write_slot(db.fd, &m, 1) or_return
		if err := prim.datasync(db.fd); err != .None {
			return _perr(err)
		}
		db.meta = m
		return _perr(prim.sync_dir(prim.dir_name(db.path)))
	}
	best: Meta
	found := false
	for slot in 0 ..< 2 {
		m, ok := _meta_read(db.fd, slot)
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
		if err := prim.truncate(db.fd, i64(best.pages) * PAGE); err != .None {
			return _perr(err)
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
_meta_write :: proc(fd: prim.Fd, m: ^Meta) -> Error {
	return _meta_write_slot(fd, m, int(m.txn & 1))
}

@(private)
_meta_write_slot :: proc(fd: prim.Fd, m: ^Meta, slot: int) -> Error {
	b: [PAGE]u8
	_meta_encode(b[:], m)
	return _perr(prim.write_at(fd, b[:], i64(slot) * PAGE))
}

@(private)
_meta_read :: proc(fd: prim.Fd, slot: int) -> (m: Meta, ok: bool) {
	b: [META_LEN]u8
	n, err := prim.read_at(fd, b[:], i64(slot) * PAGE)
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
	n, rerr := prim.read_at(db.fd, buf, i64(no) * PAGE)
	if rerr != .None {
		return nil, _perr(rerr)
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
