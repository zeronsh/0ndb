package fs

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:strings"
import "core:sync"
import "core:thread"
import "../odb"
import "../prim"

Index_Flag :: enum u8 {
	Assume_Valid,
	Skip_Worktree,
	Intent_To_Add,
	Sparse_Dir,
}

Index_Flags :: bit_set[Index_Flag;u8]

Index_Entry :: struct {
	path:     string,
	ctime_s:  u32,
	ctime_ns: u32,
	mtime_s:  u32,
	mtime_ns: u32,
	dev:      u32,
	ino:      u32,
	mode:     u32,
	uid:      u32,
	gid:      u32,
	size:     u32,
	oid:      odb.Oid,
	stage:    u8,
	flags:    Index_Flags,
}

Index_Reader :: struct {
	allocator:  runtime.Allocator,
	vfs:        prim.Vfs,
	format:     odb.Hash_Format,
	version:    u32,
	count:      int,
	mtime_ns:   i64,
	main:       Index_Cursor,
	adds:       Index_Cursor,
	shared:     Index_Cursor,
	split:      bool,
	single:     bool,
	eoie_start: i64,
	link:       []u8,
	del_bits:   Index_Ewah,
	rep_bits:   Index_Ewah,
	next_del:   int,
	next_rep:   int,
	base_pos:   int,
	base_count: int,
	a:          Index_Entry,
	b:          Index_Entry,
	have_a:     bool,
	have_b:     bool,
	done:       bool,
	err:        Error,
}

Cache_Tree_Node :: struct {
	oid:     odb.Oid,
	entries: int,
}

Cache_Tree :: struct {
	nodes:     map[string]Cache_Tree_Node,
	allocator: runtime.Allocator,
}

@(private = "file")
INDEX_WINDOW :: 1024 * 1024

@(private = "file")
INDEX_HEADER :: 12

@(private = "file")
INDEX_SIGNATURE :: 0x44495243

@(private = "file")
INDEX_MODE_DIR :: 0o040000

@(private = "file")
INDEX_NO_BIT :: max(int)

@(private = "file")
INDEX_THREAD_MIN :: 4 * 1024 * 1024

@(private = "file")
Index_Ident :: struct {
	size:     i64,
	mtime_ns: i64,
	ino:      u64,
	dev:      u64,
}

@(private = "file")
Index_Hash_Job :: struct {
	vfs:    prim.Vfs,
	file:   string,
	ident:  Index_Ident,
	limit:  i64,
	format: odb.Hash_Format,
	buf:    []u8,
	stop:   bool,
	sum:    odb.Oid,
	err:    Error,
	worker: ^thread.Thread,
}

@(private = "file")
Index_Cursor :: struct {
	vfs:         prim.Vfs,
	file:        string,
	ident:       Index_Ident,
	buf:         []u8,
	base:        i64,
	pos:         int,
	len:         int,
	limit:       i64,
	hashing:     bool,
	hashed:      i64,
	hasher:      odb.Hasher,
	job:         ^Index_Hash_Job,
	format:      odb.Hash_Format,
	trailer:     odb.Oid,
	skip_hash:   bool,
	version:     u32,
	hs:          int,
	count:       int,
	remaining:   int,
	path:        [dynamic]u8,
	plen:        int,
	stage:       u8,
	check_order: bool,
	started:     bool,
	allocator:   runtime.Allocator,
}

@(private = "file")
Index_Ewah :: struct {
	words:    []u8,
	nwords:   int,
	ptr:      int,
	pos:      int,
	ones:     int,
	lit_left: int,
	cur:      u64,
	cur_base: int,
}

@(private = "file")
Index_Scan :: struct {
	lead_empty: int,
	late_empty: bool,
	adds_off:   i64,
	has_link:   bool,
	link:       []u8,
}

index_open :: proc(r: ^Index_Reader, vfs: prim.Vfs, git_dir: string, format: odb.Hash_Format, allocator := context.allocator) -> Error {
	r^ = {}
	r.allocator = allocator
	r.vfs = vfs
	r.format = format
	err := idx_open(r, git_dir, format, allocator)
	if err != .None {
		index_close(r)
	}
	return err
}

index_close :: proc(r: ^Index_Reader) {
	idx_cursor_close(&r.adds)
	idx_cursor_close(&r.shared)
	idx_cursor_close(&r.main)
	if r.link != nil {
		delete(r.link, r.allocator)
	}
	r^ = {}
}

index_version :: proc(r: ^Index_Reader) -> u32 {
	return r.version
}

index_count :: proc(r: ^Index_Reader) -> int {
	return r.count
}

index_file_mtime_ns :: proc(r: ^Index_Reader) -> i64 {
	return r.mtime_ns
}

index_next :: proc(r: ^Index_Reader) -> (e: Index_Entry, ok: bool, err: Error) {
	if r.err != .None {
		return {}, false, r.err
	}
	if r.done {
		return {}, false, .None
	}
	if r.split {
		e, ok, err = idx_next_split(r)
	} else if r.main.remaining == 0 {
		err = idx_finish_main(r)
	} else {
		err = idx_read_entry(&r.main, &e)
		if err == .None {
			err = idx_check_entry(&e)
		}
		ok = err == .None
	}
	if err != .None {
		r.err = err
		return {}, false, err
	}
	if !ok {
		r.done = true
	}
	return
}

index_cache_tree :: proc(vfs: prim.Vfs, git_dir: string, format: odb.Hash_Format, allocator := context.allocator) -> (ct: Cache_Tree, err: Error) {
	ct.allocator = allocator
	ct.nodes = make(map[string]Cache_Tree_Node, allocator)
	c: Index_Cursor
	c.vfs = vfs
	err = idx_cache_tree(&c, &ct, git_dir, format, allocator)
	idx_cursor_close(&c)
	if err != .None {
		cache_tree_destroy(&ct)
		return {}, err
	}
	return
}

cache_tree_lookup :: proc(ct: ^Cache_Tree, dir: string) -> (oid: odb.Oid, entries: int, ok: bool) {
	node, found := ct.nodes[dir]
	if !found {
		return
	}
	return node.oid, node.entries, true
}

cache_tree_destroy :: proc(ct: ^Cache_Tree) {
	for key in ct.nodes {
		delete(key, ct.allocator)
	}
	delete(ct.nodes)
	ct^ = {}
}

@(private = "file")
idx_open :: proc(r: ^Index_Reader, git_dir: string, format: odb.Hash_Format, allocator: runtime.Allocator) -> Error {
	pbuf: [prim.PATH_MAX]u8
	path, pok := path_join_buf(pbuf[:], git_dir, "index")
	if !pok {
		return .Name_Too_Long
	}
	r.main.vfs = r.vfs
	idx_cursor_open(&r.main, path, format, allocator) or_return
	r.version = r.main.version
	r.mtime_ns = r.main.ident.mtime_ns
	start, has_link, found := idx_eoie(&r.main)
	if (found && !has_link) || (!found && !idx_has_shared(r.vfs, git_dir, allocator)) {
		r.eoie_start = start
		r.single = true
		idx_start(&r.main, true) or_return
		r.main.check_order = true
		r.count = r.main.count
		return .None
	}
	scan: Index_Scan
	idx_start(&r.main, true) or_return
	err := idx_scan(&r.main, &scan, nil)
	r.link = scan.link
	if err != .None {
		return err
	}
	base: odb.Oid
	hs := r.main.hs
	if scan.has_link {
		if len(r.link) < hs {
			return .Corrupt
		}
		copy(base[:hs], r.link[:hs])
	}
	if base == {} {
		idx_start(&r.main, false) or_return
		r.main.check_order = true
		r.count = r.main.count
		return .None
	}
	return idx_open_split(r, git_dir, base, scan, allocator)
}

@(private = "file")
idx_open_split :: proc(r: ^Index_Reader, git_dir: string, base: odb.Oid, scan: Index_Scan, allocator: runtime.Allocator) -> Error {
	hs := r.main.hs
	rest := r.link[hs:]
	if len(rest) > 0 {
		used: int
		ok: bool
		r.del_bits, used, ok = idx_ewah_parse(rest)
		if !ok {
			return .Corrupt
		}
		rest = rest[used:]
		r.rep_bits, used, ok = idx_ewah_parse(rest)
		if !ok || used != len(rest) {
			return .Corrupt
		}
	}
	hex: [odb.MAX_HEX]u8
	name_buf: [len("sharedindex.") + odb.MAX_HEX]u8
	name_len := copy(name_buf[:], "sharedindex.")
	name_len += copy(name_buf[name_len:], odb.oid_to_string(base, r.format, &hex))
	pbuf: [prim.PATH_MAX]u8
	path, pok := path_join_buf(pbuf[:], git_dir, string(name_buf[:name_len]))
	if !pok {
		return .Name_Too_Long
	}
	r.shared.vfs = r.vfs
	if err := idx_cursor_open(&r.shared, path, r.format, allocator); err != .None {
		return .Corrupt if err == .Not_Found else err
	}
	if r.shared.trailer != base {
		return .Corrupt
	}
	idx_start(&r.shared, true) or_return
	r.shared.check_order = true
	r.base_count = r.shared.count
	deleted := idx_ewah_count(r.del_bits, r.base_count) or_return
	replaced := idx_ewah_count(r.rep_bits, r.base_count) or_return
	if scan.lead_empty != replaced || scan.late_empty {
		return .Corrupt
	}
	idx_start(&r.main, false) or_return
	r.main.remaining = replaced
	idx_cursor_share(&r.adds, &r.main) or_return
	idx_seek(&r.adds, scan.adds_off)
	r.adds.remaining = r.main.count - replaced
	r.adds.check_order = true
	r.count = r.base_count - deleted + r.adds.remaining
	r.next_del = idx_ewah_next(&r.del_bits, r.base_count) or_return
	r.next_rep = idx_ewah_next(&r.rep_bits, r.base_count) or_return
	r.split = true
	return .None
}

@(private = "file")
idx_cache_tree :: proc(c: ^Index_Cursor, ct: ^Cache_Tree, git_dir: string, format: odb.Hash_Format, allocator: runtime.Allocator) -> Error {
	pbuf: [prim.PATH_MAX]u8
	path, pok := path_join_buf(pbuf[:], git_dir, "index")
	if !pok {
		return .Name_Too_Long
	}
	idx_cursor_open(c, path, format, allocator) or_return
	idx_start(c, true) or_return
	scan: Index_Scan
	err := idx_scan(c, &scan, ct)
	if scan.link != nil {
		delete(scan.link, allocator)
	}
	return err
}

@(private = "file")
idx_next_split :: proc(r: ^Index_Reader) -> (e: Index_Entry, ok: bool, err: Error) {
	for {
		if !r.have_b {
			r.have_b = idx_next_base(r, &r.b) or_return
		}
		if !r.have_a && r.adds.remaining > 0 {
			idx_read_entry(&r.adds, &r.a) or_return
			idx_check_entry(&r.a) or_return
			r.have_a = true
		}
		switch {
		case r.have_a && r.have_b:
			if r.a.path == r.b.path && (r.a.stage == 0 || r.a.stage == r.b.stage) {
				r.have_b = false
				continue
			}
			if idx_entry_less(&r.b, &r.a) {
				r.have_b = false
				return r.b, true, .None
			}
			r.have_a = false
			return r.a, true, .None
		case r.have_b:
			r.have_b = false
			return r.b, true, .None
		case r.have_a:
			r.have_a = false
			return r.a, true, .None
		}
		break
	}
	if r.main.remaining != 0 || r.adds.remaining != 0 || r.next_rep != INDEX_NO_BIT || r.next_del != INDEX_NO_BIT {
		return {}, false, .Corrupt
	}
	idx_extensions(&r.shared, nil, nil) or_return
	idx_hash_finish(&r.shared) or_return
	return {}, false, .None
}

@(private = "file")
idx_next_base :: proc(r: ^Index_Reader, e: ^Index_Entry) -> (ok: bool, err: Error) {
	for r.base_pos < r.base_count {
		idx_read_entry(&r.shared, e) or_return
		pos := r.base_pos
		r.base_pos += 1
		if pos == r.next_rep {
			if r.main.remaining == 0 {
				return false, .Corrupt
			}
			rep: Index_Entry
			idx_read_entry(&r.main, &rep) or_return
			if len(rep.path) != 0 {
				return false, .Corrupt
			}
			rep.path = e.path
			e^ = rep
			r.next_rep = idx_ewah_next(&r.rep_bits, r.base_count) or_return
		}
		if pos == r.next_del {
			r.next_del = idx_ewah_next(&r.del_bits, r.base_count) or_return
			continue
		}
		idx_check_entry(e) or_return
		return true, .None
	}
	return false, .None
}

@(private = "file")
idx_entry_less :: proc(a, b: ^Index_Entry) -> bool {
	c := bytes.compare(transmute([]u8)a.path, transmute([]u8)b.path)
	return c < 0 || (c == 0 && a.stage < b.stage)
}

@(private = "file")
idx_check_entry :: proc(e: ^Index_Entry) -> Error {
	n := len(e.path)
	if n == 0 || e.path[0] == '/' {
		return .Corrupt
	}
	dir := e.path[n - 1] == '/'
	if dir != (e.mode == INDEX_MODE_DIR) {
		return .Corrupt
	}
	if dir {
		if n == 1 {
			return .Corrupt
		}
		e.flags += {.Sparse_Dir}
	}
	return .None
}

@(private = "file")
idx_finish_main :: proc(r: ^Index_Reader) -> Error {
	if !r.single {
		return .None
	}
	if r.eoie_start != 0 && idx_off(&r.main) != r.eoie_start {
		return .Corrupt
	}
	s: Index_Scan
	err := idx_extensions(&r.main, &s, nil)
	if s.has_link {
		if len(s.link) < r.main.hs {
			err = .Corrupt
		} else {
			for b in s.link[:r.main.hs] {
				if b != 0 {
					err = .Corrupt
				}
			}
		}
		delete(s.link, r.allocator)
	}
	if err != .None {
		return err
	}
	return idx_hash_finish(&r.main)
}

@(private = "file")
idx_has_shared :: proc(vfs: prim.Vfs, git_dir: string, allocator: runtime.Allocator) -> bool {
	d: prim.Dir
	if prim.dir_open(vfs, &d, git_dir, allocator) != .None {
		return true
	}
	defer prim.dir_close(vfs, &d)
	prefix :: "sharedindex."
	for {
		ent, ok, err := prim.dir_next(vfs, &d)
		if err != .None {
			return true
		}
		if !ok {
			return false
		}
		if len(ent.name) > len(prefix) && ent.name[:len(prefix)] == prefix {
			return true
		}
	}
}

@(private = "file")
idx_pread :: proc(vfs: prim.Vfs, file: string, id: Index_Ident, dst: []u8, off: i64) -> (int, Error) {
	fd, oerr := prim.open_file(vfs, file)
	if oerr == .Not_Found {
		return 0, .Changed
	}
	if oerr != .None {
		return 0, from_prim(oerr)
	}
	defer prim.close_file(vfs, fd)
	st, serr := prim.fstat(vfs, fd)
	if serr != .None {
		return 0, from_prim(serr)
	}
	if (Index_Ident{size = st.size, mtime_ns = st.mtime_ns, ino = st.ino, dev = st.dev}) != id {
		return 0, .Changed
	}
	n, rerr := prim.read_at(vfs, fd, dst, off)
	if rerr != .None {
		return 0, from_prim(rerr)
	}
	return n, .None
}

@(private = "file")
idx_cursor_open :: proc(c: ^Index_Cursor, path: string, format: odb.Hash_Format, allocator: runtime.Allocator) -> Error {
	vfs := c.vfs
	c^ = {}
	c.vfs = vfs
	c.allocator = allocator
	c.format = format
	c.hs = odb.oid_size(format)
	fd, oerr := prim.open_file(c.vfs, path)
	if oerr != .None {
		return from_prim(oerr)
	}
	st, serr := prim.fstat(c.vfs, fd)
	if serr != .None {
		prim.close_file(c.vfs, fd)
		return from_prim(serr)
	}
	c.ident = Index_Ident{size = st.size, mtime_ns = st.mtime_ns, ino = st.ino, dev = st.dev}
	hdr: [INDEX_HEADER]u8
	n, rerr := prim.read_at(c.vfs, fd, hdr[:], 0)
	if st.size >= i64(INDEX_HEADER + c.hs) && rerr == .None && n == INDEX_HEADER {
		n, rerr = prim.read_at(c.vfs, fd, c.trailer[:c.hs], st.size - i64(c.hs))
	}
	prim.close_file(c.vfs, fd)
	if st.size < i64(INDEX_HEADER + c.hs) {
		return .Corrupt
	}
	if rerr != .None {
		return from_prim(rerr)
	}
	if n != c.hs || endian.unchecked_get_u32be(hdr[0:]) != INDEX_SIGNATURE {
		return .Corrupt
	}
	file, ferr := strings.clone(path, allocator)
	if ferr != nil {
		return .No_Memory
	}
	c.file = file
	c.limit = st.size - i64(c.hs)
	c.version = endian.unchecked_get_u32be(hdr[4:])
	if c.version < 2 {
		return .Corrupt
	}
	if c.version > 4 {
		return .Unsupported
	}
	count := i64(endian.unchecked_get_u32be(hdr[8:]))
	if count * i64(42 + c.hs) > c.limit - INDEX_HEADER {
		return .Corrupt
	}
	c.count = int(count)
	c.skip_hash = c.trailer == {}
	return idx_cursor_alloc(c, c.limit)
}

@(private = "file")
idx_cursor_alloc :: proc(c: ^Index_Cursor, span: i64) -> Error {
	size := int(min(span, INDEX_WINDOW))
	buf, aerr := make([]u8, max(size, 64), c.allocator)
	if aerr != nil {
		return .No_Memory
	}
	c.buf = buf
	path, perr := make([dynamic]u8, 0, 256, c.allocator)
	if perr != nil {
		return .No_Memory
	}
	c.path = path
	return .None
}

@(private = "file")
idx_cursor_share :: proc(dst, src: ^Index_Cursor) -> Error {
	dst^ = {}
	dst.vfs = src.vfs
	file, ferr := strings.clone(src.file, src.allocator)
	if ferr != nil {
		return .No_Memory
	}
	dst.file = file
	dst.ident = src.ident
	dst.allocator = src.allocator
	dst.format = src.format
	dst.hs = src.hs
	dst.version = src.version
	dst.limit = src.limit
	dst.trailer = src.trailer
	dst.skip_hash = src.skip_hash
	dst.count = src.count
	return idx_cursor_alloc(dst, src.limit)
}

@(private = "file")
idx_cursor_close :: proc(c: ^Index_Cursor) {
	if c.job != nil {
		sync.atomic_store(&c.job.stop, true)
		idx_job_end(c)
	}
	if len(c.file) > 0 {
		delete(c.file, c.allocator)
	}
	if c.buf != nil {
		delete(c.buf, c.allocator)
	}
	if c.path != nil {
		delete(c.path)
	}
	c^ = {}
}

@(private = "file")
idx_seek :: proc(c: ^Index_Cursor, off: i64) {
	c.base = off
	c.pos = 0
	c.len = 0
	c.hashed = off
	clear(&c.path)
	c.plen = 0
	c.started = false
}

@(private = "file")
idx_start :: proc(c: ^Index_Cursor, hashing: bool) -> Error {
	idx_seek(c, 0)
	c.hashing = hashing && !c.skip_hash
	c.remaining = c.count
	if c.hashing && c.limit >= INDEX_THREAD_MIN && c.job == nil && c.vfs.procs == prim.os_vfs().procs {
		c.hashing = false
		idx_job_start(c) or_return
	}
	if c.hashing {
		odb.hasher_init(&c.hasher, c.format)
	}
	return idx_skip(c, INDEX_HEADER)
}

@(private = "file")
idx_job_start :: proc(c: ^Index_Cursor) -> Error {
	job, jerr := new(Index_Hash_Job, c.allocator)
	if jerr != nil {
		return .No_Memory
	}
	buf, berr := make([]u8, INDEX_WINDOW, c.allocator)
	if berr != nil {
		free(job, c.allocator)
		return .No_Memory
	}
	job.vfs = c.vfs
	job.file = c.file
	job.ident = c.ident
	job.limit = c.limit
	job.format = c.format
	job.buf = buf
	c.job = job
	context.allocator = c.allocator
	job.worker = thread.create_and_start_with_poly_data(job, idx_job_run)
	if job.worker == nil {
		idx_job_run(job)
	}
	return .None
}

@(private = "file")
idx_job_run :: proc(job: ^Index_Hash_Job) {
	h: odb.Hasher
	odb.hasher_init(&h, job.format)
	off: i64
	for off < job.limit {
		if sync.atomic_load(&job.stop) {
			job.err = .Stopped
			return
		}
		n := int(min(i64(len(job.buf)), job.limit - off))
		got, err := idx_pread(job.vfs, job.file, job.ident, job.buf[:n], off)
		if err != .None {
			job.err = err
			return
		}
		if got != n {
			job.err = .Corrupt
			return
		}
		odb.hasher_update(&h, job.buf[:n])
		off += i64(n)
	}
	job.sum, _ = odb.hasher_final(&h)
}

@(private = "file")
idx_job_end :: proc(c: ^Index_Cursor) -> (sum: odb.Oid, err: Error) {
	job := c.job
	c.job = nil
	if job.worker != nil {
		context.allocator = c.allocator
		thread.join(job.worker)
		thread.destroy(job.worker)
	}
	sum, err = job.sum, job.err
	delete(job.buf, c.allocator)
	free(job, c.allocator)
	return
}

@(private = "file")
idx_off :: #force_inline proc "contextless" (c: ^Index_Cursor) -> i64 {
	return c.base + i64(c.pos)
}

@(private = "file")
idx_hash_consumed :: proc(c: ^Index_Cursor) {
	if !c.hashing {
		return
	}
	start := int(c.hashed - c.base)
	if start < c.pos {
		odb.hasher_update(&c.hasher, c.buf[start:c.pos])
	}
	c.hashed = c.base + i64(c.pos)
}

@(private = "file")
idx_avail :: proc(c: ^Index_Cursor, n: int) -> (have: int, err: Error) {
	have = c.len - c.pos
	if have >= n {
		return
	}
	left := c.limit - idx_off(c)
	if i64(have) >= left {
		return
	}
	want := min(i64(n), left)
	idx_hash_consumed(c)
	if c.pos > 0 {
		copy(c.buf, c.buf[c.pos:c.len])
		c.base += i64(c.pos)
		c.len -= c.pos
		c.pos = 0
	}
	if want > i64(len(c.buf)) {
		grown := int(min(max(want, i64(len(c.buf)) * 2), left))
		buf, aerr := make([]u8, grown, c.allocator)
		if aerr != nil {
			return 0, .No_Memory
		}
		copy(buf, c.buf[:c.len])
		delete(c.buf, c.allocator)
		c.buf = buf
	}
	to_read := int(min(i64(len(c.buf) - c.len), c.limit - (c.base + i64(c.len))))
	got, rerr := idx_pread(c.vfs, c.file, c.ident, c.buf[c.len:c.len + to_read], c.base + i64(c.len))
	if rerr != .None {
		return 0, rerr
	}
	if got != to_read {
		return 0, .Corrupt
	}
	c.len += got
	return c.len - c.pos, .None
}

@(private = "file")
idx_need :: #force_inline proc(c: ^Index_Cursor, n: int) -> Error {
	if c.len - c.pos >= n {
		return .None
	}
	have := idx_avail(c, n) or_return
	return .Corrupt if have < n else .None
}

@(private = "file")
idx_skip :: proc(c: ^Index_Cursor, n: i64) -> Error {
	n := n
	if n > c.limit - idx_off(c) {
		return .Corrupt
	}
	for n > 0 {
		have := c.len - c.pos
		if have == 0 {
			if !c.hashing {
				idx_seek_raw(c, idx_off(c) + n)
				return .None
			}
			have = idx_avail(c, int(min(n, i64(len(c.buf))))) or_return
			if have == 0 {
				return .Corrupt
			}
		}
		k := int(min(i64(have), n))
		c.pos += k
		n -= i64(k)
	}
	return .None
}

@(private = "file")
idx_seek_raw :: proc(c: ^Index_Cursor, off: i64) {
	c.base = off
	c.pos = 0
	c.len = 0
	c.hashed = off
}

@(private = "file")
idx_read_into :: proc(c: ^Index_Cursor, dst: []u8) -> Error {
	done := 0
	for done < len(dst) {
		have := idx_avail(c, min(len(dst) - done, len(c.buf))) or_return
		if have == 0 {
			return .Corrupt
		}
		k := copy(dst[done:], c.buf[c.pos:c.pos + min(have, len(dst) - done)])
		c.pos += k
		done += k
	}
	return .None
}

@(private = "file")
idx_find :: proc(c: ^Index_Cursor, start: int, end: i64, ch: u8) -> (at: int, err: Error) {
	scan := start
	want := start + 256
	for {
		have := idx_avail(c, want) or_return
		bound := int(min(i64(have), end - idx_off(c)))
		if scan < bound {
			if i := bytes.index_byte(c.buf[c.pos + scan:c.pos + bound], ch); i >= 0 {
				return scan + i, .None
			}
			scan = bound
		}
		if bound < want {
			return 0, .Corrupt
		}
		want *= 2
	}
}

@(private = "file")
idx_varint :: proc "contextless" (p: []u8) -> (val: int, n: int, ok: bool) {
	if len(p) == 0 {
		return
	}
	b := p[0]
	v := u64(b & 127)
	n = 1
	for b & 128 != 0 {
		if n >= len(p) {
			return
		}
		v += 1
		if v == 0 || v >> 57 != 0 {
			return
		}
		b = p[n]
		n += 1
		v = (v << 7) + u64(b & 127)
	}
	if v > u64(max(i32)) {
		return
	}
	return int(v), n, true
}

@(private = "file")
idx_set_path :: proc(c: ^Index_Cursor, keep: int, suffix: []u8, stage: u8) -> Error {
	if c.check_order && c.started {
		r := bytes.compare(c.path[keep:], suffix)
		if r > 0 || (r == 0 && stage <= c.stage) {
			return .Corrupt
		}
	}
	if err := resize(&c.path, keep + len(suffix)); err != nil {
		return .No_Memory
	}
	copy(c.path[keep:], suffix)
	c.stage = stage
	c.started = true
	return .None
}

@(private = "file")
idx_read_entry :: proc(c: ^Index_Cursor, e: ^Index_Entry) -> Error {
	if c.remaining <= 0 {
		return .Corrupt
	}
	hs := c.hs
	fixed := 42 + hs
	idx_need(c, fixed) or_return
	p := c.buf[c.pos:c.len]
	e.ctime_s = endian.unchecked_get_u32be(p[0:])
	e.ctime_ns = endian.unchecked_get_u32be(p[4:])
	e.mtime_s = endian.unchecked_get_u32be(p[8:])
	e.mtime_ns = endian.unchecked_get_u32be(p[12:])
	e.dev = endian.unchecked_get_u32be(p[16:])
	e.ino = endian.unchecked_get_u32be(p[20:])
	e.mode = endian.unchecked_get_u32be(p[24:])
	e.uid = endian.unchecked_get_u32be(p[28:])
	e.gid = endian.unchecked_get_u32be(p[32:])
	e.size = endian.unchecked_get_u32be(p[36:])
	e.oid = {}
	copy(e.oid[:hs], p[40:40 + hs])
	flags := endian.unchecked_get_u16be(p[40 + hs:])
	e.flags = {}
	if flags & 0x8000 != 0 {
		e.flags += {.Assume_Valid}
	}
	e.stage = u8((flags >> 12) & 3)
	off := fixed
	if flags & 0x4000 != 0 {
		if c.version < 3 {
			return .Corrupt
		}
		idx_need(c, fixed + 2) or_return
		p = c.buf[c.pos:c.len]
		x := endian.unchecked_get_u16be(p[fixed:])
		if x & ~u16(0x6000) != 0 {
			return .Corrupt
		}
		if x & 0x4000 != 0 {
			e.flags += {.Skip_Worktree}
		}
		if x & 0x2000 != 0 {
			e.flags += {.Intent_To_Add}
		}
		off += 2
	}
	namelen := int(flags & 0xfff)
	if c.version < 4 {
		total: int
		if namelen < 0xfff {
			total = (off + namelen + 8) &~ 7
			idx_need(c, total) or_return
			p = c.buf[c.pos:c.len]
			if bytes.index_byte(p[off:off + namelen + 1], 0) != namelen {
				return .Corrupt
			}
		} else {
			nul := idx_find(c, off, c.limit, 0) or_return
			namelen = nul - off
			total = (nul + 8) &~ 7
			idx_need(c, total) or_return
			p = c.buf[c.pos:c.len]
		}
		for b in p[off + namelen + 1:total] {
			if b != 0 {
				return .Corrupt
			}
		}
		idx_set_path(c, 0, p[off:off + namelen], e.stage) or_return
		c.pos += total
	} else {
		have := idx_avail(c, off + 10) or_return
		if have <= off {
			return .Corrupt
		}
		strip, vlen, ok := idx_varint(c.buf[c.pos + off:c.pos + have])
		if !ok || strip > len(c.path) {
			return .Corrupt
		}
		keep := len(c.path) - strip
		start := off + vlen
		nul := idx_find(c, start, c.limit, 0) or_return
		if namelen < 0xfff && namelen != keep + nul - start {
			return .Corrupt
		}
		idx_set_path(c, keep, c.buf[c.pos + start:c.pos + nul], e.stage) or_return
		c.pos += nul + 1
	}
	e.path = string(c.path[:])
	c.remaining -= 1
	return .None
}

@(private = "file")
idx_skip_entry :: proc(c: ^Index_Cursor) -> (namelen: int, err: Error) {
	if c.remaining <= 0 {
		return 0, .Corrupt
	}
	fixed := 42 + c.hs
	idx_need(c, fixed) or_return
	flags := endian.unchecked_get_u16be(c.buf[c.pos + fixed - 2:])
	off := fixed
	if flags & 0x4000 != 0 {
		if c.version < 3 {
			return 0, .Corrupt
		}
		off += 2
	}
	namelen = int(flags & 0xfff)
	if c.version < 4 {
		total: int
		if namelen < 0xfff {
			total = (off + namelen + 8) &~ 7
		} else {
			nul := idx_find(c, off, c.limit, 0) or_return
			namelen = nul - off
			total = (nul + 8) &~ 7
		}
		idx_need(c, total) or_return
		c.pos += total
	} else {
		have := idx_avail(c, off + 10) or_return
		if have <= off {
			return 0, .Corrupt
		}
		strip, vlen, ok := idx_varint(c.buf[c.pos + off:c.pos + have])
		if !ok || strip > c.plen {
			return 0, .Corrupt
		}
		start := off + vlen
		nul := idx_find(c, start, c.limit, 0) or_return
		namelen = c.plen - strip + nul - start
		c.plen = namelen
		c.pos += nul + 1
	}
	c.remaining -= 1
	return namelen, .None
}

@(private = "file")
idx_scan :: proc(c: ^Index_Cursor, s: ^Index_Scan, tree: ^Cache_Tree) -> Error {
	s.adds_off = -1
	for _ in 0 ..< c.count {
		off := idx_off(c)
		n := idx_skip_entry(c) or_return
		if n == 0 {
			if s.adds_off >= 0 {
				s.late_empty = true
			} else {
				s.lead_empty += 1
			}
		} else if s.adds_off < 0 {
			s.adds_off = off
		}
	}
	if s.adds_off < 0 {
		s.adds_off = idx_off(c)
	}
	idx_extensions(c, s, tree) or_return
	return idx_hash_finish(c)
}

@(private = "file")
idx_extensions :: proc(c: ^Index_Cursor, s: ^Index_Scan, tree: ^Cache_Tree) -> Error {
	for idx_off(c) < c.limit {
		idx_need(c, 8) or_return
		sig := string(c.buf[c.pos:c.pos + 4])
		size := i64(endian.unchecked_get_u32be(c.buf[c.pos + 4:]))
		c.pos += 8
		if size > c.limit - idx_off(c) {
			return .Corrupt
		}
		switch sig {
		case "link":
			if s == nil || s.has_link {
				return .Corrupt
			}
			s.has_link = true
			data, aerr := make([]u8, int(size), c.allocator)
			if aerr != nil {
				return .No_Memory
			}
			s.link = data
			idx_read_into(c, data) or_return
			continue
		case "TREE":
			if tree != nil {
				idx_parse_tree(c, size, tree) or_return
				continue
			}
		case "sdir", "REUC", "UNTR", "FSMN", "EOIE", "IEOT":
		case:
			if sig[0] < 'A' || sig[0] > 'Z' {
				return .Unsupported
			}
		}
		idx_skip(c, size) or_return
	}
	return .None
}

@(private = "file")
idx_hash_finish :: proc(c: ^Index_Cursor) -> Error {
	if idx_off(c) != c.limit {
		return .Corrupt
	}
	if c.job != nil {
		sum := idx_job_end(c) or_return
		return .None if sum == c.trailer else .Corrupt
	}
	if !c.hashing {
		return .None
	}
	idx_hash_consumed(c)
	c.hashing = false
	sum, _ := odb.hasher_final(&c.hasher)
	if sum != c.trailer {
		return .Corrupt
	}
	return .None
}

@(private = "file")
idx_eoie :: proc(c: ^Index_Cursor) -> (start: i64, has_link: bool, ok: bool) {
	if c.format != .Sha1 || c.limit < INDEX_HEADER + 32 {
		return
	}
	at := c.limit - 32
	tail: [32]u8
	if n, err := idx_pread(c.vfs, c.file, c.ident, tail[:], at); err != .None || n != 32 {
		return
	}
	if string(tail[:4]) != "EOIE" || endian.unchecked_get_u32be(tail[4:]) != 24 {
		return
	}
	start = i64(endian.unchecked_get_u32be(tail[8:]))
	if start < INDEX_HEADER || start > at {
		return
	}
	h: odb.Hasher
	odb.hasher_init(&h, .Sha1)
	p := start
	for p < at {
		if at - p < 8 {
			return
		}
		hdr: [8]u8
		if n, err := idx_pread(c.vfs, c.file, c.ident, hdr[:], p); err != .None || n != 8 {
			return
		}
		odb.hasher_update(&h, hdr[:])
		size := i64(endian.unchecked_get_u32be(hdr[4:]))
		if size > at - p - 8 {
			return
		}
		if string(hdr[:4]) == "link" {
			has_link = true
		}
		p += 8 + size
	}
	sum, _ := odb.hasher_final(&h)
	if string(sum[:20]) != string(tail[12:32]) {
		return
	}
	return start, has_link, true
}

@(private = "file")
idx_ewah_parse :: proc(data: []u8) -> (w: Index_Ewah, used: int, ok: bool) {
	if len(data) < 8 {
		return
	}
	nwords := i64(endian.unchecked_get_u32be(data[4:]))
	total := 8 + nwords * 8 + 4
	if total > i64(len(data)) {
		return
	}
	w.words = data[8:8 + nwords * 8]
	w.nwords = int(nwords)
	return w, int(total), true
}

@(private = "file")
idx_ewah_next :: proc(w: ^Index_Ewah, limit: int) -> (pos: int, err: Error) {
	for {
		if w.cur != 0 {
			tz := int(intrinsics.count_trailing_zeros(w.cur))
			w.cur &= w.cur - 1
			pos = w.cur_base + tz
			if pos >= limit {
				return 0, .Corrupt
			}
			return pos, .None
		}
		if w.ones > 0 {
			pos = w.pos
			w.pos += 1
			w.ones -= 1
			return pos, .None
		}
		if w.lit_left > 0 {
			if w.ptr >= w.nwords {
				return 0, .Corrupt
			}
			w.cur = endian.unchecked_get_u64be(w.words[w.ptr * 8:])
			w.cur_base = w.pos
			w.pos += 64
			w.ptr += 1
			w.lit_left -= 1
			continue
		}
		if w.ptr >= w.nwords {
			return INDEX_NO_BIT, .None
		}
		rlw := endian.unchecked_get_u64be(w.words[w.ptr * 8:])
		w.ptr += 1
		run := int((rlw >> 1) & 0xffff_ffff) * 64
		w.lit_left = int(rlw >> 33)
		if rlw & 1 != 0 {
			if run > 0 && run > limit - w.pos {
				return 0, .Corrupt
			}
			w.ones = run
		} else {
			w.pos = min(w.pos + run, 1 << 48)
		}
	}
}

@(private = "file")
idx_ewah_count :: proc(w: Index_Ewah, limit: int) -> (n: int, err: Error) {
	it := w
	for {
		pos := idx_ewah_next(&it, limit) or_return
		if pos == INDEX_NO_BIT {
			return
		}
		n += 1
	}
}

@(private = "file")
idx_parse_number :: proc "contextless" (s: []u8, allow_negative: bool) -> (v: int, n: int, ok: bool) {
	neg := false
	if n < len(s) && s[n] == '-' {
		if !allow_negative {
			return
		}
		neg = true
		n += 1
	}
	digits := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		if digits == 9 {
			return
		}
		v = v * 10 + int(s[n] - '0')
		n += 1
		digits += 1
	}
	if digits == 0 {
		return
	}
	return -v if neg else v, n, true
}

@(private = "file")
Index_Tree_Frame :: struct {
	plen: int,
	left: int,
}

@(private = "file")
idx_parse_tree :: proc(c: ^Index_Cursor, size: i64, ct: ^Cache_Tree) -> Error {
	end := idx_off(c) + size
	stack, serr := make([dynamic]Index_Tree_Frame, 0, 16, c.allocator)
	if serr != nil {
		return .No_Memory
	}
	defer delete(stack)
	path, perr := make([dynamic]u8, 0, 256, c.allocator)
	if perr != nil {
		return .No_Memory
	}
	defer delete(path)
	root := true
	for idx_off(c) < end {
		if !root && len(stack) == 0 {
			return .Corrupt
		}
		nul := idx_find(c, 0, end, 0) or_return
		name := c.buf[c.pos:c.pos + nul]
		if root {
			if nul != 0 {
				return .Corrupt
			}
		} else {
			if nul == 0 || bytes.index_byte(name, '/') >= 0 {
				return .Corrupt
			}
			top := &stack[len(stack) - 1]
			top.left -= 1
			if err := resize(&path, top.plen); err != nil {
				return .No_Memory
			}
			if top.plen > 0 {
				if _, err := append(&path, '/'); err != nil {
					return .No_Memory
				}
			}
			if _, err := append(&path, ..name); err != nil {
				return .No_Memory
			}
		}
		c.pos += nul + 1
		nl := idx_find(c, 0, end, '\n') or_return
		line := c.buf[c.pos:c.pos + nl]
		entries, n1, ok1 := idx_parse_number(line, true)
		if !ok1 || n1 >= len(line) || line[n1] != ' ' {
			return .Corrupt
		}
		subtrees, n2, ok2 := idx_parse_number(line[n1 + 1:], false)
		if !ok2 || n1 + 1 + n2 != len(line) {
			return .Corrupt
		}
		c.pos += nl + 1
		if entries >= 0 {
			if i64(c.hs) > end - idx_off(c) {
				return .Corrupt
			}
			idx_need(c, c.hs) or_return
			node: Cache_Tree_Node
			copy(node.oid[:c.hs], c.buf[c.pos:c.pos + c.hs])
			node.entries = entries
			c.pos += c.hs
			if string(path[:]) in ct.nodes {
				return .Corrupt
			}
			key, kerr := make([]u8, len(path), ct.allocator)
			if kerr != nil {
				return .No_Memory
			}
			copy(key, path[:])
			if _, err := map_insert(&ct.nodes, string(key), node); err != nil {
				delete(key, ct.allocator)
				return .No_Memory
			}
		}
		if _, err := append(&stack, Index_Tree_Frame{len(path), subtrees}); err != nil {
			return .No_Memory
		}
		root = false
		for len(stack) > 0 && stack[len(stack) - 1].left == 0 {
			pop(&stack)
		}
	}
	if root || len(stack) != 0 || idx_off(c) != end {
		return .Corrupt
	}
	return .None
}
