#+build linux, darwin, windows
package osync

import "base:runtime"
import "core:hash/xxhash"
import "../pack"
import "../prim"

Extent_Resolver :: struct {
	data:    rawptr,
	resolve: proc(data: rawptr, fd: prim.Fd, off: i64, n: i64) -> (prim.Fd, i64, i64, bool),
}

File_Store :: struct {
	vfs:       prim.Vfs,
	lay:       Layout,
	resolver:  Extent_Resolver,
	pack:      ^pack.Pack,
	random:    prim.Random,
	clock:     prim.Clock,
	root:      string,
	loop:      ^prim.Loop,
	worker:    Worker,
	udirty:    [dynamic]^_Fns,
	scratch:   []u8,
	allocator: runtime.Allocator,
}

@(private)
_Fns :: struct {
	dir:    string,
	usage:  i64,
	ufd:    prim.Fd,
	useq:   u64,
	udirty: bool,
}

@(private)
_Deferred :: struct {
	append: ^_Fappend,
	from:   i64,
	to:     i64,
	done:   Storage_Done,
	ctx:    rawptr,
	trim:   bool,
	evict:  bool,
	data:   []u8,
	keep:   bool,
}

@(private)
_Fstream :: struct {
	busy:    bool,
	pins:    int,
	closing: bool,
	queue:  [dynamic]_Deferred,
	ns:     ^_Fns,
	id:     Stream_Id,
	fd:     prim.Fd,
	length: i64,
	base:   i64,
	seq:    u64,
	fresh:  bool,
	trimmed: bool,
	slotted: bool,
}

@(private)
_Fappend :: struct {
	st:     ^_Fstream,
	fd:     prim.Fd,
	at:     i64,
	pos:    i64,
	total:  i64,
	hash:   xxhash.XXH64_state,
	failed: Error,
	fill:   bool,
	note:   bool,
}

@(private)
_Fput :: struct {
	ns:     rawptr,
	fd:     prim.Fd,
	tmp:    string,
	final:  string,
	total:  i64,
	pos:    i64,
	failed: Error,
}

@(private)
_Fobj :: struct {
	fd: prim.Fd,
}

@(private)
_Flist :: struct {
	it:    prim.Dir,
	open:  bool,
	dir:   string,
	since: i64,
}

file_store_init :: proc(fs: ^File_Store, l: ^prim.Loop, vfs: prim.Vfs, root: string, sync_threads := 4, lay := LAYOUT_SECTOR, group := Group_Commit{}, random := prim.Random{}, clock := prim.Clock{}, allocator := context.allocator) -> Error {
	fs^ = {
		vfs       = vfs,
		random    = random,
		clock     = clock,
		lay       = lay,
		loop      = l,
		allocator = allocator,
	}
	fs.root = _clone_string(root, allocator) or_return
	if merr := prim.mkdir_all(fs.vfs, root, 0o700); merr != .None {
		delete(fs.root, allocator)
		return _from_prim(merr)
	}
	b, aerr := make([]u8, 256 * 1024, allocator)
	if aerr != nil {
		delete(fs.root, allocator)
		return .No_Memory
	}
	fs.scratch = b
	if err := worker_init(&fs.worker, l, sync_threads, _fs_job_done, fs, allocator); err != .None {
		delete(fs.scratch, allocator)
		delete(fs.root, allocator)
		return err
	}
	fs.worker.group = group
	fs.worker.before = _fs_usage_flush
	fs.udirty = make([dynamic]^_Fns, allocator)
	return .None
}

file_store_destroy :: proc(fs: ^File_Store) {
	worker_destroy(&fs.worker)
	_fs_usage_flush(fs)
	delete(fs.udirty)
	delete(fs.scratch, fs.allocator)
	delete(fs.root, fs.allocator)
	fs^ = {}
}

file_store :: proc(fs: ^File_Store) -> Relay_Storage {
	return Relay_Storage {
		data = fs,
		namespace_open = _fs_ns_open,
		namespace_close = _fs_ns_close,
		stream_open = _fs_stream_open,
		stream_close = _fs_stream_close,
		stream_probe = _fs_stream_probe,
		stream_base = _fs_stream_base,
		stream_read = _fs_stream_read,
		stream_extent = _fs_stream_extent,
		stream_hint = _fs_stream_hint,
		append_begin = _fs_append_begin,
		append_write = _fs_append_write,
		append_commit = _fs_append_commit,
		append_abort = _fs_append_abort,
		fill_begin = _fs_fill_begin,
		note = _fs_note,
		drop = _fs_drop,
		redact = _fs_redact,
		trim = _fs_trim,
		evict = _fs_evict,
		restore = _fs_restore,
		stream_trimmed = _fs_stream_trimmed,
		list_begin = _fs_list_begin,
		list_next = _fs_list_next,
		list_end = _fs_list_end,
		put_begin = _fs_put_begin,
		put_write = _fs_put_write,
		put_commit = _fs_put_commit,
		put_abort = _fs_put_abort,
		object_open = _fs_object_open,
		object_read = _fs_object_read,
		object_extent = _fs_object_extent,
		object_close = _fs_object_close,
		object_remove = _fs_object_remove,
		objects = _fs_objects,
		atomic = fs.pack != nil,
	}
}

@(private)
_fs_ns_open :: proc(data: rawptr, id: Space_Id) -> (h: rawptr, usage: i64, err: Error) {
	fs := cast(^File_Store)data
	dir := space_paths(fs.vfs, fs.root, id, fs.allocator) or_return
	ns, aerr := new(_Fns, fs.allocator)
	if aerr != nil {
		delete(dir, fs.allocator)
		return nil, 0, .No_Memory
	}
	ns.dir = dir
	ns.ufd = prim.INVALID_FD
	upath, _ := prim.path_join(context.temp_allocator, dir, "usage")
	tdir, _ := prim.path_join(context.temp_allocator, dir, "t")
	_clear_tmp(fs.vfs, tdir, fs.allocator)
	ufd, uerr := prim.open_file(fs.vfs, upath, {.Write}, 0o600)
	if uerr == .None {
		newest, _, count, serr := slots_read(fs.vfs, ufd, 64)
		if serr == .None && count > 0 {
			ns.ufd = ufd
			ns.usage = newest.value
			ns.useq = newest.seq
			return ns, ns.usage, .None
		}
		prim.close_file(fs.vfs, ufd)
	}
	ns.usage, _ = space_usage_scan(fs.vfs, dir, fs.allocator, fs.lay.base)
	if fd, cerr := prim.open_file(fs.vfs, upath, {.Write, .Create}, 0o600); cerr == .None {
		ns.ufd = fd
		_usage_save(fs, ns)
	}
	return ns, ns.usage, .None
}

@(private)
_fs_ns_close :: proc(data: rawptr, h: rawptr) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	if ns.udirty {
		_usage_save(fs, ns)
		for i := 0; i < len(fs.udirty); i += 1 {
			if fs.udirty[i] == ns {
				unordered_remove(&fs.udirty, i)
				break
			}
		}
	}
	if ns.ufd >= 0 {
		prim.close_file(fs.vfs, ns.ufd)
	}
	delete(ns.dir, fs.allocator)
	free(ns, fs.allocator)
}

@(private)
_fs_stream_open :: proc(data: rawptr, h: rawptr, id: Stream_Id, create: bool) -> (s: rawptr, length: i64, err: Error) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	f := stream_file_open(fs.vfs, stream_path(&pbuf, ns.dir, id), create, fs.scratch, fs.lay) or_return
	st, aerr := new(_Fstream, fs.allocator)
	if aerr != nil {
		prim.close_file(fs.vfs, f.fd)
		return nil, 0, .No_Memory
	}
	st^ = {
		queue  = make([dynamic]_Deferred, fs.allocator),
		ns     = ns,
		id     = id,
		fd     = f.fd,
		length = f.length,
		base   = f.base,
		seq    = f.seq,
		fresh  = f.fresh,
		trimmed = f.trimmed,
		slotted = f.slotted,
	}
	return st, f.length, .None
}

@(private)
_fs_stream_base :: proc(data: rawptr, s: rawptr) -> i64 {
	return (cast(^_Fstream)s).base
}

@(private)
_fs_stream_trimmed :: proc(data: rawptr, s: rawptr) -> bool {
	return (cast(^_Fstream)s).trimmed
}

@(private)
_fs_trim :: proc(data: rawptr, s: rawptr, base: i64, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	if st.busy {
		if _, e := append(&st.queue, _Deferred{trim = true, from = base, done = done, ctx = ctx}); e != nil {
			done(ctx, .No_Memory, 0)
		}
		return
	}
	if base >= st.length {
		done(ctx, .Conflict, 0)
		return
	}
	if base < st.base || (base == st.base && (st.trimmed || base == 0)) {
		done(ctx, .None, 0)
		return
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	st.busy = true
	job^ = {
		vfs    = fs.vfs,
		lay    = fs.lay,
		kind   = .Trim,
		fd     = st.fd,
		value  = st.length,
		base   = base,
		from   = st.base,
		delta  = st.base - base,
		seq    = st.seq + 1,
		target = st,
		done   = done,
		ctx    = ctx,
	}
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_evict :: proc(data: rawptr, s: rawptr, upto: i64, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	if !fs.lay.exact || st.slotted {
		done(ctx, .None, 0)
		return
	}
	if st.busy {
		if _, e := append(&st.queue, _Deferred{evict = true, from = upto, done = done, ctx = ctx}); e != nil {
			done(ctx, .No_Memory, 0)
		}
		return
	}
	hi := min(upto, st.length)
	if hi <= st.base {
		done(ctx, .None, 0)
		return
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	st.busy = true
	job^ = {vfs = fs.vfs, lay = fs.lay, kind = .Evict, fd = st.fd, from = st.base, value = hi, target = st, done = done, ctx = ctx}
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_restore :: proc(data: rawptr, s: rawptr, at: i64, bytes: []u8, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	own, aerr := make([]u8, len(bytes), fs.allocator)
	if aerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	copy(own, bytes)
	_fs_restore_owned(fs, cast(^_Fstream)s, at, own, done, ctx)
}

@(private)
_fs_restore_owned :: proc(fs: ^File_Store, st: ^_Fstream, at: i64, own: []u8, done: Storage_Done, ctx: rawptr) {
	if st.busy {
		if _, e := append(&st.queue, _Deferred{keep = true, from = at, data = own, done = done, ctx = ctx}); e != nil {
			delete(own, fs.allocator)
			done(ctx, .No_Memory, 0)
		}
		return
	}
	if at < st.base || at + i64(len(own)) > st.length {
		delete(own, fs.allocator)
		done(ctx, .Conflict, 0)
		return
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		delete(own, fs.allocator)
		done(ctx, .No_Memory, 0)
		return
	}
	st.busy = true
	job^ = {vfs = fs.vfs, lay = fs.lay, kind = .Restore, fd = st.fd, from = at, data = own, target = st, done = done, ctx = ctx}
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_stream_close :: proc(data: rawptr, s: rawptr) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	st.closing = true
	_fs_stream_reap(fs, st)
}

@(private)
_fs_stream_reap :: proc(fs: ^File_Store, st: ^_Fstream) {
	if !st.closing || st.pins > 0 || st.busy || len(st.queue) > 0 {
		return
	}
	delete(st.queue)
	prim.close_file(fs.vfs, st.fd)
	free(st, fs.allocator)
}

@(private)
_fs_stream_probe :: proc(data: rawptr, h: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool, err: Error) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	return stream_file_size(fs.vfs, stream_path(&pbuf, ns.dir, id), fs.scratch, fs.lay)
}

@(private)
_fs_stream_read :: proc(data: rawptr, s: rawptr, at: i64, dst: []u8) -> (int, Error) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	n, err := prim.read_at(fs.vfs, st.fd, dst, fs.lay.base + at)
	return n, _from_prim(err)
}

@(private)
_fs_stream_extent :: proc(data: rawptr, s: rawptr, at: i64, n: i64) -> (fd: prim.Fd, off: i64, length: i64, ok: bool) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	return _fs_extent(fs, st.fd, fs.lay.base + at, n)
}

@(private)
_fs_extent :: proc(fs: ^File_Store, fd: prim.Fd, off: i64, n: i64) -> (prim.Fd, i64, i64, bool) {
	if fs.vfs.procs == prim.os_vfs().procs {
		return fd, off, n, true
	}
	if fs.resolver.resolve != nil {
		return fs.resolver.resolve(fs.resolver.data, fd, off, n)
	}
	return prim.INVALID_FD, 0, 0, false
}

@(private)
_fs_stream_hint :: proc(data: rawptr, h: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	fd, err := prim.open_file(fs.vfs, stream_path(&pbuf, ns.dir, id))
	if err != .None {
		return 0, 0, false
	}
	defer prim.close_file(fs.vfs, fd)
	newest, _, count, serr := slots_read(fs.vfs, fd, fs.lay.spacing)
	if serr == .None && count == 0 && fs.lay.exact {
		size, ferr := prim.file_size(fs.vfs, fd)
		return max(size - fs.lay.base, 0) if ferr == .None else 0, 0, true
	}
	if serr != .None || count == 0 {
		return 0, 0, true
	}
	return newest.value, newest.base, true
}


@(private)
_fs_append_begin :: proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	if at != st.length {
		return nil, .Conflict
	}
	fd := _fs_stage(fs, st) or_return
	a, aerr := new(_Fappend, fs.allocator)
	if aerr != nil {
		_fs_unstage(fs, st, fd)
		return nil, .No_Memory
	}
	a^ = {
		st    = st,
		fd    = fd,
		at    = at,
		pos   = at,
		total = total,
	}
	xxhash.XXH64_reset_state(&a.hash, u64(at))
	return a, .None
}

@(private)
_fs_fill_begin :: proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	assert(!st.trimmed, "fill below a trimmed base")
	if at < 0 || total <= 0 || at + total != st.base {
		return nil, .Conflict
	}
	fd := _fs_stage(fs, st) or_return
	a, aerr := new(_Fappend, fs.allocator)
	if aerr != nil {
		_fs_unstage(fs, st, fd)
		return nil, .No_Memory
	}
	a^ = {
		st    = st,
		fd    = fd,
		at    = at,
		pos   = at,
		total = total,
		fill  = true,
	}
	xxhash.XXH64_reset_state(&a.hash, u64(at))
	return a, .None
}

@(private)
_fs_note :: proc(data: rawptr, s: rawptr, length: i64, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	a, aerr := new(_Fappend, fs.allocator)
	if aerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	a^ = {
		st    = st,
		fd    = st.fd,
		at    = length,
		pos   = length,
		note  = true,
	}
	_fs_append_commit(fs, a, done, ctx)
}

@(private)
_fs_append_write :: proc(data: rawptr, w: rawptr, bytes: []u8) -> Error {
	fs := cast(^File_Store)data
	a := cast(^_Fappend)w
	if a.failed == .None {
		if err := prim.write_at(fs.vfs, a.fd, bytes, fs.lay.base + a.pos); err != .None {
			a.failed = _from_prim(err)
		} else {
			xxhash.XXH64_update(&a.hash, bytes)
		}
	}
	a.pos += i64(len(bytes))
	return a.failed
}

@(private)
_fs_append_free :: proc(fs: ^File_Store, a: ^_Fappend) {
	_fs_unstage(fs, a.st, a.fd)
	free(a, fs.allocator)
}

@(private)
_fs_stage :: proc(fs: ^File_Store, st: ^_Fstream) -> (prim.Fd, Error) {
	if fs.pack == nil {
		return st.fd, .None
	}
	fd, err := pack.stage(fs.pack, st.fd)
	return fd, _from_prim(err)
}

@(private)
_fs_unstage :: proc(fs: ^File_Store, st: ^_Fstream, fd: prim.Fd) {
	if fd != st.fd && fd >= 0 {
		prim.close_file(fs.vfs, fd)
	}
}

@(private)
_fs_append_abort :: proc(data: rawptr, w: rawptr) {
	_fs_append_free(cast(^File_Store)data, cast(^_Fappend)w)
}

@(private)
_fs_append_commit :: proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	a := cast(^_Fappend)w
	st := a.st
	if st.busy {
		if _, e := append(&st.queue, _Deferred{append = a, done = done, ctx = ctx}); e != nil {
			_fs_append_free(fs, a)
			done(ctx, .No_Memory, 0)
		}
		return
	}
	err := a.failed
	if err == .None && a.pos != a.at + a.total {
		err = .Invalid
	}
	new_len := a.at + a.total
	new_base := st.base
	slot := Slot{seq = st.seq + 1, value = new_len, start = a.at, hash = xxhash.XXH64_digest(&a.hash), base = st.base, trimmed = st.trimmed}
	switch {
	case a.note:
		if st.base != st.length || a.at < st.length {
			err = .Conflict
		}
		new_base = a.at
		slot = Slot{seq = st.seq + 1, value = a.at, start = a.at, base = a.at}
	case a.fill:
		if a.at + a.total != st.base {
			err = .Conflict
		}
		new_len = st.length
		new_base = a.at
		slot.value = st.length
		slot.base = a.at
		slot.end = a.at + a.total
	case:
		if a.at != st.length {
			err = .Conflict
		}
	}
	delta := a.total
	if a.note {
		new_len = a.at
	}
	if err == .None && (!fs.lay.exact || st.slotted || a.note || a.fill || st.base != 0 || st.trimmed) {
		err = slot_write(fs.vfs, st.fd, slot, fs.lay.spacing)
		if err == .None {
			st.slotted = true
		}
	}
	job: ^Job
	if err == .None {
		jerr: runtime.Allocator_Error
		job, jerr = new(Job, fs.allocator)
		if jerr != nil {
			err = .No_Memory
		}
	}
	if err != .None {
		_fs_append_free(fs, a)
		done(ctx, err, 0)
		return
	}
	fd := a.fd
	a.fd = st.fd
	_fs_append_free(fs, a)
	st.busy = true
	job^ = {
		vfs    = fs.vfs,
		lay    = fs.lay,
		kind   = .Stream_Sync,
		fd     = fd,
		value  = new_len,
		base   = new_base,
		delta  = delta,
		seq    = st.seq + 1,
		target = st,
		done   = done,
		ctx    = ctx,
	}
	if st.fresh {
		job.dir_fd = true
		pbuf: prim.Path_Buf = ---
		job.path, _ = _clone_string(stream_path(&pbuf, st.ns.dir, st.id), fs.allocator)
	}
	if serr := worker_submit(&fs.worker, job); serr != .None {
		job.result = serr
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_drop :: proc(data: rawptr, h: rawptr, id: Stream_Id, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	path := stream_path(&pbuf, ns.dir, id)
	fst, serr := prim.stat(fs.vfs, path)
	size := fst.size
	if serr == .Not_Found {
		done(ctx, .None, 0)
		return
	}
	stored := max(size - fs.lay.base, 0)
	if length, base, exists, perr := stream_file_size(fs.vfs, path, fs.scratch, fs.lay); perr == .None && exists {
		stored = min(stored, max(length - base, 0))
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	job^ = {
		vfs    = fs.vfs,
		lay    = fs.lay,
		kind  = .Remove,
		ns    = h,
		fd    = prim.INVALID_FD,
		value = stored,
		done  = done,
		ctx   = ctx,
	}
	job.path, _ = _clone_string(path, fs.allocator)
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_redact :: proc(data: rawptr, s: rawptr, from, to: i64, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	st := cast(^_Fstream)s
	if st.busy {
		if _, e := append(&st.queue, _Deferred{from = from, to = to, done = done, ctx = ctx}); e != nil {
			done(ctx, .No_Memory, 0)
		}
		return
	}
	lo := clamp(from, st.base, st.length)
	hi := clamp(to, lo, st.length)
	if hi <= lo {
		done(ctx, .None, 0)
		return
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	st.busy = true
	job^ = {
		vfs    = fs.vfs,
		lay    = fs.lay,
		kind   = .Redact,
		fd     = st.fd,
		value  = st.length,
		base   = st.base,
		seq    = st.seq + 1,
		trimmed = st.trimmed,
		slot   = !fs.lay.exact || st.slotted,
		from   = lo,
		to     = hi,
		target = st,
		done   = done,
		ctx    = ctx,
	}
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_list_begin :: proc(data: rawptr, h: rawptr, since: i64) -> (it: rawptr, cursor: i64, err: Error) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	l, aerr := new(_Flist, fs.allocator)
	if aerr != nil {
		return nil, 0, .No_Memory
	}
	l.since = since
	l.dir = ns.dir
	sdir, _ := prim.path_join(context.temp_allocator, ns.dir, "s")
	l.open = prim.dir_open(fs.vfs, &l.it, sdir, fs.allocator) == .None
	return l, prim.clock_wall_ns(fs.clock) - 2_000_000_000, .None
}

@(private)
_fs_list_next :: proc(data: rawptr, it: rawptr) -> (id: Stream_Id, ok: bool) {
	fs := cast(^File_Store)data
	l := cast(^_Flist)it
	pbuf: prim.Path_Buf = ---
	for l.open {
		e, more, err := prim.dir_next(fs.vfs, &l.it)
		if !more || err != .None {
			return {}, false
		}
		sid, idok := parse_stream_name(e.name)
		if !idok {
			continue
		}
		st, serr := prim.stat(fs.vfs, stream_path(&pbuf, l.dir, sid))
		if serr != .None || st.mtime_ns < l.since {
			continue
		}
		return sid, true
	}
	return {}, false
}

@(private)
_fs_list_end :: proc(data: rawptr, it: rawptr) {
	fs := cast(^File_Store)data
	l := cast(^_Flist)it
	if l.open {
		prim.dir_close(fs.vfs, &l.it)
	}
	free(l, fs.allocator)
}

@(private)
_fs_put_begin :: proc(data: rawptr, h: rawptr, key: Object_Key, total: i64) -> (w: rawptr, exists: bool, err: Error) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	final := object_path(&pbuf, ns.dir, key)
	if prim.exists(fs.vfs, final) {
		return nil, true, .None
	}
	tbuf: prim.Path_Buf = ---
	tmp := tmp_path(&tbuf, ns.dir, fs.random)
	fd, oerr := prim.open_file(fs.vfs, tmp, {.Write, .Create, .Exclusive}, 0o600)
	if oerr != .None {
		return nil, false, _from_prim(oerr)
	}
	p, aerr := new(_Fput, fs.allocator)
	if aerr != nil {
		prim.close_file(fs.vfs, fd)
		prim.remove(fs.vfs, tmp)
		return nil, false, .No_Memory
	}
	p.fd = fd
	p.ns = h
	p.total = total
	e1, e2: Error
	p.tmp, e1 = _clone_string(tmp, fs.allocator)
	p.final, e2 = _clone_string(final, fs.allocator)
	if e1 != .None || e2 != .None {
		prim.remove(fs.vfs, tmp)
		_fs_put_free(fs, p)
		return nil, false, .No_Memory
	}
	return p, false, .None
}

@(private)
_fs_put_free :: proc(fs: ^File_Store, p: ^_Fput) {
	if p.fd >= 0 {
		prim.close_file(fs.vfs, p.fd)
	}
	if len(p.tmp) > 0 {
		delete(p.tmp, fs.allocator)
	}
	if len(p.final) > 0 {
		delete(p.final, fs.allocator)
	}
	free(p, fs.allocator)
}

@(private)
_fs_put_write :: proc(data: rawptr, w: rawptr, bytes: []u8) -> Error {
	fs := cast(^File_Store)data
	p := cast(^_Fput)w
	if p.failed == .None {
		if err := prim.write_at(fs.vfs, p.fd, bytes, p.pos); err != .None {
			p.failed = _from_prim(err)
		}
	}
	p.pos += i64(len(bytes))
	return p.failed
}

@(private)
_fs_put_abort :: proc(data: rawptr, w: rawptr) {
	fs := cast(^File_Store)data
	p := cast(^_Fput)w
	prim.remove(fs.vfs, p.tmp)
	_fs_put_free(fs, p)
}

@(private)
_fs_put_commit :: proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	p := cast(^_Fput)w
	if p.failed != .None || p.pos != p.total {
		err := p.failed if p.failed != .None else Error.Invalid
		_fs_put_abort(data, w)
		done(ctx, err, 0)
		return
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		_fs_put_abort(data, w)
		done(ctx, .No_Memory, 0)
		return
	}
	job^ = {
		vfs    = fs.vfs,
		lay    = fs.lay,
		kind  = .Object_Commit,
		ns    = p.ns,
		fd    = p.fd,
		path  = p.tmp,
		final = p.final,
		value = p.total,
		done  = done,
		ctx   = ctx,
	}
	p.fd = prim.INVALID_FD
	p.tmp = ""
	p.final = ""
	_fs_put_free(fs, p)
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_object_open :: proc(data: rawptr, h: rawptr, key: Object_Key) -> (o: rawptr, size: i64, err: Error) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	fd, oerr := prim.open_file(fs.vfs, object_path(&pbuf, ns.dir, key))
	if oerr != .None {
		return nil, 0, _from_prim(oerr)
	}
	sz, serr := prim.file_size(fs.vfs, fd)
	if serr != .None {
		prim.close_file(fs.vfs, fd)
		return nil, 0, _from_prim(serr)
	}
	ob, aerr := new(_Fobj, fs.allocator)
	if aerr != nil {
		prim.close_file(fs.vfs, fd)
		return nil, 0, .No_Memory
	}
	ob.fd = fd
	return ob, sz, .None
}

@(private)
_fs_object_remove :: proc(data: rawptr, h: rawptr, key: Object_Key, done: Storage_Done, ctx: rawptr) {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	pbuf: prim.Path_Buf = ---
	path := object_path(&pbuf, ns.dir, key)
	st, serr := prim.stat(fs.vfs, path)
	if serr != .None {
		done(ctx, .None, 0)
		return
	}
	job, jerr := new(Job, fs.allocator)
	if jerr != nil {
		done(ctx, .No_Memory, 0)
		return
	}
	job^ = {
		vfs   = fs.vfs,
		kind  = .Remove,
		ns    = h,
		fd    = prim.INVALID_FD,
		value = st.size,
		done  = done,
		ctx   = ctx,
	}
	job.path, _ = _clone_string(path, fs.allocator)
	if err := worker_submit(&fs.worker, job); err != .None {
		job.result = err
		_fs_job_done(fs, job)
	}
}

@(private)
_fs_objects :: proc(data: rawptr, h: rawptr, out: ^[dynamic]Object_Key) -> Error {
	fs := cast(^File_Store)data
	ns := cast(^_Fns)h
	odir, _ := prim.path_join(context.temp_allocator, ns.dir, "o")
	top: prim.Dir
	if prim.dir_open(fs.vfs, &top, odir, fs.allocator) != .None {
		return .None
	}
	defer prim.dir_close(fs.vfs, &top)
	for {
		e, more, err := prim.dir_next(fs.vfs, &top)
		if !more || err != .None {
			break
		}
		if len(e.name) != 2 {
			continue
		}
		sub, _ := prim.path_join(context.temp_allocator, odir, e.name)
		d: prim.Dir
		if prim.dir_open(fs.vfs, &d, sub, fs.allocator) != .None {
			continue
		}
		for {
			f, fmore, ferr := prim.dir_next(fs.vfs, &d)
			if !fmore || ferr != .None {
				break
			}
			name := [64]u8{}
			if len(f.name) != 62 {
				continue
			}
			copy(name[:2], e.name)
			copy(name[2:], f.name)
			k: Object_Key
			if prim.hex_decode(k[:], name[:]) {
				append(out, k)
			}
		}
		prim.dir_close(fs.vfs, &d)
	}
	return .None
}

@(private)
_fs_object_read :: proc(data: rawptr, o: rawptr, at: i64, dst: []u8) -> (int, Error) {
	fs := cast(^File_Store)data
	ob := cast(^_Fobj)o
	n, err := prim.read_at(fs.vfs, ob.fd, dst, at)
	return n, _from_prim(err)
}

@(private)
_fs_object_extent :: proc(data: rawptr, o: rawptr, at: i64, n: i64) -> (fd: prim.Fd, off: i64, length: i64, ok: bool) {
	fs := cast(^File_Store)data
	ob := cast(^_Fobj)o
	return _fs_extent(fs, ob.fd, at, n)
}


@(private)
_fs_object_close :: proc(data: rawptr, o: rawptr) {
	fs := cast(^File_Store)data
	ob := cast(^_Fobj)o
	prim.close_file(fs.vfs, ob.fd)
	free(ob, fs.allocator)
}

@(private)
_fs_job_done :: proc(data: rawptr, job: ^Job) {
	fs := cast(^File_Store)data
	value := job.value
	switch job.kind {
	case .Stream_Sync:
		st := cast(^_Fstream)job.target
		st.busy = false
		_fs_unstage(fs, st, job.fd)
		if job.result == .None {
			_usage_add(fs, st.ns, job.delta)
			st.length = job.value
			st.base = job.base
			st.seq = job.seq
			st.fresh = false
		}
	case .Object_Commit:
		if job.existed {
			value = 0
		}
		if job.result == .None && job.ns != nil {
			_usage_add(fs, cast(^_Fns)job.ns, value)
		}
	case .Redact:
		st := cast(^_Fstream)job.target
		st.busy = false
		if job.result == .None {
			st.seq = job.seq
		}
	case .Trim:
		st := cast(^_Fstream)job.target
		st.busy = false
		if job.result == .None {
			_usage_add(fs, st.ns, job.delta)
			st.base = job.base
			st.seq = job.seq
			st.trimmed = true
			st.slotted = true
			value = -job.delta
		}
	case .Evict, .Restore:
		st := cast(^_Fstream)job.target
		st.busy = false
		if job.data != nil {
			delete(job.data, fs.allocator)
			job.data = nil
		}
		value = 0
	case .Remove:
		if job.result == .None && job.ns != nil {
			_usage_add(fs, cast(^_Fns)job.ns, -value)
		}
	}
	done := job.done
	ctx := job.ctx
	result := job.result
	if len(job.path) > 0 {
		delete(job.path, fs.allocator)
	}
	if len(job.final) > 0 {
		delete(job.final, fs.allocator)
	}
	st := cast(^_Fstream)job.target if job.kind == .Stream_Sync || job.kind == .Redact || job.kind == .Trim || job.kind == .Evict || job.kind == .Restore else nil
	free(job, fs.allocator)
	if st == nil {
		done(ctx, result, value)
		return
	}
	st.pins += 1
	done(ctx, result, value)
	_fs_next(fs, st)
	st.pins -= 1
	_fs_stream_reap(fs, st)
}

@(private)
_fs_next :: proc(fs: ^File_Store, st: ^_Fstream) {
	st.pins += 1
	for !st.busy && len(st.queue) > 0 {
		d := st.queue[0]
		ordered_remove(&st.queue, 0)
		if d.append != nil {
			_fs_append_commit(fs, d.append, d.done, d.ctx)
		} else if d.trim {
			_fs_trim(fs, st, d.from, d.done, d.ctx)
		} else if d.evict {
			_fs_evict(fs, st, d.from, d.done, d.ctx)
		} else if d.keep {
			_fs_restore_owned(fs, st, d.from, d.data, d.done, d.ctx)
		} else {
			_fs_redact(fs, st, d.from, d.to, d.done, d.ctx)
		}
	}
	st.pins -= 1
}

@(private)
_usage_add :: proc(fs: ^File_Store, ns: ^_Fns, delta: i64) {
	if delta == 0 {
		return
	}
	ns.usage = max(ns.usage + delta, 0)
	if fs.worker.limit > 0 {
		_usage_save(fs, ns)
		return
	}
	if !ns.udirty {
		ns.udirty = true
		append(&fs.udirty, ns)
	}
}

@(private)
_fs_usage_flush :: proc(data: rawptr) {
	fs := cast(^File_Store)data
	for ns in fs.udirty {
		ns.udirty = false
		_usage_save(fs, ns)
	}
	clear(&fs.udirty)
}

@(private)
_usage_save :: proc(fs: ^File_Store, ns: ^_Fns) {
	if ns.ufd < 0 {
		return
	}
	ns.useq += 1
	slot_write(fs.vfs, ns.ufd, Slot{seq = ns.useq, value = ns.usage, start = 0}, 64)
}
