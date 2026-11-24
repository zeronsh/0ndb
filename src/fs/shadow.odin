package fs

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"
import "core:strconv"
import "../fstree"
import "../odb"
import "../prim"
import "core:sync"

SHADOW_MAGIC :: u64(0x3164_6873_6264_6e30)
SHADOW_FAMILY :: u64(0x00ff_ffff_ffff_ffff)
SHADOW_IDX_MAGIC :: u64(0x3178_6469_6264_6e30)
SHADOW_HEADER :: 4096
SHADOW_LOG_HEADER :: 16
SHADOW_PATH_SLOT :: 32
SHADOW_INODE_SLOT :: 16
SHADOW_MIN_CAP :: u64(1024)
SHADOW_CHECKPOINT :: u64(1 << 20)
SHADOW_BLOCK :: 4096
SHADOW_MAX_RECORD :: 1 << 20

Stat :: struct {
	mtime_ns: i64,
	ctime_ns: i64,
	size:     i64,
	ino:      u64,
	mode:     u32,
}

Entry :: struct {
	inode:  fstree.Inode_Id,
	kind:   fstree.Kind,
	stat:   Stat,
	oid:    odb.Oid,
	ver:    u32,
	racy:   bool,
}

Shadow_Child :: struct {
	name:  string,
	entry: Entry,
}

@(private = "file")
Pending_Rec :: struct {
	path:  string,
	del:   bool,
	fresh: bool,
	entry: Entry,
}

@(private = "file")
Path_Slot :: struct {
	hash: u64,
	off:  u64,
	head: u64,
	link: u64,
}

@(private = "file")
Inode_Slot :: struct {
	hash: u64,
	off:  u64,
}

@(private = "file")
Rec :: struct {
	off:     u64,
	size:    u64,
	del:     bool,
	linked:  bool,
	path:    string,
	entry:   Entry,
	sibling: u64,
	ids:     u64,
}

Shadow :: struct {
	burned:     u64,
	republish:  bool,
	clock:      Clock,
	hold:       bool,
	owed:       bool,
	txn:        bool,
	txn_len:    int,
	undo:       [dynamic]Shadow_Undo,
	vfs:        prim.Vfs,
	dir:        string,
	allocator:  runtime.Allocator,
	oid_size:   int,
	gen:        u64,
	log_fd:     prim.Fd,
	idx_fd:     prim.Fd,
	cap:        u64,
	used:       u64,
	inode_used: u64,
	covered:    u64,
	idx_lost:   bool,
	log_end:    u64,
	live:       u64,
	garbage:    u64,
	pending:    [dynamic]Pending_Rec,
	index:      map[string]int,
	by_inode:   map[fstree.Inode_Id]int,
	scratch:    [dynamic]u8,
	probe:      [dynamic]u8,
	out:        [dynamic]u8,
	probe_del:  bool,
	mapped:     []u8,
	map_lock:   ^sync.Mutex,
	lock:       ^sync.Mutex,
	versions:   [dynamic][]fstree.Op_Id,
	ver_index:  map[u64]u32,
	ver_gen:    u32,
	ver_ids:    [dynamic]fstree.Op_Id,
	mark:       Shadow_Mark,
	damaged:    bool,
}

SHADOW_VERSION_MAX :: 1024

@(private = "file")
SHADOW_VER_BITS :: 24

shadow_version :: proc(s: ^Shadow, e: Entry) -> (ids: []fstree.Op_Id, ok: bool) {
	if e.ver == 0 {
		return nil, true
	}
	ix := int(e.ver & (1 << SHADOW_VER_BITS - 1))
	if e.ver >> SHADOW_VER_BITS != s.ver_gen || ix == 0 || ix > len(s.versions) {
		return nil, false
	}
	return s.versions[ix - 1], true
}

@(private = "file")
version_hash :: proc "contextless" (ids: []fstree.Op_Id) -> u64 {
	h := u64(14695981039346656037)
	for id in ids {
		h = (h ~ u64(id.actor)) * 1099511628211
		h = (h ~ id.seq) * 1099511628211
	}
	return h
}

shadow_version_add :: proc(s: ^Shadow, ids: []fstree.Op_Id) -> (ver: u32, err: Error) {
	if len(ids) == 0 {
		return 0, .None
	}
	if len(ids) > SHADOW_VERSION_MAX || len(s.versions) >= 1 << SHADOW_VER_BITS - 1 {
		return 0, .Too_Large
	}
	h := version_hash(ids)
	if j, found := s.ver_index[h]; found {
		v := s.versions[j - 1]
		same := len(v) == len(ids)
		for x, k in v {
			if !same {
				break
			}
			same = x == ids[k]
		}
		if same {
			return s.ver_gen << SHADOW_VER_BITS | j, .None
		}
	}
	c, aerr := make([]fstree.Op_Id, len(ids), s.allocator)
	if aerr != nil {
		return 0, .No_Memory
	}
	copy(c, ids)
	if _, e := append(&s.versions, c); e != nil {
		delete(c, s.allocator)
		return 0, .No_Memory
	}
	j := u32(len(s.versions))
	if s.ver_index == nil {
		s.ver_index = make(map[u64]u32, s.allocator)
	}
	s.ver_index[h] = j
	return s.ver_gen << SHADOW_VER_BITS | j, .None
}

@(private = "file")
versions_clear :: proc(s: ^Shadow) {
	for v in s.versions {
		delete(v, s.allocator)
	}
	clear(&s.versions)
	clear(&s.ver_index)
	s.ver_gen = (s.ver_gen + 1) & 0xff
}

shadow_open :: proc(s: ^Shadow, vfs: prim.Vfs, dir: string, format: odb.Hash_Format, allocator := context.allocator, mark := Shadow_Mark{}) -> Error {
	s^ = {
		vfs       = vfs,
		allocator = allocator,
		oid_size  = odb.oid_size(format),
		log_fd    = prim.INVALID_FD,
		idx_fd    = prim.INVALID_FD,
		mark      = mark,
	}
	d, aerr := clone_string(dir, allocator)
	if aerr != nil {
		return .No_Memory
	}
	s.dir = d
	if err := from_prim(prim.mkdir_all(s.vfs, dir, 0o700)); err != .None {
		shadow_close(s)
		return err
	}
	gen, have, gerr := read_gen(s, dir)
	if gerr == .Corrupt && mark.end != 0 {
		have, gerr = false, .None
	}
	if gerr != .None {
		shadow_close(s)
		return gerr
	}
	s.gen = gen if have else mark.gen
	s.damaged = mark.end != 0 && (!have || gen != mark.gen)
	if err := shadow_attach(s); err != .None {
		shadow_close(s)
		return err
	}
	return .None
}

shadow_attach :: proc(s: ^Shadow) -> Error {
	if s.log_fd >= 0 {
		return .None
	}
	if s.republish {
		write_gen(s, s.dir, s.gen) or_return
		s.republish = false
	}
	s.pending = make([dynamic]Pending_Rec, s.allocator)
	s.undo = make([dynamic]Shadow_Undo, s.allocator)
	s.index = make(map[string]int, s.allocator)
	s.by_inode = make(map[fstree.Inode_Id]int, s.allocator)
	s.scratch = make([dynamic]u8, s.allocator)
	s.probe = make([dynamic]u8, s.allocator)
	s.out = make([dynamic]u8, s.allocator)
	s.idx_lost = false
	err := open_gen(s)
	if err != .None {
		shadow_detach(s)
	} else if !s.damaged {
		s.mark = {s.gen, s.log_end}
	}
	return err
}

shadow_detach :: proc(s: ^Shadow) {
	if s.idx_fd >= 0 && !s.idx_lost && !s.damaged && len(s.pending) == 0 && s.log_fd >= 0 {
		if s.covered == s.log_end || checkpoint(s) == .None {
			write_header(s, true)
		}
	}
	idx_unmap(s)
	prim.close_file(s.vfs, s.log_fd)
	prim.close_file(s.vfs, s.idx_fd)
	s.log_fd = prim.INVALID_FD
	s.idx_fd = prim.INVALID_FD
	pending_clear(s)
	delete(s.pending)
	delete(s.undo)
	s.undo = nil
	delete(s.index)
	delete(s.by_inode)
	delete(s.scratch)
	delete(s.probe)
	delete(s.out)
	versions_clear(s)
	delete(s.versions)
	delete(s.ver_index)
	s.ver_index = nil
	delete(s.ver_ids)
	s.versions = nil
	s.ver_ids = nil
	s.pending = nil
	s.index = nil
	s.by_inode = nil
	s.scratch = nil
	s.probe = nil
	s.out = nil
}

shadow_close :: proc(s: ^Shadow) {
	shadow_detach(s)
	delete(s.dir, s.allocator)
	s.dir = ""
}

shadow_attached :: proc "contextless" (s: ^Shadow) -> bool {
	return s.vfs.procs != nil && s.log_fd >= 0
}

shadow_dirty :: proc "contextless" (s: ^Shadow) -> bool {
	return len(s.pending) > 0
}

shadow_live :: proc "contextless" (s: ^Shadow) -> u64 {
	return s.live
}

shadow_empty :: proc(s: ^Shadow) -> (empty: bool, err: Error) {
	index_heal(s) or_return
	for p in s.pending {
		if !p.del && len(p.path) > 0 {
			return false, .None
		}
	}
	_, slot, found := find_path(s, "", path_hash("")) or_return
	return !found || slot.head == 0, .None
}

@(private = "file")
index_heal :: proc(s: ^Shadow) -> Error {
	if !s.idx_lost || s.idx_fd < 0 {
		return .None
	}
	idx_unmap(s)
	rebuild_index(s, s.cap) or_return
	s.idx_lost = false
	return .None
}

shadow_reserve :: proc(s: ^Shadow, n: u64) -> Error {
	want := cap_for(s.used + n)
	if want <= s.cap {
		return .None
	}
	return rebuild_index(s, want)
}

shadow_get :: proc(s: ^Shadow, path: string) -> (e: Entry, found: bool, err: Error) {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	index_heal(s) or_return
	if i, ok := s.index[path]; ok {
		p := s.pending[i]
		return p.entry, !p.del, .None
	}
	_, slot, ok := find_path(s, path, path_hash(path)) or_return
	if !ok {
		return {}, false, .None
	}
	r := read_live(s, slot.off, &s.scratch) or_return
	if r.del {
		return {}, false, .None
	}
	return r.entry, true, .None
}

shadow_by_inode :: proc(s: ^Shadow, inode: fstree.Inode_Id, allocator := context.allocator) -> (path: string, e: Entry, found: bool, err: Error) {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	index_heal(s) or_return
	if i, ok := s.by_inode[inode]; ok {
		p := s.pending[i]
		if !p.del && p.entry.inode == inode {
			out, aerr := clone_string(p.path, allocator)
			if aerr != nil {
				return "", {}, false, .No_Memory
			}
			return out, p.entry, true, .None
		}
	}
	h := inode_hash(inode)
	mask := s.cap - 1
	i := h & mask
	for _ in 0 ..< s.cap {
		slot := read_inode_slot(s, i) or_return
		if slot.hash == 0 {
			return
		}
		if slot.hash == h && slot.off != 0 {
			r := read_live(s, slot.off, &s.scratch) or_return
			cur: Path_Slot
			live := false
			if !r.del && r.entry.inode == inode {
				_, cur, live = find_path(s, r.path, path_hash(r.path)) or_return
				live = live && cur.off == slot.off
			}
			if live {
				if pi, ok := s.index[r.path]; ok {
					p := s.pending[pi]
					if p.del || p.entry.inode != inode {
						return
					}
					r.entry = p.entry
				}
				out, aerr := clone_string(r.path, allocator)
				if aerr != nil {
					return "", {}, false, .No_Memory
				}
				return out, r.entry, true, .None
			}
		}
		i = (i + 1) & mask
	}
	return
}

shadow_put :: proc(s: ^Shadow, path: string, e: Entry) -> Error {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	index_heal(s) or_return
	return pending_set(s, path, false, racy_mark(s, e))
}

@(private = "file")
racy_mark :: proc(s: ^Shadow, e: Entry) -> Entry {
	ne := e
	if ne.kind == .File && s.clock.wall_ms != nil {
		ne.racy = stat_racy(ne.stat, s.clock.wall_ms(s.clock.data) * 1_000_000)
	}
	return ne
}

stat_racy :: proc "contextless" (st: Stat, now_ns: i64) -> bool {
	tick := i64(2_000_000_000) if st.mtime_ns % 1_000_000_000 == 0 else i64(100_000_000)
	return st.mtime_ns + tick > now_ns || st.ctime_ns + tick > now_ns
}

stat_clean :: proc "contextless" (st: Stat, e: Entry) -> bool {
	return st == e.stat && !e.racy
}

shadow_remove :: proc(s: ^Shadow, path: string) -> Error {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	index_heal(s) or_return
	return pending_set(s, path, true, {})
}

shadow_append :: proc(s: ^Shadow, path: string, e: Entry) -> Error {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	p, aerr := clone_string(path, s.allocator)
	if aerr != nil {
		return .No_Memory
	}
	if _, err := append(&s.pending, Pending_Rec{path = p, fresh = true, entry = racy_mark(s, e)}); err != nil {
		delete(p, s.allocator)
		return .No_Memory
	}
	return .None
}

shadow_pending_count :: proc "contextless" (s: ^Shadow) -> int {
	return len(s.pending)
}

shadow_children :: proc(s: ^Shadow, dir: string, out: ^[dynamic]Shadow_Child, allocator := context.allocator) -> Error {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	index_heal(s) or_return
	_, slot, ok := find_path(s, dir, path_hash(dir)) or_return
	off := slot.head if ok else 0
	steps: u64
	for off != 0 {
		steps += 1
		if steps > s.log_end {
			return .Corrupt
		}
		r := read_live(s, off, &s.scratch) or_return
		if !r.linked || len(r.path) == 0 || path_parent(r.path) != dir {
			s.damaged = true
			return .Corrupt
		}
		next := r.sibling
		if next >= off {
			s.damaged = true
			return .Corrupt
		}
		if _, pending := s.index[r.path]; !pending {
			name, aerr := clone_string(path_name(r.path), allocator)
			if aerr != nil {
				return .No_Memory
			}
			e := r.entry
			present := !r.del
			_, cur, found := find_path(s, r.path, path_hash(r.path)) or_return
			if !found || cur.link != off {
				present = false
			} else if cur.off != off {
				c := read_live(s, cur.off, &s.scratch) or_return
				e = c.entry
				present = !c.del
			}
			if present {
				if _, perr := append(out, Shadow_Child{name = name, entry = e}); perr != nil {
					delete(name, allocator)
					return .No_Memory
				}
			} else {
				delete(name, allocator)
			}
		}
		off = next
	}
	for p, i in s.pending {
		if p.del || len(p.path) == 0 || path_parent(p.path) != dir {
			continue
		}
		if j, ok2 := s.index[p.path]; ok2 && j != i {
			continue
		}
		name, aerr := clone_string(path_name(p.path), allocator)
		if aerr != nil {
			return .No_Memory
		}
		if _, perr := append(out, Shadow_Child{name = name, entry = p.entry}); perr != nil {
			delete(name, allocator)
			return .No_Memory
		}
	}
	return .None
}

shadow_children_free :: proc(list: []Shadow_Child, allocator := context.allocator) {
	for c in list {
		delete(c.name, allocator)
	}
}

shadow_persist :: proc(s: ^Shadow) -> Error {
	if s.lock != nil {
		sync.mutex_lock(s.lock)
	}
	defer if s.lock != nil {
		sync.mutex_unlock(s.lock)
	}
	if len(s.pending) == 0 || s.hold || s.owed || s.txn {
		return .None
	}
	if s.log_fd < 0 {
		return .Invalid
	}
	index_heal(s) or_return
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	want := cap_for(s.used + u64(len(s.pending)) + 1)
	if want > s.cap {
		rebuild_index(s, want) or_return
	}
	idx_map(s)
	defer idx_unmap(s)
	clear(&s.out)
	start := s.log_end
	Parent_Info :: struct {
		live:  bool,
		found: bool,
		slot:  u64,
		head:  u64,
		disk:  u64,
	}
	live := make(map[string]bool, len(s.pending), context.temp_allocator)
	parents := make(map[string]Parent_Info, 64, context.temp_allocator)
	order := make([]int, len(s.pending), context.temp_allocator)
	for i in 0 ..< len(order) {
		order[i] = i
	}
	context.user_ptr = s
	slice.stable_sort_by(order, proc(a, b: int) -> bool {
		sh := (^Shadow)(context.user_ptr)
		return path_depth(sh.pending[a].path) < path_depth(sh.pending[b].path)
	})
	for oi in order {
		p := s.pending[oi]
		off := start + u64(len(s.out))
		linked := false
		sibling: u64
		if !p.del && len(p.path) > 0 {
			cur, known := live[p.path]
			if !known && !p.fresh {
				cur = key_live(s, p.path) or_return
			}
			if !cur {
				parent := path_parent(p.path)
				info, have := parents[parent]
				if !have {
					pi, pslot, pfound, pdel := find_path_rec(s, parent) or_return
					info = Parent_Info{pfound && !pdel, pfound, pi, pslot.head, pslot.head}
				}
				if plive, pknown := live[parent]; pknown {
					info.live = plive
				}
				if info.live {
					linked = true
					sibling = info.head
					info.head = off
				}
				parents[parent] = info
			}
		}
		live[p.path] = !p.del
		ids, vok := shadow_version(s, p.entry)
		if !vok {
			return .Corrupt
		}
		if encode_rec(&s.out, off, p.path, p.del, p.entry, ids, linked, sibling, s.oid_size) == 0 {
			return .Too_Large
		}
	}
	if err := prim.write_at(s.vfs, s.log_fd, s.out[:], i64(start)); err != .None {
		prim.truncate(s.vfs, s.log_fd, i64(start))
		return from_prim(err)
	}
	if err := prim.datasync(s.vfs, s.log_fd); err != .None {
		prim.truncate(s.vfs, s.log_fd, i64(start))
		return from_prim(err)
	}
	s.log_end = start + u64(len(s.out))
	s.mark = {s.gen, s.log_end}
	ierr: Error
	index: {
		pos := 0
		for _ in order {
			n := int(prim.get_u32le(s.out[pos:pos + 4]))
			r, derr := decode_rec(s.out[pos + 8:][:n], s.oid_size, &s.ver_ids)
			if derr != .None {
				ierr = derr
				break index
			}
			r.off = start + u64(pos)
			r.size = u64(n + 8)
			if aerr := apply_rec(s, r, false); aerr != .None {
				ierr = aerr
				break index
			}
			pos += n + 8
		}
		for parent in sorted_strings(parents) {
			info := parents[parent]
			if info.head == info.disk {
				continue
			}
			pi, pslot, pfound, ferr := find_path(s, parent, path_hash(parent))
			if ferr != .None {
				ierr = ferr
				break index
			}
			if pfound && pslot.head < info.head {
				pslot.head = info.head
				if werr := write_path_slot(s, pi, pslot); werr != .None {
					ierr = werr
					break index
				}
			}
		}
	}
	pending_clear(s)
	if ierr != .None {
		idx_unmap(s)
		if rebuild_index(s, s.cap) != .None {
			s.idx_lost = true
			return ierr
		}
		return .None
	}
	if cap(s.out) > 1 << 20 {
		delete(s.out)
		s.out = make([dynamic]u8, s.allocator)
	}
	idx_unmap(s)
	if s.log_end - s.covered >= SHADOW_CHECKPOINT {
		checkpoint(s) or_return
	} else {
		write_header(s, false)
	}
	return .None
}

shadow_checkpoint :: proc(s: ^Shadow) -> Error {
	if s.idx_fd < 0 || s.covered == s.log_end {
		return .None
	}
	return checkpoint(s)
}

@(private = "file")
compact_entry :: proc(s, n: ^Shadow, e: Entry) -> (out: Entry, err: Error) {
	out = e
	ids, ok := shadow_version(s, e)
	if !ok {
		return out, .Corrupt
	}
	out.ver = shadow_version_add(n, ids) or_return
	return out, .None
}

shadow_compact :: proc(s: ^Shadow) -> Error {
	held := s.lock
	s.lock = nil
	defer s.lock = held
	if len(s.pending) > 0 {
		shadow_persist(s) or_return
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ng := max(s.gen, s.burned) + 1
	log_path := gen_path(s.dir, ng, "log", context.temp_allocator)
	idx_path := gen_path(s.dir, ng, "idx", context.temp_allocator)
	prim.remove(s.vfs, log_path)
	prim.remove(s.vfs, idx_path)
	n := Shadow {
		vfs       = s.vfs,
		dir       = s.dir,
		allocator = s.allocator,
		oid_size  = s.oid_size,
		gen       = ng,
		log_fd    = prim.INVALID_FD,
		idx_fd    = prim.INVALID_FD,
	}
	n.pending = make([dynamic]Pending_Rec, s.allocator)
	n.index = make(map[string]int, s.allocator)
	n.by_inode = make(map[fstree.Inode_Id]int, s.allocator)
	n.scratch = make([dynamic]u8, s.allocator)
	n.probe = make([dynamic]u8, s.allocator)
	n.out = make([dynamic]u8, s.allocator)
	n.versions = make([dynamic][]fstree.Op_Id, s.allocator)
	ok := false
	defer if !ok {
		shadow_detach(&n)
		prim.remove(s.vfs, log_path)
		prim.remove(s.vfs, idx_path)
	}
	root, _ := shadow_get(s, "") or_return
	root = compact_entry(s, &n, root) or_return
	create_files(&n, cap_for(s.live + 1), root) or_return
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, "")
	kids := make([dynamic]Shadow_Child, context.temp_allocator)
	for len(stack) > 0 {
		dir := pop(&stack)
		clear(&kids)
		shadow_children(s, dir, &kids, context.temp_allocator) or_return
		for c in kids {
			p, _ := path_join(dir, c.name, context.temp_allocator)
			shadow_append(&n, p, compact_entry(s, &n, c.entry) or_return) or_return
			if c.entry.kind == .Dir {
				append(&stack, p)
			}
		}
		if len(n.pending) >= 65536 {
			shadow_persist(&n) or_return
		}
	}
	shadow_persist(&n) or_return
	checkpoint(&n) or_return
	write_header(&n, true)
	from_prim(prim.datasync(s.vfs, n.idx_fd)) or_return
	ok = true
	if werr := write_gen(s, s.dir, ng); werr != .None {
		s.burned = max(s.burned, ng)
		shadow_detach(&n)
		if write_gen(s, s.dir, s.gen) != .None {
			s.republish = true
			shadow_detach(s)
		}
		return werr
	}
	s.mark = {ng, n.log_end}
	shadow_detach(&n)
	old_log := gen_path(s.dir, s.gen, "log", context.temp_allocator)
	old_idx := gen_path(s.dir, s.gen, "idx", context.temp_allocator)
	shadow_detach(s)
	prim.remove(s.vfs, old_log)
	prim.remove(s.vfs, old_idx)
	s.gen = ng
	return shadow_attach(s)
}

Shadow_Row :: struct {
	path:  string,
	entry: Entry,
}

@(private)
shadow_salvage :: proc(s: ^Shadow, rows: ^map[string]Entry, allocator := context.temp_allocator) -> Error {
	if s.log_fd < 0 {
		return .None
	}
	end := s.log_end
	if s.gen == s.mark.gen && s.mark.end != 0 {
		end = min(end, s.mark.end)
	}
	off := u64(SHADOW_LOG_HEADER)
	for off < end {
		r, err := read_rec(s, off, &s.scratch)
		if err == .Corrupt || err == .None && off + r.size > end {
			off = next_rec(s, off, end) or_return
			if off == 0 {
				return .None
			}
			continue
		}
		if err != .None {
			return err
		}
		off += r.size
		if r.del {
			delete_key(rows, r.path)
			continue
		}
		if r.path in rows {
			rows[r.path] = r.entry
			continue
		}
		p, aerr := clone_string(r.path, allocator)
		if aerr != nil {
			return .No_Memory
		}
		rows[p] = r.entry
	}
	return .None
}

@(private = "file")
next_rec :: proc(s: ^Shadow, bad, end: u64) -> (off: u64, err: Error) {
	head: [4]u8
	got, rerr := prim.read_at(s.vfs, s.log_fd, head[:], i64(bad))
	if rerr != .None {
		return 0, from_prim(rerr)
	}
	n := u64(prim.get_u32le(head[:]))
	if got == 4 && n <= SHADOW_MAX_RECORD && bad + 8 + n < end {
		_, verr := read_rec(s, bad + 8 + n, &s.scratch)
		if verr == .None {
			return bad + 8 + n, .None
		}
		if verr != .Corrupt {
			return 0, verr
		}
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	buf := make([]u8, 1 << 16, context.temp_allocator)
	pos := bad + 1
	for pos + 10 <= end {
		got, rerr = prim.read_at(s.vfs, s.log_fd, buf[:min(u64(len(buf)), end - pos)], i64(pos))
		if rerr != .None {
			return 0, from_prim(rerr)
		}
		if got < 10 {
			break
		}
		for k in 0 ..= got - 10 {
			size := u64(prim.get_u32le(buf[k:k + 4]))
			if size < 3 || size > 1 << 16 || buf[k + 8] != 1 && buf[k + 8] != 2 || buf[k + 9] > 3 || pos + u64(k) + 8 + size > end {
				continue
			}
			_, verr := read_rec(s, pos + u64(k), &s.scratch)
			if verr == .None {
				return pos + u64(k), .None
			}
			if verr != .Corrupt {
				return 0, verr
			}
		}
		pos += u64(got - 9)
	}
	return 0, .None
}

@(private)
shadow_rewrite :: proc(s: ^Shadow, rows: []Shadow_Row) -> Error {
	held := s.lock
	s.lock = nil
	defer s.lock = held
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ng := max(s.gen, s.mark.gen, s.burned) + 1
	for prim.exists(s.vfs, gen_path(s.dir, ng, "log", context.temp_allocator)) {
		ng += 1
	}
	log_path := gen_path(s.dir, ng, "log", context.temp_allocator)
	idx_path := gen_path(s.dir, ng, "idx", context.temp_allocator)
	prim.remove(s.vfs, idx_path)
	n := Shadow {
		vfs       = s.vfs,
		dir       = s.dir,
		allocator = s.allocator,
		oid_size  = s.oid_size,
		gen       = ng,
		log_fd    = prim.INVALID_FD,
		idx_fd    = prim.INVALID_FD,
	}
	n.pending = make([dynamic]Pending_Rec, s.allocator)
	n.index = make(map[string]int, s.allocator)
	n.by_inode = make(map[fstree.Inode_Id]int, s.allocator)
	n.scratch = make([dynamic]u8, s.allocator)
	n.probe = make([dynamic]u8, s.allocator)
	n.out = make([dynamic]u8, s.allocator)
	n.versions = make([dynamic][]fstree.Op_Id, s.allocator)
	ok := false
	defer if !ok {
		shadow_detach(&n)
		prim.remove(s.vfs, log_path)
		prim.remove(s.vfs, idx_path)
	}
	slice.sort_by(rows, proc(a, b: Shadow_Row) -> bool {
		x, y := path_depth(a.path), path_depth(b.path)
		return x < y || x == y && a.path < b.path
	})
	root := Entry{inode = fstree.ROOT, kind = .Dir}
	body := rows
	if len(rows) > 0 && len(rows[0].path) == 0 {
		root = compact_entry(s, &n, rows[0].entry) or_return
		body = rows[1:]
	}
	create_files(&n, cap_for(u64(len(body)) + 1), root) or_return
	for r in body {
		shadow_append(&n, r.path, compact_entry(s, &n, r.entry) or_return) or_return
		if len(n.pending) >= 65536 {
			shadow_persist(&n) or_return
		}
	}
	shadow_persist(&n) or_return
	checkpoint(&n) or_return
	write_header(&n, true)
	from_prim(prim.datasync(s.vfs, n.idx_fd)) or_return
	ok = true
	if werr := write_gen(s, s.dir, ng); werr != .None {
		s.burned = max(s.burned, ng)
		shadow_detach(&n)
		return werr
	}
	old_gen := s.gen
	idx_unmap(s)
	prim.close_file(s.vfs, s.log_fd)
	prim.close_file(s.vfs, s.idx_fd)
	s.log_fd, s.idx_fd = n.log_fd, n.idx_fd
	s.cap, s.used, s.inode_used = n.cap, n.used, n.inode_used
	s.covered, s.log_end = n.covered, n.log_end
	s.live, s.garbage = n.live, n.garbage
	s.gen = ng
	s.mark = {ng, n.log_end}
	s.idx_lost = false
	s.damaged = false
	write_header(s, false)
	n.log_fd, n.idx_fd = prim.INVALID_FD, prim.INVALID_FD
	idx_unmap(&n)
	shadow_detach(&n)
	if old_gen != ng {
		prim.remove(s.vfs, gen_path(s.dir, old_gen, "log", context.temp_allocator))
		prim.remove(s.vfs, gen_path(s.dir, old_gen, "idx", context.temp_allocator))
	}
	return .None
}

@(private = "file")
key_live :: proc(s: ^Shadow, path: string) -> (live: bool, err: Error) {
	_, _, found, del := find_path_rec(s, path) or_return
	return found && !del, .None
}

@(private = "file")
find_path_rec :: proc(s: ^Shadow, path: string) -> (index: u64, slot: Path_Slot, found: bool, del: bool, err: Error) {
	index, slot, found = find_path(s, path, path_hash(path)) or_return
	return index, slot, found, s.probe_del, .None
}

@(private = "file")
pending_set :: proc(s: ^Shadow, path: string, del: bool, e: Entry) -> Error {
	if !del {
		if _, ok := shadow_version(s, e); !ok {
			return .Corrupt
		}
	}
	if i, ok := s.index[path]; ok {
		p := &s.pending[i]
		if s.txn && i < s.txn_len {
			append(&s.undo, Shadow_Undo{i, p.del, p.entry})
		}
		if !p.del {
			if j, ok2 := s.by_inode[p.entry.inode]; ok2 && j == i {
				delete_key(&s.by_inode, p.entry.inode)
			}
		}
		p.del = del
		p.entry = e
		if !del {
			s.by_inode[e.inode] = i
		}
		return .None
	}
	p, aerr := clone_string(path, s.allocator)
	if aerr != nil {
		return .No_Memory
	}
	if _, err := append(&s.pending, Pending_Rec{path = p, del = del, entry = e}); err != nil {
		delete(p, s.allocator)
		return .No_Memory
	}
	i := len(s.pending) - 1
	s.index[p] = i
	if !del {
		s.by_inode[e.inode] = i
	}
	return .None
}

@(private)
Shadow_Undo :: struct {
	index: int,
	del:   bool,
	entry: Entry,
}

shadow_txn_begin :: proc(s: ^Shadow) {
	s.txn = true
	s.txn_len = len(s.pending)
	clear(&s.undo)
}

shadow_txn_end :: proc(s: ^Shadow) {
	s.txn = false
	clear(&s.undo)
}

shadow_txn_rollback :: proc(s: ^Shadow) {
	if !s.txn {
		return
	}
	for i := len(s.undo) - 1; i >= 0; i -= 1 {
		u := s.undo[i]
		s.pending[u.index].del = u.del
		s.pending[u.index].entry = u.entry
	}
	for i := len(s.pending) - 1; i >= s.txn_len; i -= 1 {
		delete(s.pending[i].path, s.allocator)
	}
	resize(&s.pending, s.txn_len)
	clear(&s.index)
	clear(&s.by_inode)
	for p, i in s.pending {
		if p.fresh {
			continue
		}
		s.index[p.path] = i
		if !p.del {
			s.by_inode[p.entry.inode] = i
		}
	}
	shadow_txn_end(s)
}

@(private = "file")
pending_clear :: proc(s: ^Shadow) {
	for p in s.pending {
		delete(p.path, s.allocator)
	}
	clear(&s.pending)
	versions_clear(s)
	clear(&s.index)
	clear(&s.by_inode)
	if cap(s.pending) > 4096 {
		delete(s.pending)
		s.pending = make([dynamic]Pending_Rec, s.allocator)
		delete(s.index)
		s.index = make(map[string]int, s.allocator)
		delete(s.by_inode)
		s.by_inode = make(map[fstree.Inode_Id]int, s.allocator)
	}
}

@(private = "file")
apply_rec :: proc(s: ^Shadow, rec: Rec, link := true) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	r := rec
	path, aerr := clone_string(r.path, context.temp_allocator)
	if aerr != nil {
		return .No_Memory
	}
	r.path = path
	h := path_hash(r.path)
	i, slot, found := find_path(s, r.path, h) or_return
	if found && slot.off >= r.off {
		if slot.off == r.off && !r.del {
			inode_set(s, r.entry.inode, r.off) or_return
		}
		return link_parent(s, r) if link else .None
	}
	prev_inode: Maybe(fstree.Inode_Id)
	prev_off := slot.off
	if found {
		old := read_live(s, slot.off, &s.scratch) or_return
		s.garbage += old.size
		if !old.del {
			s.live -= 1
			prev_inode = old.entry.inode
		}
	} else {
		slot = Path_Slot {
			hash = h,
		}
		s.used += 1
	}
	if r.del {
		s.garbage += r.size
	} else {
		s.live += 1
	}
	slot.off = r.off
	if r.linked {
		slot.link = r.off
	}
	write_path_slot(s, i, slot) or_return
	if link {
		link_parent(s, r) or_return
	}
	if old, ok := prev_inode.?; ok && (r.del || old != r.entry.inode) {
		inode_unset(s, old, prev_off) or_return
	}
	if !r.del {
		inode_set(s, r.entry.inode, r.off) or_return
	}
	return .None
}

@(private = "file")
link_parent :: proc(s: ^Shadow, r: Rec) -> Error {
	if !r.linked || len(r.path) == 0 {
		return .None
	}
	parent := path_parent(r.path)
	pi, pslot, pfound := find_path(s, parent, path_hash(parent)) or_return
	if !pfound || pslot.head >= r.off {
		return .None
	}
	pslot.head = r.off
	return write_path_slot(s, pi, pslot)
}

@(private = "file")
inode_set :: proc(s: ^Shadow, inode: fstree.Inode_Id, off: u64) -> Error {
	h := inode_hash(inode)
	mask := s.cap - 1
	i := h & mask
	free_at: i64 = -1
	for _ in 0 ..< s.cap {
		slot := read_inode_slot(s, i) or_return
		if slot.hash == 0 {
			break
		}
		if slot.hash == h {
			if slot.off == 0 {
				if free_at < 0 {
					free_at = i64(i)
				}
			} else {
				r, rerr := read_rec(s, slot.off, &s.probe)
				if rerr != .None && rerr != .Corrupt {
					return rerr
				}
				if rerr != .None || r.del || r.entry.inode == inode {
					return write_inode_slot(s, i, Inode_Slot{h, off})
				}
			}
		}
		i = (i + 1) & mask
	}
	if free_at >= 0 {
		return write_inode_slot(s, u64(free_at), Inode_Slot{h, off})
	}
	s.inode_used += 1
	return write_inode_slot(s, i, Inode_Slot{h, off})
}

@(private = "file")
inode_unset :: proc(s: ^Shadow, inode: fstree.Inode_Id, prev_off: u64) -> Error {
	h := inode_hash(inode)
	mask := s.cap - 1
	i := h & mask
	for _ in 0 ..< s.cap {
		slot := read_inode_slot(s, i) or_return
		if slot.hash == 0 {
			return .None
		}
		if slot.hash == h && slot.off != 0 {
			if slot.off == prev_off {
				return write_inode_slot(s, i, Inode_Slot{h, 0})
			}
			r, rerr := read_rec(s, slot.off, &s.probe)
			if rerr != .None && rerr != .Corrupt {
				return rerr
			}
			if rerr == .None && r.entry.inode == inode {
				return .None
			}
		}
		i = (i + 1) & mask
	}
	return .None
}

@(private = "file")
find_path :: proc(s: ^Shadow, path: string, h: u64) -> (index: u64, slot: Path_Slot, found: bool, err: Error) {
	if s.idx_fd < 0 || s.cap == 0 {
		return 0, {}, false, .Invalid
	}
	mask := s.cap - 1
	i := h & mask
	block: [SHADOW_BLOCK]u8
	scanned: u64
	bad := false
	step := u64(8)
	for scanned < s.cap {
		n := min(step, s.cap - i)
		step = SHADOW_BLOCK / SHADOW_PATH_SLOT
		buf := block[:n * SHADOW_PATH_SLOT]
		idx_read(s, buf, SHADOW_HEADER + i * SHADOW_PATH_SLOT) or_return
		for k in 0 ..< n {
			b := buf[k * SHADOW_PATH_SLOT:]
			sh := prim.get_u64le(b[0:8])
			if sh == 0 {
				s.damaged ||= bad
				return i + k, {}, false, .Corrupt if bad else .None
			}
			if sh == h {
				off := prim.get_u64le(b[8:16])
				r, rerr := read_rec(s, off, &s.probe)
				if rerr != .None && rerr != .Corrupt {
					return 0, {}, false, rerr
				}
				bad ||= rerr == .Corrupt
				if rerr == .None && r.path == path {
					s.probe_del = r.del
					sl := Path_Slot{sh, off, prim.get_u64le(b[16:24]), prim.get_u64le(b[24:32])}
					return i + k, sl, true, .None
				}
			}
		}
		scanned += n
		i = (i + n) & mask
	}
	return 0, {}, false, .Corrupt
}

@(private = "file")
read_inode_slot :: proc(s: ^Shadow, i: u64) -> (slot: Inode_Slot, err: Error) {
	b: [SHADOW_INODE_SLOT]u8
	idx_read(s, b[:], inode_base(s) + i * SHADOW_INODE_SLOT) or_return
	return Inode_Slot{prim.get_u64le(b[0:8]), prim.get_u64le(b[8:16])}, .None
}

@(private = "file")
write_inode_slot :: proc(s: ^Shadow, i: u64, slot: Inode_Slot) -> Error {
	b: [SHADOW_INODE_SLOT]u8
	prim.put_u64le(b[0:8], slot.hash)
	prim.put_u64le(b[8:16], slot.off)
	return idx_write(s, b[:], inode_base(s) + i * SHADOW_INODE_SLOT)
}

@(private = "file")
write_path_slot :: proc(s: ^Shadow, i: u64, slot: Path_Slot) -> Error {
	b: [SHADOW_PATH_SLOT]u8
	prim.put_u64le(b[0:8], slot.hash)
	prim.put_u64le(b[8:16], slot.off)
	prim.put_u64le(b[16:24], slot.head)
	prim.put_u64le(b[24:32], slot.link)
	return idx_write(s, b[:], SHADOW_HEADER + i * SHADOW_PATH_SLOT)
}

@(private = "file")
inode_base :: proc "contextless" (s: ^Shadow) -> u64 {
	return SHADOW_HEADER + s.cap * SHADOW_PATH_SLOT
}

@(private = "file")
path_hash :: proc(path: string) -> u64 {
	if len(path) == 0 {
		return 0x9e37_79b9_7f4a_7c15
	}
	h := xxhash.XXH3_64_with_seed(transmute([]u8)path, 0x3064_6273)
	return h if h != 0 else 1
}

@(private = "file")
inode_hash :: proc(id: fstree.Inode_Id) -> u64 {
	b: [12]u8
	prim.put_u32le(b[0:4], id.actor)
	prim.put_u64le(b[4:12], id.seq)
	h := xxhash.XXH3_64_with_seed(b[:], 0x696e_6f64)
	return h if h != 0 else 1
}

@(private = "file")
cap_for :: proc "contextless" (n: u64) -> u64 {
	c := SHADOW_MIN_CAP
	for c * 5 < n * 8 {
		c *= 2
	}
	return c
}

@(private = "file")
rec_check :: proc(body: []u8, off: u64) -> u32 {
	return u32(xxhash.XXH3_64_with_seed(body, off))
}

@(private = "file")
encode_rec :: proc(out: ^[dynamic]u8, off: u64, path: string, del: bool, e: Entry, ids: []fstree.Op_Id, linked: bool, sibling: u64, oid_size: int) -> int {
	start := len(out)
	resize(out, start + 8)
	w := prim.writer(out)
	prim.write_u8(&w, 2 if del else 1)
	prim.write_u8(&w, (1 if linked else 0) | (2 if !del && e.racy else 0))
	prim.write_str(&w, path)
	if !del {
		prim.write_uvarint(&w, u64(e.inode.actor))
		prim.write_uvarint(&w, e.inode.seq)
		prim.write_u8(&w, u8(e.kind))
		prim.write_ivarint(&w, e.stat.mtime_ns)
		prim.write_ivarint(&w, e.stat.ctime_ns)
		prim.write_ivarint(&w, e.stat.size)
		prim.write_uvarint(&w, e.stat.ino)
		prim.write_uvarint(&w, u64(e.stat.mode))
		oid := e.oid
		prim.write_raw(&w, oid[:oid_size])
		prim.write_uvarint(&w, u64(len(ids)))
		for id in ids {
			prim.write_uvarint(&w, u64(id.actor))
			prim.write_uvarint(&w, id.seq)
		}
	}
	if linked {
		prim.write_u64le(&w, sibling)
	}
	n := len(out) - start - 8
	if w.err != .None || n > SHADOW_MAX_RECORD {
		resize(out, start)
		return 0
	}
	prim.put_u32le(out[start:start + 4], u32(n))
	prim.put_u32le(out[start + 4:start + 8], rec_check(out[start + 8:], off))
	return n + 8
}

@(private = "file")
read_rec :: proc(s: ^Shadow, off: u64, buf: ^[dynamic]u8) -> (r: Rec, err: Error) {
	if off < SHADOW_LOG_HEADER || off + 8 > s.log_end {
		return {}, .Corrupt
	}
	want := min(u64(512), s.log_end - off)
	if len(buf) < int(want) {
		resize(buf, int(want))
	}
	got, rerr := prim.read_at(s.vfs, s.log_fd, buf[:want], i64(off))
	if rerr != .None {
		return {}, from_prim(rerr)
	}
	if u64(got) < 8 {
		return {}, .Corrupt
	}
	n := u64(prim.get_u32le(buf[0:4]))
	if n > SHADOW_MAX_RECORD || off + 8 + n > s.log_end {
		return {}, .Corrupt
	}
	if 8 + n > u64(got) {
		if len(buf) < int(8 + n) {
			resize(buf, int(8 + n))
		}
		got, rerr = prim.read_at(s.vfs, s.log_fd, buf[:8 + n], i64(off))
		if rerr != .None {
			return {}, from_prim(rerr)
		}
		if u64(got) != 8 + n {
			return {}, .Corrupt
		}
	}
	body := buf[8:][:n]
	if rec_check(body, off) != prim.get_u32le(buf[4:8]) {
		return {}, .Corrupt
	}
	r = decode_rec(body, s.oid_size, &s.ver_ids) or_return
	if r.ids > 0 {
		r.entry.ver = shadow_version_add(s, s.ver_ids[:]) or_return
	}
	r.off = off
	r.size = 8 + n
	return r, .None
}

@(private = "file")
read_live :: proc(s: ^Shadow, off: u64, buf: ^[dynamic]u8) -> (r: Rec, err: Error) {
	r, err = read_rec(s, off, buf)
	s.damaged ||= err == .Corrupt
	return
}

@(private = "file")
decode_rec :: proc(body: []u8, oid_size: int, ids: ^[dynamic]fstree.Op_Id) -> (r: Rec, err: Error) {
	rd := prim.reader(body)
	kind := prim.read_u8(&rd)
	flags := prim.read_u8(&rd)
	r.path = prim.read_str(&rd)
	switch kind {
	case 1:
	case 2:
		r.del = true
	case:
		return {}, .Corrupt
	}
	r.linked = flags & 1 != 0
	r.entry.racy = !r.del && flags & 2 != 0
	if !r.del {
		actor := prim.read_uvarint(&rd)
		if actor > u64(max(u32)) {
			return {}, .Corrupt
		}
		r.entry.inode.actor = u32(actor)
		r.entry.inode.seq = prim.read_uvarint(&rd)
		k := prim.read_u8(&rd)
		if k > u8(max(fstree.Kind)) {
			return {}, .Corrupt
		}
		r.entry.kind = fstree.Kind(k)
		r.entry.stat.mtime_ns = prim.read_ivarint(&rd)
		r.entry.stat.ctime_ns = prim.read_ivarint(&rd)
		r.entry.stat.size = prim.read_ivarint(&rd)
		r.entry.stat.ino = prim.read_uvarint(&rd)
		mode := prim.read_uvarint(&rd)
		if mode > u64(max(u32)) {
			return {}, .Corrupt
		}
		r.entry.stat.mode = u32(mode)
		prim.read_fixed(&rd, r.entry.oid[:oid_size])
		n := prim.read_uvarint(&rd)
		if n > SHADOW_VERSION_MAX {
			return {}, .Corrupt
		}
		if ids != nil {
			clear(ids)
		}
		for _ in 0 ..< n {
			ix := prim.read_uvarint(&rd)
			if ix > u64(max(u32)) || ids == nil {
				return {}, .Corrupt
			}
			append(ids, fstree.Op_Id{actor = u32(ix), seq = prim.read_uvarint(&rd)})
		}
		r.ids = n
	}
	if r.linked {
		r.sibling = prim.read_u64le(&rd)
	}
	if !prim.reader_ok(&rd) || !prim.reader_done(&rd) {
		return {}, .Corrupt
	}
	return r, .None
}

@(private = "file")
gen_path :: proc(dir: string, gen: u64, ext: string, allocator: runtime.Allocator) -> string {
	digits: [24]u8
	num := strconv.write_uint(digits[:], gen, 10)
	buf := make([]u8, len(dir) + len("/shadow.") + len(num) + 1 + len(ext), allocator)
	n := copy(buf, dir)
	n += copy(buf[n:], "/shadow.")
	n += copy(buf[n:], num)
	buf[n] = '.'
	copy(buf[n + 1:], ext)
	return string(buf)
}

@(private = "file")
read_gen :: proc(s: ^Shadow, dir: string) -> (gen: u64, have: bool, err: Error) {
	buf: prim.Path_Buf
	p, ok := path_join_buf(buf[:], dir, "shadow.gen")
	if !ok {
		return 0, false, .Name_Too_Long
	}
	fd, oerr := prim.open_file(s.vfs, p)
	if oerr == .Not_Found {
		return 0, false, .None
	}
	if oerr != .None {
		return 0, false, from_prim(oerr)
	}
	defer prim.close_file(s.vfs, fd)
	b: [16]u8
	n, rerr := prim.read_at(s.vfs, fd, b[:], 0)
	if rerr != .None {
		return 0, false, from_prim(rerr)
	}
	if n != 16 || u32(xxhash.XXH3_64_default(b[0:8])) != prim.get_u32le(b[8:12]) {
		return 0, false, .Corrupt
	}
	return prim.get_u64le(b[0:8]), true, .None
}

@(private = "file")
write_gen :: proc(s: ^Shadow, dir: string, gen: u64) -> Error {
	buf: prim.Path_Buf
	p, ok := path_join_buf(buf[:], dir, "shadow.gen")
	if !ok {
		return .Name_Too_Long
	}
	b: [16]u8
	prim.put_u64le(b[0:8], gen)
	prim.put_u32le(b[8:12], u32(xxhash.XXH3_64_default(b[0:8])))
	return from_prim(prim.replace_atomic(s.vfs, p, b[:]))
}

@(private = "file")
open_gen :: proc(s: ^Shadow) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log_path := gen_path(s.dir, s.gen, "log", context.temp_allocator)
	idx_path := gen_path(s.dir, s.gen, "idx", context.temp_allocator)
	fd, err := prim.open_file(s.vfs, log_path, {.Write}, 0o600)
	if err == .Not_Found {
		if s.mark.end != 0 {
			s.damaged = true
			return .None
		}
		prim.remove(s.vfs, idx_path)
		return create_files(s, SHADOW_MIN_CAP, Entry{inode = fstree.ROOT, kind = .Dir})
	}
	if err != .None {
		return from_prim(err)
	}
	size, serr := prim.file_size(s.vfs, fd)
	if serr != .None {
		prim.close_file(s.vfs, fd)
		return from_prim(serr)
	}
	if size < SHADOW_LOG_HEADER {
		prim.close_file(s.vfs, fd)
		if s.mark.end != 0 {
			s.damaged = true
			return .None
		}
		prim.remove(s.vfs, idx_path)
		return create_files(s, SHADOW_MIN_CAP, Entry{inode = fstree.ROOT, kind = .Dir})
	}
	s.log_fd = fd
	hdr: [SHADOW_LOG_HEADER]u8
	got, rerr := prim.read_at(s.vfs, fd, hdr[:], 0)
	if rerr != .None {
		return from_prim(rerr)
	}
	magic := prim.get_u64le(hdr[0:8])
	if got == SHADOW_LOG_HEADER && magic & SHADOW_FAMILY == SHADOW_MAGIC & SHADOW_FAMILY && magic > SHADOW_MAGIC {
		return .Newer
	}
	if got != SHADOW_LOG_HEADER || magic != SHADOW_MAGIC {
		if s.mark.end == 0 {
			return .Corrupt
		}
		prim.close_file(s.vfs, fd)
		s.log_fd = prim.INVALID_FD
		s.damaged = true
		return .None
	}
	if int(hdr[8]) != s.oid_size {
		return .Corrupt
	}
	s.log_end = u64(size)
	if s.damaged || s.mark.end != 0 && s.gen == s.mark.gen && s.log_end < s.mark.end {
		s.damaged = true
		return .None
	}
	ifd, ierr := prim.open_file(s.vfs, idx_path, {.Write}, 0o600)
	if ierr == .None {
		s.idx_fd = ifd
		clean, valid := load_header(s)
		if valid {
			if rerr := recover_tail(s, clean); rerr != .None {
				if s.damaged {
					return .None
				}
				s.idx_lost = true
				return rerr
			}
			return .None
		}
		prim.close_file(s.vfs, ifd)
		s.idx_fd = prim.INVALID_FD
	} else if ierr != .Not_Found {
		return from_prim(ierr)
	}
	if rerr := rebuild_index(s, SHADOW_MIN_CAP); rerr != .None {
		return .None if s.damaged else rerr
	}
	return from_prim(prim.datasync(s.vfs, s.log_fd))
}

@(private = "file")
create_files :: proc(s: ^Shadow, capacity: u64, root: Entry) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	log_path := gen_path(s.dir, s.gen, "log", context.temp_allocator)
	idx_path := gen_path(s.dir, s.gen, "idx", context.temp_allocator)
	hdr: [SHADOW_LOG_HEADER]u8
	prim.put_u64le(hdr[0:8], SHADOW_MAGIC)
	hdr[8] = u8(s.oid_size)
	from_prim(prim.replace_atomic(s.vfs, log_path, hdr[:])) or_return
	fd, oerr := prim.open_file(s.vfs, log_path, {.Write}, 0o600)
	if oerr != .None {
		return from_prim(oerr)
	}
	s.log_fd = fd
	s.log_end = SHADOW_LOG_HEADER
	ifd, ierr := prim.open_file(s.vfs, idx_path, {.Write, .Create, .Truncate}, 0o600)
	if ierr != .None {
		return from_prim(ierr)
	}
	s.idx_fd = ifd
	s.cap = capacity
	s.used = 0
	s.inode_used = 0
	s.live = 0
	s.garbage = 0
	s.covered = SHADOW_LOG_HEADER
	zero_fill(s, ifd, i64(SHADOW_HEADER + capacity * (SHADOW_PATH_SLOT + SHADOW_INODE_SLOT))) or_return
	write_header(s, false)
	from_prim(prim.sync_dir(s.vfs, s.dir)) or_return
	if s.gen == 0 {
		write_gen(s, s.dir, 0) or_return
	}
	shadow_put(s, "", root) or_return
	return shadow_persist(s)
}

@(private = "file")
load_header :: proc(s: ^Shadow) -> (clean: bool, valid: bool) {
	b: [96]u8
	got, err := prim.read_at(s.vfs, s.idx_fd, b[:], 0)
	if err != .None || got != len(b) {
		return
	}
	if prim.get_u64le(b[0:8]) != SHADOW_IDX_MAGIC || xxhash.XXH3_64_default(b[0:88]) != prim.get_u64le(b[88:96]) {
		return
	}
	s.cap = prim.get_u64le(b[8:16])
	s.used = prim.get_u64le(b[16:24])
	s.inode_used = prim.get_u64le(b[24:32])
	s.covered = prim.get_u64le(b[32:40])
	s.live = prim.get_u64le(b[40:48])
	s.garbage = prim.get_u64le(b[48:56])
	clean = prim.get_u64le(b[56:64]) == 1
	if s.cap < SHADOW_MIN_CAP || s.cap & (s.cap - 1) != 0 || s.cap > 1 << 40 || s.covered < SHADOW_LOG_HEADER || s.covered > s.log_end {
		return false, false
	}
	size, serr := prim.file_size(s.vfs, s.idx_fd)
	if serr != .None || u64(size) < SHADOW_HEADER + s.cap * (SHADOW_PATH_SLOT + SHADOW_INODE_SLOT) {
		return false, false
	}
	return clean, true
}

@(private = "file")
write_header :: proc(s: ^Shadow, clean: bool) {
	b: [96]u8
	prim.put_u64le(b[0:8], SHADOW_IDX_MAGIC)
	prim.put_u64le(b[8:16], s.cap)
	prim.put_u64le(b[16:24], s.used)
	prim.put_u64le(b[24:32], s.inode_used)
	prim.put_u64le(b[32:40], s.covered)
	prim.put_u64le(b[40:48], s.live)
	prim.put_u64le(b[48:56], s.garbage)
	prim.put_u64le(b[56:64], 1 if clean else 0)
	prim.put_u64le(b[88:96], xxhash.XXH3_64_default(b[0:88]))
	prim.write_at(s.vfs, s.idx_fd, b[:], 0)
}

@(private = "file")
checkpoint :: proc(s: ^Shadow) -> Error {
	if s.idx_lost {
		return .None
	}
	if err := from_prim(prim.datasync(s.vfs, s.idx_fd)); err != .None {
		s.idx_lost = true
		return err
	}
	s.covered = s.log_end
	write_header(s, false)
	return .None
}

@(private = "file")
recover_tail :: proc(s: ^Shadow, clean: bool) -> Error {
	if clean && s.covered == s.log_end {
		write_header(s, false)
		return .None
	}
	end := s.log_end
	off := s.covered
	idx_map(s)
	defer idx_unmap(s)
	for off < end {
		r, err := read_rec(s, off, &s.scratch)
		if err == .Corrupt {
			if off < s.mark.end {
				s.damaged = true
				return .Corrupt
			}
			break
		}
		if err != .None {
			return err
		}
		apply_rec(s, r) or_return
		off += r.size
	}
	if off > s.covered {
		from_prim(prim.datasync(s.vfs, s.log_fd)) or_return
	}
	if off < end {
		from_prim(prim.truncate(s.vfs, s.log_fd, i64(off))) or_return
		from_prim(prim.datasync(s.vfs, s.log_fd)) or_return
		s.log_end = off
	}
	recount(s) or_return
	idx_unmap(s)
	if s.used * 8 > s.cap * 7 {
		return rebuild_index(s, cap_for(s.used))
	}
	return checkpoint(s)
}

@(private = "file")
recount :: proc(s: ^Shadow) -> Error {
	block: [SHADOW_BLOCK * 16]u8
	used: u64
	pos: u64
	total := s.cap * SHADOW_PATH_SLOT
	for pos < total {
		n := min(u64(len(block)), total - pos)
		got, rerr := prim.read_at(s.vfs, s.idx_fd, block[:n], i64(SHADOW_HEADER + pos))
		if rerr != .None || u64(got) != n {
			return .Corrupt if rerr == .None else from_prim(rerr)
		}
		for k: u64 = 0; k < n; k += SHADOW_PATH_SLOT {
			if prim.get_u64le(block[k:k + 8]) != 0 {
				used += 1
			}
		}
		pos += n
	}
	inode_used: u64
	pos = 0
	total = s.cap * SHADOW_INODE_SLOT
	for pos < total {
		n := min(u64(len(block)), total - pos)
		got, rerr := prim.read_at(s.vfs, s.idx_fd, block[:n], i64(inode_base(s) + pos))
		if rerr != .None || u64(got) != n {
			return .Corrupt if rerr == .None else from_prim(rerr)
		}
		for k: u64 = 0; k < n; k += SHADOW_INODE_SLOT {
			if prim.get_u64le(block[k:k + 8]) != 0 {
				inode_used += 1
			}
		}
		pos += n
	}
	s.used = used
	s.inode_used = inode_used
	live: u64
	pos = 0
	total = s.cap * SHADOW_PATH_SLOT
	for pos < total {
		n := min(u64(len(block)), total - pos)
		got, rerr := prim.read_at(s.vfs, s.idx_fd, block[:n], i64(SHADOW_HEADER + pos))
		if rerr != .None || u64(got) != n {
			return .Corrupt if rerr == .None else from_prim(rerr)
		}
		for k: u64 = 0; k < n; k += SHADOW_PATH_SLOT {
			if prim.get_u64le(block[k:k + 8]) == 0 {
				continue
			}
			r, err := read_rec(s, prim.get_u64le(block[k + 8:k + 16]), &s.scratch)
			if err != .None && err != .Corrupt {
				return err
			}
			if err == .None && !r.del {
				live += 1
			}
		}
		pos += n
	}
	s.live = live
	return .None
}

@(private = "file")
rebuild_index :: proc(s: ^Shadow, capacity: u64) -> Error {
	c := max(capacity, SHADOW_MIN_CAP)
	for {
		full, err := rebuild_into(s, c)
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
rebuild_into :: proc(s: ^Shadow, capacity: u64) -> (full: bool, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	idx_path := gen_path(s.dir, s.gen, "idx", context.temp_allocator)
	tmp_path := gen_path(s.dir, s.gen, "idx.tmp", context.temp_allocator)
	ifd, oerr := prim.open_file(s.vfs, tmp_path, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return false, from_prim(oerr)
	}
	saved := s^
	s.idx_fd = ifd
	s.cap = capacity
	s.used = 0
	s.inode_used = 0
	s.live = 0
	s.garbage = 0
	ok := false
	defer if !ok {
		idx_unmap(s)
		prim.close_file(s.vfs, ifd)
		prim.remove(s.vfs, tmp_path)
		s.idx_fd = saved.idx_fd
		s.cap = saved.cap
		s.used = saved.used
		s.inode_used = saved.inode_used
		s.live = saved.live
		s.garbage = saved.garbage
		s.covered = saved.covered
	}
	zero_fill(s, ifd, i64(SHADOW_HEADER + capacity * (SHADOW_PATH_SLOT + SHADOW_INODE_SLOT))) or_return
	idx_map(s)
	end := s.log_end
	off := u64(SHADOW_LOG_HEADER)
	for off < end {
		r, rerr := read_rec(s, off, &s.scratch)
		if rerr == .Corrupt {
			if off < s.mark.end {
				s.damaged = true
				return false, .Corrupt
			}
			break
		}
		if rerr != .None {
			return false, rerr
		}
		apply_rec(s, r) or_return
		off += r.size
		if s.used * 8 > s.cap * 7 {
			return true, .None
		}
	}
	if off < end {
		from_prim(prim.truncate(s.vfs, s.log_fd, i64(off))) or_return
		from_prim(prim.datasync(s.vfs, s.log_fd)) or_return
		s.log_end = off
	}
	idx_unmap(s)
	from_prim(prim.datasync(s.vfs, ifd)) or_return
	s.covered = s.log_end
	write_header(s, false)
	from_prim(prim.rename(s.vfs, tmp_path, idx_path)) or_return
	ok = true
	if saved.idx_fd >= 0 {
		prim.close_file(s.vfs, saved.idx_fd)
	}
	return false, .None
}

@(private = "file")
idx_read :: proc(s: ^Shadow, buf: []u8, off: u64) -> Error {
	if s.mapped != nil {
		if off + u64(len(buf)) > u64(len(s.mapped)) {
			return .Corrupt
		}
		copy(buf, s.mapped[off:])
		return .None
	}
	got, err := prim.read_at(s.vfs, s.idx_fd, buf, i64(off))
	if err != .None {
		return from_prim(err)
	}
	return .None if got == len(buf) else .Corrupt
}

@(private = "file")
idx_write :: proc(s: ^Shadow, data: []u8, off: u64) -> Error {
	if s.mapped != nil {
		if off + u64(len(data)) > u64(len(s.mapped)) {
			return .Corrupt
		}
		copy(s.mapped[off:], data)
		return .None
	}
	return from_prim(prim.write_at(s.vfs, s.idx_fd, data, i64(off)))
}

@(private = "file")
idx_map :: proc(s: ^Shadow) {
	if s.mapped != nil || s.idx_fd < 0 || s.vfs.procs != prim.os_vfs().procs {
		return
	}
	size := SHADOW_HEADER + s.cap * (SHADOW_PATH_SLOT + SHADOW_INODE_SLOT)
	if s.map_lock != nil {
		sync.mutex_lock(s.map_lock)
	}
	p, merr := prim.map_file(s.idx_fd, int(size), true)
	if merr != .None {
		if s.map_lock != nil {
			sync.mutex_unlock(s.map_lock)
		}
		return
	}
	s.mapped = p
}

@(private = "file")
idx_unmap :: proc(s: ^Shadow) {
	if s.mapped == nil {
		return
	}
	prim.unmap_file(s.mapped)
	s.mapped = nil
	if s.map_lock != nil {
		sync.mutex_unlock(s.map_lock)
	}
}

@(private = "file")
zero_fill :: proc(s: ^Shadow, fd: prim.Fd, size: i64) -> Error {
	from_prim(prim.truncate(s.vfs, fd, 0)) or_return
	zeros := make([]u8, 1 << 20, context.temp_allocator)
	pos: i64
	for pos < size {
		n := min(i64(len(zeros)), size - pos)
		from_prim(prim.write_at(s.vfs, fd, zeros[:n], pos)) or_return
		pos += n
	}
	return .None
}

path_depth :: proc "contextless" (p: string) -> int {
	if len(p) == 0 {
		return 0
	}
	n := 1
	for i in 0 ..< len(p) {
		if p[i] == '/' {
			n += 1
		}
	}
	return n
}

clone_string :: proc(s: string, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	buf, err := make([]u8, len(s), allocator)
	if err != nil {
		return "", err
	}
	copy(buf, s)
	return string(buf), nil
}

shadow_end :: proc "contextless" (s: ^Shadow) -> (gen, end: u64) {
	return s.gen, s.log_end
}

shadow_rollback :: proc(s: ^Shadow, end: u64) -> Error {
	if s.log_fd < 0 || end < SHADOW_LOG_HEADER || end >= s.log_end {
		return .None
	}
	s.log_end = end
	rebuild_index(s, s.cap) or_return
	return shadow_compact(s)
}

shadow_wants_compact :: proc "contextless" (s: ^Shadow) -> bool {
	return s.garbage > 4 << 20 && s.garbage > s.log_end / 2
}
