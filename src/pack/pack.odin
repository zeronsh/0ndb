package pack

import "base:runtime"
import "core:hash/xxhash"
import "core:strconv"
import "../prim"

Error :: prim.Error

Options :: struct {
	promote_size:   i64,
	container_size: i64,
	mem_budget:     int,
	log_window:     i64,
	spill:          int,
	merge_fanout:   int,
	max_runs:       int,
	compact_ratio:  f64,
	roll_min:       i64,
	filter_budget:  int,
	clock:          prim.Clock,
	wake:           proc(data: rawptr),
	wake_data:      rawptr,
	before_commit:  proc(data: rawptr) -> Error,
	before_data:    rawptr,
	deferred_sync:  bool,
	worker:         Worker_Hook,
}

Worker_Hook :: struct {
	data:   rawptr,
	submit: proc(data: rawptr),
}

DEFAULT_OPTIONS :: Options {
	promote_size   = 256 * 1024,
	container_size = 64 * 1024 * 1024,
	mem_budget     = 2 * 1024 * 1024,
	log_window     = 64 * 1024 * 1024,
	spill          = 256 * 1024,
	merge_fanout   = 16,
	max_runs       = 48,
	compact_ratio  = 0.5,
	filter_budget  = 16 * 1024 * 1024,
}

Stats :: struct {
	commits:       u64,
	fsyncs:        u64,
	flushes:       u64,
	merges:        u64,
	merge_bytes:   u64,
	log_bytes:     u64,
	run_reads:     u64,
	cache_hits:    u64,
	filter_reads:  u64,
	index_written: u64,
	index_size:    u64,
	filter_skips:  u64,
	filter_bytes:  int,
	findex_bytes:  int,
	zeroed_bytes:  u64,
	compact_moved: u64,
	compact_conts: u64,
	promotions:    u64,
	replayed:      u64,
	runs:          int,
	containers:    int,
	mem_bytes:     int,
	open_handles:  int,
}

@(private)
Cont :: struct {
	id:      u32,
	fd:      prim.Fd,
	size:    i64,
	live:    i64,
	ck_live: i64,
	dirty:   bool,
	lent:    bool,
	busy:    bool,
	used:    u64,
}

@(private)
Zero :: struct {
	phys:   Phys,
	need:   u64,
	urgent: bool,
}

@(private)
Open_Inode :: struct {
	inum:     u64,
	refs:     int,
	ino:      Inode,
	real_fd:  prim.Fd,
	locked:   int,
	unlinked: bool,
	dirty:    bool,
	pinned:   int,
	ext_base: i64,
	img:      ^Image,
}

@(private)
Handle :: struct {
	used:  bool,
	write: bool,
	dir:   bool,
	oi:    ^Open_Inode,
	inum:  u64,
	stage: ^Stage,
	sized: bool,
}

@(private)
Pending_Unlink :: struct {
	inum: u64,
	need: u64,
}

Pack :: struct {
	base:          prim.Vfs,
	tombs:         u64,
	root:          string,
	opts:          Options,
	allocator:     runtime.Allocator,
	lock_fd:       prim.Fd,
	super_fd:      prim.Fd,
	gen:           u64,
	next_ino:      u64,
	next_cont:     u32,
	next_run:      u32,
	ck_cont:       u32,
	ck_off:        i64,
	ck_seq:        u64,
	conts:         [dynamic]Cont,
	active:        int,
	buf:           [dynamic]u8,
	buf_base:      i64,
	group_start:   i64,
	last_cont:     u32,
	last_start:    i64,
	seq:           u64,
	durable_seq:   u64,
	nrec:          int,
	hh:            u64,
	dh:            u64,
	force:         bool,
	dirty:         [dynamic]u32,
	zeros:         [dynamic]Zero,
	unlinks:       [dynamic]Pending_Unlink,
	ext_dirty:     [dynamic]u64,
	queued:        [dynamic]Commit_Hook,
	graveyard:     [dynamic]prim.Fd,
	fl:            Inflight,
	waiters:       [dynamic]Waiter,
	worker:        ^Worker,
	hook_ran:      bool,
	hook_err:      Error,
	log_since_ck:  i64,
	mem:           Mem,
	runs:          [dynamic]^Run,
	merge:         ^Merge,
	compact:       Compact,
	compacting:    u32,
	compact_resume: i64,
	horizon:       u32,
	handles:       [dynamic]Handle,
	free_handles:  [dynamic]int,
	open_inodes:   map[u64]^Open_Inode,
	pend:          map[u64]^Pend,
	dcache:        [DCACHE]Dcache_Entry,
	poisoned:      bool,
	recovering:    bool,
	unclean:       bool,
	hold_unclean:  bool,
	batch:         int,
	stats:         Stats,
	filters_cold:  bool,
	dirsync_pending: bool,
	pressure:      bool,
	want_flush:    bool,
	closing:       bool,
	reclaiming:    bool,
	op_depth:      int,
	imgs:          [dynamic]^Open_Inode,
	img_bytes:     int,
	img_dirty:     int,
	reclaimed:     bool,
	cscan:         [dynamic]Scan,
	bcache:        []Bc_Entry,
	tick:          u64,
	scratch:       [dynamic]u8,
	vbuf:          [dynamic]u8,
	work:          [dynamic]u8,
}

@(private)
DCACHE :: 64
@(private)
BCACHE :: 128

@(private)
Bc_Entry :: struct {
	run:   u32,
	blk:   u32,
	valid: bool,
	data:  [BLOCK]u8,
}

@(private)
Dcache_Entry :: struct {
	parent: u64,
	ino:    u64,
	nlen:   int,
	name:   [MAX_NAME]u8,
}

@(private)
SUPER_SLOT :: 64 * 1024
@(private)
SUPER_MAGIC :: u64(0x7265_7075_736b_6370)
@(private)
CONT_MAGIC :: u64(0x746e_6f63_6b63_6170)
CONT_HDR :: 64
@(private)
VERSION :: u32(5)
ROOT_INO :: u64(1)

@(private)
K_DIR :: u8('D')
@(private)
K_INODE :: u8('I')
@(private)
K_ORPHAN :: u8('O')
@(private)
K_STALE :: u8('S')

@(private)
Erase :: struct {
	on:  bool,
	lo:  i64,
	hi:  i64,
}

@(private)
STALE_KEY :: 29

@(private)
STALE_SPAN :: i64(1) << 20

@(private)
_skey :: proc "contextless" (buf: []u8, inum: u64, foff: i64, cont: u32, off: i64) -> []u8 {
	buf[0] = K_STALE
	_put_be64(buf[1:9], inum)
	_put_be64(buf[9:17], u64(foff))
	buf[17] = u8(cont >> 24)
	buf[18] = u8(cont >> 16)
	buf[19] = u8(cont >> 8)
	buf[20] = u8(cont)
	_put_be64(buf[21:29], u64(off))
	return buf[:STALE_KEY]
}

@(private)
_skey_parse :: proc "contextless" (key: []u8) -> (foff: i64, cont: u32, off: i64) {
	foff = i64(_get_be64(key[9:17]))
	cont = u32(key[17]) << 24 | u32(key[18]) << 16 | u32(key[19]) << 8 | u32(key[20])
	off = i64(_get_be64(key[21:29]))
	return
}

@(private)
_stale_put :: proc(p: ^Pack, inum: u64, ph: Phys) -> Error {
	for at := i64(0); at < ph.len; at += STALE_SPAN {
		n := min(STALE_SPAN, ph.len - at)
		sb: [STALE_KEY]u8
		vb: [10]u8
		vn := prim.put_uvarint(vb[:], u64(n))
		_put(p, _skey(sb[:], inum, ph.foff + at, ph.cont, ph.off + at), vb[:vn], false) or_return
	}
	return .None
}

@(private)
_stale_prune :: proc(p: ^Pack, inum: u64, foff, ln: i64, cont: u32, off: i64) -> Error {
	klo: [STALE_KEY]u8
	khi: [STALE_KEY]u8
	_skey(klo[:], inum, foff, 0, 0)
	_skey(khi[:], inum, foff + ln, 0, 0)
	it: Merge_Iter
	if e := _miter_init(&it, p, klo[:17], khi[:17]); e != .None {
		_miter_destroy(&it)
		return e
	}
	dead := make([dynamic][STALE_KEY]u8, context.temp_allocator)
	for {
		key, _, ok := _miter_next(&it)
		if !ok {
			break
		}
		if len(key) != STALE_KEY {
			continue
		}
		_, c, o := _skey_parse(key)
		if c == cont && o >= off && o < off + ln {
			k: [STALE_KEY]u8
			copy(k[:], key)
			append(&dead, k)
		}
	}
	err := it.err
	_miter_destroy(&it)
	if err != .None {
		return err
	}
	for &k in dead {
		_put(p, k[:], nil, true) or_return
	}
	return .None
}

@(private)
_perr :: #force_inline proc "contextless" (e: prim.Error) -> Error {
	return e
}

@(private)
_dkey :: proc "contextless" (buf: []u8, parent: u64, name: string) -> []u8 {
	buf[0] = K_DIR
	_put_be64(buf[1:9], parent)
	n := copy(buf[9:], name)
	return buf[:9 + n]
}

@(private)
_ikey :: proc "contextless" (buf: []u8, kind: u8, inum: u64) -> []u8 {
	buf[0] = kind
	_put_be64(buf[1:9], inum)
	return buf[:9]
}

@(private)
_put_be64 :: proc "contextless" (b: []u8, v: u64) {
	for i in 0 ..< 8 {
		b[i] = u8(v >> (56 - 8 * uint(i)))
	}
}

@(private)
_get_be64 :: proc "contextless" (b: []u8) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v = v << 8 | u64(b[i])
	}
	return v
}

@(private)
_name :: proc(buf: []u8, prefix: u8, id: u64, width: int) -> string {
	buf[0] = prefix
	digits := "0123456789abcdef"
	for i in 0 ..< width {
		buf[width - i] = digits[(id >> (4 * uint(i))) & 0xf]
	}
	return string(buf[:width + 1])
}

@(private)
_phys_path :: proc(p: ^Pack, buf: ^prim.Path_Buf, prefix: u8, id: u64) -> string {
	n := copy(buf[:], p.root)
	buf[n] = '/'
	n += 1
	width := 16 if prefix == 'x' else 8
	nm := _name(buf[n:], prefix, id, width)
	return string(buf[:n + len(nm)])
}

@(private)
_parse_phys_name :: proc(name: string) -> (prefix: u8, id: u64, ok: bool) {
	if len(name) != 9 && len(name) != 17 {
		return
	}
	prefix = name[0]
	width := 16 if prefix == 'x' else 8
	if len(name) != width + 1 || (prefix != 'c' && prefix != 'r' && prefix != 'x') {
		return
	}
	v, vok := strconv.parse_u64_of_base(name[1:], 16)
	if !vok {
		return
	}
	return prefix, v, true
}

@(private)
_sync :: proc(p: ^Pack, fd: prim.Fd) -> Error {
	p.stats.fsyncs += 1
	return prim.datasync(p.base, fd)
}

@(private)
_sync_root :: proc(p: ^Pack) -> Error {
	p.stats.fsyncs += 1
	return prim.sync_dir(p.base, p.root)
}

@(private)
_poison :: proc(p: ^Pack, e: Error) -> Error {
	p.poisoned = true
	return e if e != .None else .Io
}

@(private)
_cont_index :: proc "contextless" (p: ^Pack, id: u32) -> int {
	lo, hi := 0, len(p.conts)
	for lo < hi {
		mid := (lo + hi) / 2
		if p.conts[mid].id < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(p.conts) && p.conts[lo].id == id {
		return lo
	}
	return -1
}

@(private)
MAX_OPEN_CONTS :: 32

@(private)
_cont_fd :: proc(p: ^Pack, id: u32) -> (prim.Fd, Error) {
	i := _cont_index(p, id)
	if i < 0 {
		return prim.INVALID_FD, .Not_Found
	}
	c := &p.conts[i]
	p.tick += 1
	if c.fd >= 0 {
		c.used = p.tick
		return c.fd, .None
	}
	open := 0
	victim := -1
	for &o, k in p.conts {
		if o.fd >= 0 {
			open += 1
			if k != p.active && !o.dirty && !o.lent && !o.busy && (victim < 0 || o.used < p.conts[victim].used) {
				victim = k
			}
		}
	}
	if open >= MAX_OPEN_CONTS && victim >= 0 {
		prim.close_file(p.base, p.conts[victim].fd)
		p.conts[victim].fd = prim.INVALID_FD
	}
	pb: prim.Path_Buf
	fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'c', u64(id)), {.Write})
	if err != .None {
		return prim.INVALID_FD, err
	}
	c.fd = fd
	c.used = p.tick
	return fd, .None
}

@(private)
_live_add :: proc "contextless" (p: ^Pack, ph: Phys, sign: i64) {
	i := _cont_index(p, ph.cont)
	if i >= 0 {
		p.conts[i].live += sign * ph.len
	}
}

@(private)
_get :: proc(p: ^Pack, key: []u8, out: ^[dynamic]u8) -> (found: bool, err: Error) {
	if r, ok := _mem_get(&p.mem, key); ok {
		if r.flags & MEM_TOMB != 0 {
			return false, .None
		}
		clear(out)
		append(out, ..r.val)
		return true, .None
	}
	if p.fl.imm != nil {
		if r, ok := _mem_get(p.fl.imm, key); ok {
			if r.flags & MEM_TOMB != 0 {
				return false, .None
			}
			clear(out)
			append(out, ..r.val)
			return true, .None
		}
	}
	if p.filters_cold {
		p.filters_cold = false
		_filters_rebalance(p) or_return
	}
	for i := len(p.runs) - 1; i >= 0; i -= 1 {
		maybe := _run_may_contain(p, p.runs[i], key) or_return
		if !maybe {
			p.stats.filter_skips += 1
			continue
		}
		f, tomb := _run_get(p, p.runs[i], key, out) or_return
		if f {
			return !tomb, .None
		}
	}
	return false, .None
}

@(private)
_put :: proc(p: ^Pack, key: []u8, val: []u8, tomb: bool) -> Error {
	flags := MEM_TOMB if tomb else 0
	if tomb {
		p.tombs += 1
	}
	if !p.recovering {
		flags |= MEM_DIRTY
	}
	off, ok := _mem_put(&p.mem, key, val, flags)
	if !ok {
		return .No_Memory
	}
	if !p.recovering {
		append(&p.dirty, off)
	}
	return .None
}

@(private)
_inode_load :: proc(p: ^Pack, inum: u64, ino: ^Inode) -> (found: bool, err: Error) {
	if oi, ok := p.open_inodes[inum]; ok {
		if oi.img != nil {
			_img_settle(p, oi) or_return
		}
		ino^ = oi.ino
		return true, .None
	}
	if inum == ROOT_INO {
		ino^ = {}
		ino.kind = .Dir
		ino.mode = 0o040755
		return true, .None
	}
	kb: [16]u8
	f := _get(p, _ikey(kb[:], K_INODE, inum), &p.vbuf) or_return
	if !f {
		return false, .None
	}
	if !_inode_decode(p.vbuf[:], ino) {
		return false, .Io
	}
	return true, .None
}

@(private)
_range_seq :: proc "contextless" (p: ^Pack, ph: Phys) -> u64 {
	if p.active >= 0 && ph.cont == p.conts[p.active].id && ph.off >= p.group_start {
		return p.seq
	}
	if p.fl.on && ph.cont == p.fl.cont && ph.off >= p.fl.start {
		return p.fl.seq
	}
	if ph.cont == p.last_cont && ph.off >= p.last_start {
		return p.durable_seq
	}
	return 0
}

@(private)
_defer_zero :: proc(p: ^Pack, ph: Phys, urgent: bool) {
	if ph.len <= 0 {
		return
	}
	if p.compacting != 0 && ph.cont == p.compacting && !p.recovering {
		return
	}
	need: u64
	if !p.recovering {
		need = max(p.seq, _range_seq(p, ph) + 1)
	}
	append(&p.zeros, Zero{phys = ph, need = need, urgent = urgent})
}

@(private)
_inode_store :: proc(p: ^Pack, inum: u64, old: ^Inode, new: ^Inode, erase := Erase{}) -> Error {
	olds, news, removed, added: Phys_List
	if old != nil {
		_phys_of(old, &olds)
	}
	if new != nil {
		_phys_of(new, &news)
	}
	_phys_diff(olds.a[:olds.n], news.a[:news.n], &removed)
	_phys_diff(news.a[:news.n], olds.a[:olds.n], &added)
	for ph in added.a[:added.n] {
		_live_add(p, ph, 1)
	}
	destroy := new == nil
	stale := old != nil && old.stale
	for ph in removed.a[:removed.n] {
		_live_add(p, ph, -1)
		if destroy || (erase.on && ph.foff < erase.hi && ph.foff + ph.len > erase.lo) {
			_defer_zero(p, ph, erase.on && !destroy)
			continue
		}
		if p.compacting != 0 && ph.cont == p.compacting {
			continue
		}
		_stale_put(p, inum, ph) or_return
		stale = true
	}
	if erase.on && !destroy {
		for &z in p.zeros {
			z.urgent = true
		}
	}
	if erase.on && !destroy && p.compacting != 0 {
		append(&p.cscan, Scan{inum = inum, lo = erase.lo, hi = erase.hi})
	}
	if stale && (destroy || erase.on) {
		lo := erase.lo if !destroy else 0
		hi := erase.hi if !destroy else max(i64)
		_erase_stale(p, inum, lo, hi, !destroy) or_return
	}
	kb: [16]u8
	key := _ikey(kb[:], K_INODE, inum)
	if destroy {
		if oi, ok := p.open_inodes[inum]; ok {
			oi.ino.kind = .None
		}
		return _put(p, key, nil, true)
	}
	if stale && !new.stale {
		new.stale = true
	}
	if !_inode_encode(new, &p.scratch) {
		return .No_Memory
	}
	if oi, ok := p.open_inodes[inum]; ok && &oi.ino != new {
		oi.ino = new^
	}
	return _put(p, key, p.scratch[:], false)
}

@(private)
_erase_stale :: proc(p: ^Pack, inum: u64, lo, hi: i64, urgent: bool) -> Error {
	klo: [STALE_KEY]u8
	khi: [STALE_KEY]u8
	_skey(klo[:], inum, max(lo - STALE_SPAN + 1, 0), 0, 0)
	if hi < max(i64) {
		_skey(khi[:], inum, hi, 0, 0)
	} else {
		_skey(khi[:], inum + 1, 0, 0, 0)
	}
	it: Merge_Iter
	if e := _miter_init(&it, p, klo[:17], khi[:17]); e != .None {
		_miter_destroy(&it)
		return e
	}
	Cut :: struct {
		key:  [STALE_KEY]u8,
		cont: u32,
		off:  i64,
		foff: i64,
		end:  i64,
		a:    i64,
		b:    i64,
	}
	cuts := make([dynamic]Cut, context.temp_allocator)
	for {
		key, val, ok := _miter_next(&it)
		if !ok {
			break
		}
		if len(key) != STALE_KEY {
			continue
		}
		ln, n1 := prim.get_uvarint(val)
		if n1 <= 0 {
			continue
		}
		foff, cont, off := _skey_parse(key)
		if foff >= hi || foff + i64(ln) <= lo {
			continue
		}
		c := Cut{cont = cont, off = off, foff = foff, end = foff + i64(ln)}
		c.a = max(lo, c.foff)
		c.b = min(hi, c.end)
		copy(c.key[:], key)
		_defer_zero(p, Phys{cont = cont, off = off + (c.a - c.foff), len = c.b - c.a, foff = c.a}, urgent)
		append(&cuts, c)
	}
	err := it.err
	_miter_destroy(&it)
	if err != .None {
		return err
	}
	for &c in cuts {
		if c.a > c.foff {
			_put(p, c.key[:], _stale_val(c.a - c.foff), false) or_return
		} else {
			_put(p, c.key[:], nil, true) or_return
		}
		if c.b < c.end {
			sb: [STALE_KEY]u8
			_put(p, _skey(sb[:], inum, c.b, c.cont, c.off + (c.b - c.foff)), _stale_val(c.end - c.b), false) or_return
		}
	}
	return .None
}

@(private)
_stale_val :: proc(ln: i64) -> []u8 {
	vb := make([]u8, 10, context.temp_allocator)
	n := prim.put_uvarint(vb, u64(ln))
	return vb[:n]
}

@(private)
_super_encode :: proc(p: ^Pack, out: ^[dynamic]u8) -> bool {
	snap: Snap
	_snap_take(p, &snap)
	defer _snap_free(&snap)
	return _snap_encode(&snap, out)
}

@(private)
Super :: struct {
	version:   u32,
	gen:       u64,
	ck_cont:   u32,
	ck_off:    i64,
	ck_seq:    u64,
	next_ino:  u64,
	next_cont: u32,
	next_run:  u32,
	compacting: u32,
	cpos:      i64,
	clean:     bool,
	runs:      [dynamic]Run,
	lives:     [dynamic]Cont,
}

@(private)
_super_decode :: proc(b: []u8, s: ^Super) -> bool {
	if len(b) < 12 {
		return false
	}
	n := int(prim.get_u32le(b[0:4]))
	if n < 12 || n > len(b) {
		return false
	}
	if xxhash.XXH3_64_with_seed(b[12:n], SUPER_MAGIC) != prim.get_u64le(b[4:12]) {
		return false
	}
	r := prim.reader(b[12:n])
	if prim.read_u64le(&r) != SUPER_MAGIC {
		return false
	}
	s.version = prim.read_u32le(&r)
	if s.version != VERSION {
		return true
	}
	s.gen = prim.read_u64le(&r)
	s.ck_cont = prim.read_u32le(&r)
	s.ck_off = i64(prim.read_u64le(&r))
	s.ck_seq = prim.read_u64le(&r)
	s.next_ino = prim.read_u64le(&r)
	s.next_cont = prim.read_u32le(&r)
	s.next_run = prim.read_u32le(&r)
	s.compacting = prim.read_u32le(&r)
	s.cpos = i64(prim.read_u64le(&r))
	s.clean = prim.read_u8(&r) == 1
	nr := prim.read_uvarint(&r)
	if r.err != .None || nr > 4096 {
		return false
	}
	clear(&s.runs)
	for _ in 0 ..< nr {
		run := Run {
			fd = prim.INVALID_FD,
		}
		run.id = prim.read_u32le(&r)
		run.level = prim.read_u8(&r)
		run.depth = prim.read_u8(&r)
		run.root = prim.read_u32le(&r)
		run.nblocks = prim.read_u32le(&r)
		run.nentries = prim.read_u64le(&r)
		append(&s.runs, run)
	}
	nc := prim.read_uvarint(&r)
	if r.err != .None || nc > 1 << 20 {
		return false
	}
	clear(&s.lives)
	for _ in 0 ..< nc {
		c := Cont {
			fd = prim.INVALID_FD,
		}
		c.id = prim.read_u32le(&r)
		c.live = i64(prim.read_uvarint(&r))
		append(&s.lives, c)
	}
	return r.err == .None && prim.reader_done(&r) && s.ck_off >= CONT_HDR
}

@(private)
_super_write :: proc(p: ^Pack) -> Error {
	_drain(p) or_return
	p.gen += 1
	buf := make([dynamic]u8, context.temp_allocator)
	if !_super_encode(p, &buf) {
		return .Too_Large
	}
	slot := i64(p.gen % 2) * SUPER_SLOT
	if e := prim.write_at(p.base, p.super_fd, buf[:], slot); e != .None {
		return e
	}
	return _sync(p, p.super_fd)
}

@(private)
_super_read :: proc(p: ^Pack, s: ^Super) -> bool {
	best := false
	tmp: Super
	tmp.runs.allocator = context.temp_allocator
	tmp.lives.allocator = context.temp_allocator
	buf := make([]u8, SUPER_SLOT, context.temp_allocator)
	for slot in 0 ..< 2 {
		n, err := prim.read_at(p.base, p.super_fd, buf, i64(slot) * SUPER_SLOT)
		if err != .None {
			continue
		}
		if !_super_decode(buf[:n], &tmp) {
			continue
		}
		if tmp.version != VERSION {
			if !best {
				s.version = tmp.version
				best = true
			}
			continue
		}
		if !best || s.version != VERSION || tmp.gen > s.gen {
			s.version = tmp.version
			s.gen = tmp.gen
			s.ck_cont = tmp.ck_cont
			s.ck_off = tmp.ck_off
			s.ck_seq = tmp.ck_seq
			s.next_ino = tmp.next_ino
			s.next_cont = tmp.next_cont
			s.next_run = tmp.next_run
			s.compacting = tmp.compacting
			s.cpos = tmp.cpos
			s.clean = tmp.clean
			clear(&s.runs)
			append(&s.runs, ..tmp.runs[:])
			clear(&s.lives)
			append(&s.lives, ..tmp.lives[:])
			best = true
		}
	}
	return best
}

stats :: proc(p: ^Pack) -> Stats {
	s := p.stats
	s.runs = len(p.runs)
	s.containers = len(p.conts)
	s.mem_bytes = _mem_bytes(&p.mem) + cap(p.buf) + cap(p.scratch)
	if p.fl.imm != nil {
		s.mem_bytes += _mem_bytes(p.fl.imm)
	}
	n := 0
	for h in p.handles {
		if h.used {
			n += 1
		}
	}
	s.open_handles = n
	for r in p.runs {
		s.index_size += u64(r.nblocks) * BLOCK
		s.filter_bytes += len(r.fres)
		s.findex_bytes += len(r.fkeys) + len(r.fents) * size_of(Fpart)
	}
	return s
}

@(private)
_filters_rebalance :: proc(p: ^Pack) -> Error {
	order := make([dynamic]^Run, 0, len(p.runs), context.temp_allocator)
	for r in p.runs {
		append(&order, r)
	}
	for i in 1 ..< len(order) {
		j := i
		for j > 0 && _run_filter_bytes(order[j - 1]) > _run_filter_bytes(order[j]) {
			order[j - 1], order[j] = order[j], order[j - 1]
			j -= 1
		}
	}
	used := 0
	for r in order {
		need := _run_filter_bytes(r)
		if used + need <= p.opts.filter_budget {
			_run_filter_load(p, r) or_return
			used += need
		} else {
			_run_filter_drop(p, r)
		}
	}
	return .None
}

queue_hook :: proc(p: ^Pack, h: Commit_Hook) {
	if p.queued == nil {
		p.queued = make([dynamic]Commit_Hook, p.allocator)
	}
	append(&p.queued, h)
}
