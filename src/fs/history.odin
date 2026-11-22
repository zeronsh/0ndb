package fs

import "base:runtime"
import "core:slice"
import "../crdt"
import "../fshist"
import "../fstree"
import "../journal"
import "../odb"
import "../prim"

REC_BATCH :: fshist.REC_BATCH
REC_IMPORT :: fshist.REC_IMPORT
REC_ACTORS :: fshist.REC_ACTORS

TOP_CREATE :: fshist.TOP_CREATE
TOP_MOVE :: fshist.TOP_MOVE
TOP_REMOVE :: fshist.TOP_REMOVE
TOP_RESTORE :: fshist.TOP_RESTORE
TOP_FLAGS :: fshist.TOP_FLAGS
TOP_TARGET :: fshist.TOP_TARGET
TOP_CONTENT :: fshist.TOP_CONTENT
TOP_GIT :: fshist.TOP_GIT

CHECKPOINT_OPS :: 64
OPS_CHUNK :: fshist.OPS_CHUNK
MOVES_CHUNK :: fshist.MOVES_CHUNK

Version :: fshist.Version

Stream_Source :: struct {
	data: rawptr,
	read: proc(data: rawptr, stream: prim.Id, off: i64, out: ^[dynamic]u8) -> bool,
}

Blob_Reg :: fshist.Blob_Reg
Op_Ref :: fshist.Op_Ref
File_Record :: fshist.File_Record

File_State :: struct {
	inode:    fstree.Inode_Id,
	rec:      File_Record,
	using st: fshist.Text_State,
	dirty:    bool,
	new_refs: [dynamic]Op_Ref,
}

Git_Marker :: struct {
	kind:   string,
	branch: string,
	commit: string,
}

Clock :: struct {
	data:    rawptr,
	wall_ms: proc(data: rawptr) -> i64,
}

Hold :: struct {
	data: rawptr,
	drop: proc(data: rawptr),
}

History_Options :: struct {
	chain:         Maybe(journal.Chain),
	keep_at_least: i64,
	clock:         Clock,
	random:        prim.Random,
	deferred:      bool,
	hold:          Hold,
}

@(private)
hold_drop :: proc(x: Hold) {
	if x.drop != nil {
		x.drop(x.data)
	}
}

History :: struct {
	opts:       History_Options,
	vfs:        prim.Vfs,
	allocator:  runtime.Allocator,
	id:         prim.Id,
	self:       prim.Id,
	dir:        string,
	db:         ^odb.Odb,
	streams:    Stream_Source,
	journal:    journal.Journal,
	kv:         Kv,
	g:          crdt.Graph,
	tree:       fstree.Tree,
	dict:       crdt.Actor_Dict,
	stream_ids: [dynamic]prim.Id,
	rdicts:     [dynamic]crdt.Actor_Dict,
	applied:    [dynamic]i64,
	files:      map[fstree.Inode_Id]^File_State,
	moves:      [dynamic]fstree.Move_Ref,
	moves_count: u64,
	awake:      bool,
	io:         [dynamic]u8,
	blob_cache: odb.Oid,
	blob_data:  []u8,
	touched:    [dynamic]fstree.Inode_Id,
	touched_set: map[fstree.Inode_Id]struct{},
	src_err:    Error,
	refs:       int,
	owned:      bool,
	durable:    u64,
	mark:       u64,
	mark_fp:    [3]u64,
	staged:     [dynamic]Staged_Blob,
	mounts:     [dynamic]^Mount,
	pins:       [dynamic]odb.Oid,
	lvidx:      prim.Fd,
	lvidx_n:    u64,
	markers:    [dynamic]Git_Marker,
	views:      [dynamic]^Text_View,
}

history_open :: proc(h: ^History, vfs: prim.Vfs, dir: string, id: prim.Id, self: prim.Id, db: ^odb.Odb, streams := Stream_Source{}, allocator := context.allocator, opts := History_Options{}) -> Error {
	h^ = {
		opts      = opts,
		vfs       = vfs,
		allocator = allocator,
		id        = id,
		self      = self,
		db        = db,
		streams   = streams,
	}
	d, aerr := clone_string(dir, allocator)
	if aerr != nil {
		return .No_Memory
	}
	h.dir = d
	h.staged = make([dynamic]Staged_Blob, allocator)
	h.mounts = make([dynamic]^Mount, allocator)
	if err := history_wake(h); err != .None {
		delete(h.dir, allocator)
		h.dir = ""
		return err
	}
	return .None
}

history_wall_ms :: proc(h: ^History) -> i64 {
	if h.opts.clock.wall_ms != nil {
		return h.opts.clock.wall_ms(h.opts.clock.data)
	}
	return prim.now_ms()
}

@(private)
history_attach_sources :: proc(h: ^History) {
	if h.db == nil {
		return
	}
	data, found, err := kv_get(&h.kv, transmute([]u8)string("src"), context.temp_allocator)
	if err != .None || !found {
		return
	}
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		dir := prim.read_str(&rd)
		if !prim.reader_ok(&rd) {
			return
		}
		odb.add_object_dir(h.db, dir)
	}
}

history_add_source :: proc(h: ^History, objects: string) -> Error {
	if h.db == nil {
		return .None
	}
	if e := odb.add_object_dir(h.db, objects); e != .None && e != .Not_Found {
		return from_odb(e)
	}
	data, _ := kv_get(&h.kv, transmute([]u8)string("src"), context.temp_allocator) or_return
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		if prim.read_str(&rd) == objects {
			return .None
		}
		if !prim.reader_ok(&rd) {
			break
		}
	}
	buf := make([dynamic]u8, 0, len(data) + len(objects) + 8, context.temp_allocator)
	append(&buf, ..data)
	w := prim.writer(&buf)
	prim.write_str(&w, objects)
	kv_put(&h.kv, transmute([]u8)string("src"), buf[:]) or_return
	return kv_commit(&h.kv)
}

history_wall_ns :: proc(h: ^History) -> i64 {
	if h.opts.clock.wall_ms != nil {
		return h.opts.clock.wall_ms(h.opts.clock.data) * 1_000_000
	}
	return prim.now_ns()
}

history_id_new :: proc(h: ^History) -> prim.Id {
	c := prim.Clock {
		data    = h,
		wall_ns = proc(data: rawptr) -> i64 {
			return history_wall_ns((^History)(data))
		},
	}
	return prim.id_new_with(c, h.opts.random)
}

@(private)
from_journal :: proc "contextless" (e: journal.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Io:
		return .Io
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Permission:
		return .Permission
	case .Busy:
		return .Busy
	case .Not_Found:
		return .Not_Found
	case .Redacted:
		return .Redacted
	}
	return .Corrupt
}

history_create :: proc(vfs: prim.Vfs, dir: string, id: prim.Id, self: prim.Id, db: ^odb.Odb, streams := Stream_Source{}, allocator := context.allocator, opts := History_Options{}) -> (h: ^History, err: Error) {
	h = new(History, allocator)
	if h == nil {
		return nil, .No_Memory
	}
	if err = history_open(h, vfs, dir, id, self, db, streams, allocator, opts); err != .None {
		free(h, allocator)
		hold_drop(opts.hold)
		return nil, err
	}
	h.owned = true
	h.refs = 1
	return h, .None
}

history_retain :: proc(h: ^History) {
	h.refs += 1
}

history_set_streams :: proc(h: ^History, streams: Stream_Source) {
	h.streams = streams
}

history_release :: proc(h: ^History) {
	if h == nil {
		return
	}
	h.refs -= 1
	if h.refs > 0 || !h.owned {
		return
	}
	allocator := h.allocator
	history_close(h)
	free(h, allocator)
}

history_reconfigure :: proc(h: ^History, opts: History_Options) -> Error {
	awake := h.awake
	history_sleep(h)
	old := h.opts.hold
	h.opts = opts
	hold_drop(old)
	if awake || len(h.mounts) > 0 {
		return history_wake(h)
	}
	return .None
}

history_rebind :: proc(h: ^History, streams: Stream_Source, opts: History_Options) -> Error {
	h.streams = streams
	a, aok := h.opts.chain.?
	b, bok := opts.chain.?
	if aok != bok || (aok && a != b) || h.opts.keep_at_least != opts.keep_at_least || h.opts.deferred != opts.deferred {
		return history_reconfigure(h, opts)
	}
	old := h.opts.hold
	h.opts = opts
	hold_drop(old)
	return .None
}

history_durable_mark :: proc "contextless" (h: ^History) -> u64 {
	return h.mark
}

@(private)
history_fp :: proc(h: ^History) -> [3]u64 {
	if !h.awake {
		return h.mark_fp
	}
	return {u64(journal.journal_durable_len(&h.journal)), h.kv.log_end, h.kv.gen}
}

history_durable :: proc(h: ^History, mark: u64) -> Error {
	if mark <= h.durable {
		return .None
	}
	h.durable = min(mark, h.mark)
	history_flush_staged(h, h.durable) or_return
	err: Error
	for m in h.mounts {
		if e := mount_ack(m); e != .None && err == .None {
			err = e
		}
	}
	return err
}

history_close :: proc(h: ^History) {
	history_sleep(h)
	delete(h.mounts)
	h.mounts = nil
	for x in h.staged {
		delete(x.data, h.allocator)
	}
	delete(h.staged)
	h.staged = nil
	delete(h.dir, h.allocator)
	h.dir = ""
	hold := h.opts.hold
	h.opts.hold = {}
	hold_drop(hold)
}

history_wake :: proc(h: ^History) -> Error {
	if h.awake {
		return .None
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	from_prim(prim.mkdir_all(h.vfs, h.dir, 0o700)) or_return
	kv_open(&h.kv, h.vfs, h.dir, "state", h.allocator) or_return
	history_attach_sources(h)
	jpath, _ := path_join(h.dir, "fs.journal", context.temp_allocator)
	jopts := journal.Options{keep_at_least = h.opts.keep_at_least}
	if _, ok := h.opts.chain.?; ok {
		jopts.chain = &h.opts.chain.?
	}
	if jerr := journal.journal_open(&h.journal, h.vfs, jpath, jopts, h.allocator); jerr != .None {
		kv_close(&h.kv)
		return .Io
	}
	crdt.dict_init(&h.dict, h.allocator)
	h.stream_ids = make([dynamic]prim.Id, h.allocator)
	h.rdicts = make([dynamic]crdt.Actor_Dict, h.allocator)
	h.applied = make([dynamic]i64, h.allocator)
	h.files = make(map[fstree.Inode_Id]^File_State, h.allocator)
	h.moves = make([dynamic]fstree.Move_Ref, h.allocator)
	h.io = make([dynamic]u8, h.allocator)
	h.touched = make([dynamic]fstree.Inode_Id, h.allocator)
	h.touched_set = make(map[fstree.Inode_Id]struct{}, h.allocator)
	h.pins = make([dynamic]odb.Oid, h.allocator)
	h.markers = make([dynamic]Git_Marker, h.allocator)
	lp, _ := path_join(h.dir, "lv.idx", context.temp_allocator)
	lfd, lerr := prim.open_file(h.vfs, lp, {.Write, .Create}, 0o600)
	if lerr != .None {
		journal.journal_close(&h.journal)
		kv_close(&h.kv)
		return from_prim(lerr)
	}
	h.lvidx = lfd
	lsize, _ := prim.file_size(h.vfs, lfd)
	h.lvidx_n = u64(lsize) / LVIDX_REC
	h.awake = true
	err := load_state(h)
	if err == .None {
		err = replay_own(h)
	}
	if err != .None {
		history_sleep(h)
		return err
	}
	h.mark_fp = history_fp(h)
	return .None
}

history_sleep :: proc(h: ^History) {
	if !h.awake {
		return
	}
	views_stale(h)
	history_unload_files(h)
	fstree.destroy(&h.tree)
	crdt.graph_destroy(&h.g)
	crdt.dict_destroy(&h.dict)
	for &d in h.rdicts {
		crdt.dict_destroy(&d)
	}
	delete(h.rdicts)
	journal.journal_close(&h.journal)
	kv_close(&h.kv)
	prim.close_file(h.vfs, h.lvidx)
	h.lvidx = prim.INVALID_FD
	delete(h.stream_ids)
	delete(h.applied)
	delete(h.files)
	delete(h.moves)
	delete(h.io)
	delete(h.touched)
	delete(h.touched_set)
	delete(h.pins)
	markers_clear(h)
	delete(h.markers)
	if h.blob_data != nil {
		delete(h.blob_data, h.allocator)
		h.blob_data = nil
	}
	h.awake = false
}

history_heads :: proc(h: ^History, allocator := context.allocator) -> Version {
	return crdt.graph_version_ids(&h.g, h.g.heads[:], allocator)
}

history_line :: proc(h: ^History, name: string, allocator := context.allocator) -> (v: Version, found: bool, err: Error) {
	key := line_key(name, context.temp_allocator)
	data, ok := kv_get(&h.kv, key, context.temp_allocator) or_return
	own: Version
	if ok {
		own = decode_version(data, context.temp_allocator) or_return
	}
	acc := make([dynamic]crdt.Lv, context.temp_allocator)
	tmp := make([dynamic]crdt.Lv, context.temp_allocator)
	out := make([dynamic]crdt.Lv, context.temp_allocator)
	merged := false
	if ok && crdt.graph_version_lvs(&h.g, own, &acc) != .None {
		v = slice.clone(own, allocator)
		return v, true, .None
	}
	for sid, i in h.stream_ids {
		if i == 0 || sid == h.self {
			continue
		}
		if !(remote_line(h, sid, name, &tmp) or_return) {
			continue
		}
		crdt.version_union(&h.g, acc[:], tmp[:], &out)
		clear(&acc)
		append(&acc, ..out[:])
		merged = true
	}
	if !merged {
		if !ok {
			return nil, false, .None
		}
		v = slice.clone(own, allocator)
		return v, true, .None
	}
	return crdt.graph_version_ids(&h.g, acc[:], allocator), true, .None
}

@(private)
remote_line :: proc(h: ^History, stream: prim.Id, name: string, lvs: ^[dynamic]crdt.Lv) -> (found: bool, err: Error) {
	for tag in ([2]u8{'P', 'L'}) {
		data, ok := kv_get(&h.kv, remote_line_key(tag, stream, name, context.temp_allocator), context.temp_allocator) or_return
		if !ok {
			continue
		}
		x := decode_version(data, context.temp_allocator) or_return
		if crdt.graph_version_lvs(&h.g, x, lvs) == .None {
			return true, .None
		}
	}
	return false, .None
}

history_set_line :: proc(h: ^History, name: string, v: Version) -> Error {
	key := line_key(name, context.temp_allocator)
	sorted := slice.clone(v, context.temp_allocator)
	slice.sort_by(sorted, crdt.op_id_less)
	buf := make([dynamic]u8, context.temp_allocator)
	encode_version(&buf, sorted)
	old, had := kv_get(&h.kv, key, context.temp_allocator) or_return
	if had && string(old) == string(buf[:]) {
		return .None
	}
	clear(&h.io)
	w := prim.writer(&h.io)
	prim.write_u8(&w, REC_LINE)
	prim.write_str(&w, name)
	prim.write_bytes(&w, buf[:])
	if _, jerr := journal.journal_append(&h.journal, h.io[:]); jerr != .None {
		return .Io
	}
	if journal.journal_commit(&h.journal) != .None {
		return .Io
	}
	stream_index(h, h.self)
	h.applied[0] = journal.journal_durable_len(&h.journal)
	kv_put(&h.kv, key, buf[:]) or_return
	return kv_commit(&h.kv)
}

@(private)
remote_line_key :: proc(tag: u8, stream: prim.Id, name: string, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, 2 + 16 + len(name), allocator)
	out[0] = tag
	out[1] = ':'
	s := stream
	copy(out[2:], s[:])
	copy(out[18:], name)
	return out
}

@(private)
decode_line_record :: proc(body: []u8) -> (name: string, version: []u8, ok: bool) {
	rd := prim.reader(body[1:])
	name = prim.read_str(&rd)
	version = prim.read_bytes(&rd)
	return name, version, prim.reader_ok(&rd)
}

@(private)
apply_line_record :: proc(h: ^History, stream: prim.Id, body: []u8) -> Error {
	name, vb, ok := decode_line_record(body)
	if !ok {
		return .Corrupt
	}
	v := decode_version(vb, context.temp_allocator) or_return
	if stream == h.self {
		return kv_put(&h.kv, line_key(name, context.temp_allocator), vb)
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) == .None {
		kv_put(&h.kv, remote_line_key('L', stream, name, context.temp_allocator), vb) or_return
		pk := remote_line_key('P', stream, name, context.temp_allocator)
		if _, pending := kv_get(&h.kv, pk, context.temp_allocator) or_return; pending {
			kv_del(&h.kv, pk) or_return
		}
		return .None
	}
	return kv_put(&h.kv, remote_line_key('P', stream, name, context.temp_allocator), vb)
}

history_contains :: proc(h: ^History, v: Version, id: crdt.Op_Id) -> bool {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return false
	}
	lv, ok := crdt.graph_lv(&h.g, id)
	return ok && crdt.graph_contains(&h.g, lvs[:], lv)
}

history_next_seq :: proc(h: ^History, actor: prim.Id) -> u64 {
	return crdt.graph_known(&h.g, actor)
}

history_lamport_after :: proc(h: ^History, parents: Version) -> u64 {
	l: u64 = 0
	for p in parents {
		lv, ok := crdt.graph_lv(&h.g, p)
		if ok {
			l = max(l, crdt.graph_lamport(&h.g, lv))
		}
	}
	return l + 1
}

history_actor_ix :: proc(h: ^History, actor: prim.Id) -> u32 {
	return crdt.graph_intern(&h.g, actor)
}

history_actor :: proc(h: ^History, ix: u32) -> prim.Id {
	if int(ix) < len(h.g.actors) {
		return h.g.actors[ix]
	}
	return {}
}

inode_op :: proc(h: ^History, id: fstree.Inode_Id) -> crdt.Op_Id {
	if id == fstree.ROOT {
		return {}
	}
	return crdt.Op_Id{history_actor(h, id.actor), id.seq}
}

op_inode :: proc(h: ^History, id: crdt.Op_Id) -> fstree.Inode_Id {
	if id == {} {
		return fstree.ROOT
	}
	return fstree.Inode_Id{crdt.graph_intern(&h.g, id.actor), id.seq}
}

Import_File :: struct {
	inode:  fstree.Inode_Id,
	oid:    odb.Oid,
	len:    i64,
	first:  crdt.Op_Id,
	last:   crdt.Op_Id,
}

history_commit_import :: proc(h: ^History, b: ^crdt.Batch) -> (off: i64, err: Error) {
	parents := make([dynamic]crdt.Lv, context.temp_allocator)
	skip, gerr := crdt.graph_check(&h.g, b, &parents)
	if gerr != .None || skip != 0 {
		return 0, .Invalid
	}
	if !import_valid(h, b) {
		return 0, .Invalid
	}
	off = journal_batch(h, b, REC_IMPORT) or_return
	import_apply(h, b, 0, u64(off)) or_return
	h.applied[0] = journal.journal_durable_len(&h.journal)
	return off, history_persist(h)
}

@(private)
import_valid :: proc(h: ^History, b: ^crdt.Batch) -> bool {
	created := make(map[u64]bool, context.temp_allocator)
	filled := make(map[u64]bool, context.temp_allocator)
	pos: u64
	for op in b.ops {
		if op.kind == .Opaque {
			if len(op.content) > 0 && op.content[0] == TOP_CREATE {
				created[b.seq + pos] = true
			}
		} else {
			if op.kind != .Insert_Ref || op.pos != 0 || op.target.actor != b.actor || !created[op.target.seq] || filled[op.target.seq] {
				return false
			}
			filled[op.target.seq] = true
		}
		pos += u64(op.len)
	}
	return true
}

@(private)
import_apply :: proc(h: ^History, b: ^crdt.Batch, stream: u32, off: u64) -> Error {
	first, _, aerr := crdt.graph_add(&h.g, b)
	if aerr != .None {
		return .Corrupt
	}
	lvidx_add(h, first, crdt.batch_len(b), stream, off)
	apply_tree_ops(h, b, first, 0, stream, off) or_return
	buf := make([dynamic]u8, context.temp_allocator)
	pos: u64
	for op in b.ops {
		at := b.seq + pos
		pos += u64(op.len)
		if op.kind != .Insert_Ref {
			continue
		}
		rec: File_Record
		rec.has_base = true
		rec.base = Op_Ref{stream, off, 0, u32(pos)}
		rec.has_cp = true
		rec.cp_text = fshist.oid_from_crdt(op.ref.oid)
		rec.cp_len = i64(op.len)
		rec.cp_version = make([dynamic]crdt.Op_Id, context.temp_allocator)
		rec.cp_spans = make([dynamic]crdt.Author_Span, context.temp_allocator)
		append(&rec.cp_version, crdt.Op_Id{b.actor, at + u64(op.len) - 1})
		append(&rec.cp_spans, crdt.Author_Span{id = {b.actor, at}, op = {b.actor, at}, len = op.len})
		clear(&buf)
		encode_file_record(&buf, &rec)
		ino := op_inode(h, op.target)
		kv_put(&h.kv, inode_key("f", ino), buf[:]) or_return
		views_stale(h, ino)
		if f, ok := h.files[ino]; ok {
			file_free(h, f)
			delete_key(&h.files, ino)
		}
	}
	return .None
}

history_commit_local :: proc(h: ^History, b: ^crdt.Batch, line: Maybe(string) = nil) -> (off: i64, err: Error) {
	parents := make([dynamic]crdt.Lv, context.temp_allocator)
	skip, gerr := crdt.graph_check(&h.g, b, &parents)
	if gerr != .None || skip != 0 {
		return 0, .Invalid
	}
	n := crdt.batch_len(b)
	valid := n
	for sp in target_spans(b, context.temp_allocator) {
		f := batch_file(h, op_inode(h, sp.target), b) or_return
		view, vskip, lead := span_view(b, sp, 0)
		v, terr := crdt.text_check(&f.text, &h.g, &f.log, &view, sp.target, vskip, parents[:])
		if terr != .None {
			return 0, .Corrupt
		}
		if v < crdt.batch_len(&view) - vskip {
			valid = min(valid, lead + v)
		}
	}
	if valid != n {
		return 0, .Invalid
	}
	lkey, lver: []u8
	lname, has_line := line.?
	if has_line {
		lkey, lver = line_after(h, lname, parents[:], crdt.Op_Id{b.actor, b.seq + u64(n) - 1}) or_return
	}
	o := journal_batch(h, b, REC_BATCH, lver == nil) or_return
	if lver != nil {
		clear(&h.io)
		w := prim.writer(&h.io)
		prim.write_u8(&w, REC_LINE)
		prim.write_str(&w, lname)
		prim.write_bytes(&w, lver)
		if _, jerr := journal.journal_append(&h.journal, h.io[:]); jerr != .None {
			journal.journal_abort(&h.journal)
			return 0, .Io
		}
		journal_seal(h) or_return
	}
	apply_batch(h, b, 0, u64(o)) or_return
	h.applied[0] = journal.journal_durable_len(&h.journal)
	if lver != nil {
		kv_put(&h.kv, lkey, lver) or_return
	}
	return o, history_persist(h)
}

history_marked :: proc(h: ^History, from: i64, mark: []u8, out: ^[dynamic]Intent) -> Error {
	end := journal.journal_durable_len(&h.journal)
	if from >= end {
		return .None
	}
	r: journal.Reader
	journal.journal_reader(&h.journal, &r, context.temp_allocator)
	defer journal.reader_close(&r)
	off := from
	for off < end {
		body, next, jerr := journal.record_at(&r, off)
		if jerr == .Redacted && next > off {
			off = next
			continue
		}
		if jerr != .None {
			return from_journal(jerr)
		}
		off = next
		if len(body) == 0 || body[0] != REC_BATCH {
			continue
		}
		b, derr := crdt.batch_decode(body[1:], context.temp_allocator, &h.dict)
		if derr != .None {
			return .Corrupt
		}
		for op in b.ops {
			if op.kind == .Opaque && string(op.content) == string(mark) {
				append(out, Intent{b.actor, b.seq, u64(crdt.batch_len(&b))})
				break
			}
		}
	}
	return .None
}

@(private)
line_after :: proc(h: ^History, name: string, parents: []crdt.Lv, last: crdt.Op_Id) -> (key: []u8, version: []u8, err: Error) {
	key = line_key(name, context.temp_allocator)
	out := make([dynamic]crdt.Op_Id, context.temp_allocator)
	if cur, found := history_line(h, name, context.temp_allocator) or_return; found {
		for id in cur {
			if lv, known := crdt.graph_lv(&h.g, id); known && crdt.graph_contains(&h.g, parents, lv) {
				continue
			}
			append(&out, id)
		}
	}
	append(&out, last)
	slice.sort_by(out[:], crdt.op_id_less)
	buf := make([dynamic]u8, context.temp_allocator)
	encode_version(&buf, out[:])
	return key, buf[:], .None
}

@(private)
journal_seal :: proc(h: ^History) -> Error {
	if h.db != nil {
		if e := odb.barrier(h.db); e != .None {
			journal.journal_abort(&h.journal)
			return from_odb(e)
		}
	}
	if journal.journal_commit(&h.journal) != .None {
		return .Io
	}
	if len(h.applied) == 0 {
		append(&h.applied, 0)
		append(&h.stream_ids, h.self)
	}
	return .None
}

@(private)
journal_batch :: proc(h: ^History, b: ^crdt.Batch, kind := REC_BATCH, commit := true) -> (off: i64, err: Error) {
	fresh := make([dynamic]prim.Id, context.temp_allocator)
	note_actor :: proc(h: ^History, fresh: ^[dynamic]prim.Id, id: prim.Id) {
		if _, ok := crdt.dict_find(&h.dict, id); ok {
			return
		}
		for x in fresh {
			if x == id {
				return
			}
		}
		append(fresh, id)
	}
	note_actor(h, &fresh, b.actor)
	for p in b.parents {
		note_actor(h, &fresh, p.actor)
	}
	for op in b.ops {
		if op.target != {} {
			note_actor(h, &fresh, op.target.actor)
		}
	}
	if len(fresh) > 0 {
		clear(&h.io)
		w := prim.writer(&h.io)
		prim.write_u8(&w, REC_ACTORS)
		prim.write_uvarint(&w, u64(len(fresh)))
		for id in fresh {
			prim.write_id(&w, id)
		}
		if _, jerr := journal.journal_append(&h.journal, h.io[:]); jerr != .None {
			return 0, .Io
		}
		for id in fresh {
			crdt.dict_add(&h.dict, id)
		}
	}
	clear(&h.io)
	append(&h.io, kind)
	if crdt.batch_encode(b, &h.io, &h.dict) != .None {
		journal.journal_abort(&h.journal)
		return 0, .Too_Large
	}
	o, jerr := journal.journal_append(&h.journal, h.io[:])
	if jerr != .None {
		return 0, .Io
	}
	if commit {
		journal_seal(h) or_return
	}
	return o, .None
}

history_admit :: proc(h: ^History, stream: prim.Id, off: i64, body: []u8) -> (admitted: int, err: Error) {
	if len(body) == 0 {
		return 0, .None
	}
	si := stream_index(h, stream)
	if body[0] == REC_ACTORS {
		rd := prim.reader(body[1:])
		n := prim.read_uvarint(&rd)
		if n > u64(len(body)) {
			return 0, .Corrupt
		}
		d := stream_dict(h, si)
		for _ in 0 ..< n {
			crdt.dict_add(d, prim.read_id(&rd))
		}
		if !prim.reader_ok(&rd) {
			return 0, .Corrupt
		}
		return 0, history_persist(h)
	}
	if body[0] == REC_REPLACE {
		apply_replace_record(h, si, body, u64(off)) or_return
		if h.applied[si] < off + 1 {
			h.applied[si] = off + 1
		}
		return 0, history_persist(h)
	}
	if body[0] == REC_ALIAS {
		rd := prim.reader(body[1:])
		n := prim.read_uvarint(&rd)
		if n > u64(len(body)) {
			return 0, .Corrupt
		}
		for _ in 0 ..< n {
			prim.read_str(&rd)
		}
		commit := prim.read_str(&rd)
		vb := prim.read_bytes(&rd)
		if !prim.reader_ok(&rd) {
			return 0, .Corrupt
		}
		key := make([]u8, 3 + len(commit), context.temp_allocator)
		copy(key, "cv:")
		copy(key[3:], commit)
		kv_put(&h.kv, key, vb) or_return
		if h.applied[si] < off + 1 {
			h.applied[si] = off + 1
		}
		return 0, history_persist(h)
	}
	if body[0] == REC_LINE {
		apply_line_record(h, stream, body) or_return
		if h.applied[si] < off + 1 {
			h.applied[si] = off + 1
		}
		return 0, history_persist(h)
	}
	if body[0] == REC_SEAL {
		apply_seal_record(h, si, body) or_return
		if h.applied[si] < off + 1 {
			h.applied[si] = off + 1
		}
		return 0, history_persist(h)
	}
	if body[0] == REC_REDACT {
		apply_redact_record(h, body, true) or_return
		if h.applied[si] < off + 1 {
			h.applied[si] = off + 1
		}
		return 0, history_persist(h)
	}
	if body[0] != REC_BATCH && body[0] != REC_IMPORT {
		return 0, .None
	}
	dict := stream_dict(h, si)
	if body[0] == REC_IMPORT {
		return admit_import(h, si, off, body, dict)
	}
	b, derr := crdt.batch_decode(body[1:], context.temp_allocator, dict)
	if derr != .None {
		return 0, .Corrupt
	}
	parents := make([dynamic]crdt.Lv, context.temp_allocator)
	skip, gerr := crdt.graph_check(&h.g, &b, &parents)
	if gerr == .Missing {
		return 0, .Not_Found
	}
	if gerr != .None {
		return 0, .Corrupt
	}
	n := crdt.batch_len(&b)
	if skip >= n {
		return 0, .None
	}
	valid := n - skip
	for sp in target_spans(&b, context.temp_allocator) {
		f := batch_file(h, op_inode(h, sp.target), &b) or_return
		view, vskip, lead := span_view(&b, sp, skip)
		v, terr := crdt.text_check(&f.text, &h.g, &f.log, &view, sp.target, vskip, parents[:])
		if terr != .None {
			return 0, .Corrupt
		}
		if v < crdt.batch_len(&view) - vskip {
			valid = min(valid, lead + v)
		}
	}
	if valid == 0 {
		return 0, .Invalid
	}
	use := &b
	cut: crdt.Batch
	if skip + valid < n {
		cut, _ = crdt.batch_slice(&b, 0, skip + valid, context.temp_allocator)
		use = &cut
	}
	apply_batch(h, use, si, u64(off)) or_return
	if int(si) < len(h.applied) && h.applied[si] < off + 1 {
		h.applied[si] = off + 1
	}
	return valid, history_persist(h)
}

@(private)
admit_import :: proc(h: ^History, si: u32, off: i64, body: []u8, dict: ^crdt.Actor_Dict) -> (admitted: int, err: Error) {
	b, derr := crdt.batch_decode(body[1:], context.temp_allocator, dict)
	if derr != .None {
		return 0, .Corrupt
	}
	parents := make([dynamic]crdt.Lv, context.temp_allocator)
	skip, gerr := crdt.graph_check(&h.g, &b, &parents)
	if gerr == .Missing {
		return 0, .Not_Found
	}
	n := crdt.batch_len(&b)
	if gerr != .None || (skip > 0 && skip < n) || !import_valid(h, &b) {
		return 0, .Corrupt
	}
	if skip >= n {
		return 0, .None
	}
	import_apply(h, &b, si, u64(off)) or_return
	if int(si) < len(h.applied) && h.applied[si] < off + 1 {
		h.applied[si] = off + 1
	}
	return n, history_persist(h)
}

history_persist :: proc(h: ^History) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	buf := make([dynamic]u8, context.temp_allocator)
	keys := make([dynamic]crdt.Page_Key, context.temp_allocator)
	crdt.graph_dirty(&h.g, &keys)
	for k in keys {
		clear(&buf)
		if crdt.graph_page_encode(&h.g, k, &buf) != .None {
			return .Corrupt
		}
		kv_put(&h.kv, page_key(k), buf[:]) or_return
	}
	clear(&buf)
	if crdt.graph_meta_encode(&h.g, &buf) != .None {
		return .Too_Large
	}
	kv_put(&h.kv, transmute([]u8)string("g"), buf[:]) or_return
	inodes, nodes, derr := fstree.dirty(&h.tree, context.temp_allocator)
	if derr != nil {
		return .No_Memory
	}
	slice.sort_by(inodes, inode_less)
	slice.sort_by(nodes, proc(a, b: fstree.Node_State) -> bool {
		if a.key.dir != b.key.dir {
			return inode_less(a.key.dir, b.key.dir)
		}
		return a.key.node < b.key.node
	})
	for id in inodes {
		clear(&buf)
		if fstree.encode_inode_record(&h.tree, id, &buf) {
			kv_put(&h.kv, inode_key("ti", id), buf[:]) or_return
		}
	}
	for ns in nodes {
		k := node_key(ns.key)
		if ns.deleted {
			kv_del(&h.kv, k) or_return
			continue
		}
		clear(&buf)
		if fstree.encode_node_record(&h.tree, ns.key, &buf) {
			kv_put(&h.kv, k, buf[:]) or_return
		}
	}
	fstree.mark_persisted(&h.tree)
	persist_moves(h) or_return
	pins_persist(h) or_return
	for id in sorted_inodes(h.files) {
		if f := h.files[id]; f.dirty {
			persist_file(h, id, f) or_return
		}
	}
	clear(&buf)
	w := prim.writer(&buf)
	prim.write_u8(&w, 2)
	prim.write_uvarint(&w, u64(len(h.stream_ids)))
	for s, i in h.stream_ids {
		prim.write_id(&w, s)
		prim.write_uvarint(&w, u64(h.applied[i]))
		if i > 0 {
			d := &h.rdicts[i]
			prim.write_uvarint(&w, u64(len(d.ids)))
			for id in d.ids {
				prim.write_id(&w, id)
			}
		}
	}
	prim.write_uvarint(&w, u64(len(h.dict.ids)))
	for id in h.dict.ids {
		prim.write_id(&w, id)
	}
	prim.write_uvarint(&w, h.moves_count)
	kv_put(&h.kv, transmute([]u8)string("s"), buf[:]) or_return
	kv_commit(&h.kv) or_return
	if !h.opts.deferred {
		return history_flush_staged(h, max(u64))
	}
	return .None
}

Staged_Blob :: struct {
	oid:  odb.Oid,
	data: []u8,
	mark: u64,
}

history_stage_blob :: proc(h: ^History, data: []u8) -> (oid: odb.Oid, err: Error) {
	if h.db == nil {
		return {}, .Invalid
	}
	oid = from_odb_v(odb.hash(h.db.format, .Blob, data)) or_return
	if odb.exists(h.db, oid) {
		return oid, .None
	}
	for s in h.staged {
		if s.oid == oid {
			return oid, .None
		}
	}
	copy_data := make([]u8, len(data), h.allocator)
	copy(copy_data, data)
	if h.opts.deferred {
		h.mark += 1
	}
	append(&h.staged, Staged_Blob{oid, copy_data, h.mark})
	return oid, .None
}

@(private)
history_staged_data :: proc(h: ^History, oid: odb.Oid) -> ([]u8, bool) {
	for s in h.staged {
		if s.oid == oid {
			return s.data, true
		}
	}
	return nil, false
}

history_flush_staged :: proc(h: ^History, upto: u64) -> Error {
	if len(h.staged) == 0 {
		return .None
	}
	i := 0
	for i < len(h.staged) {
		s := h.staged[i]
		if s.mark > upto {
			i += 1
			continue
		}
		if h.db != nil {
			_ = from_odb_v(odb.write(h.db, .Blob, s.data)) or_return
			history_note_blob(h, s.oid)
		}
		delete(s.data, h.allocator)
		ordered_remove(&h.staged, i)
	}
	return .None
}

history_unload_files :: proc(h: ^History) {
	for _, f in h.files {
		file_free(h, f)
	}
	clear(&h.files)
	if h.blob_data != nil {
		delete(h.blob_data, h.allocator)
		h.blob_data = nil
	}
	h.blob_cache = {}
}

history_trim :: proc(h: ^History) {
	history_unload_files(h)
	crdt.graph_trim(&h.g)
	fstree.trim(&h.tree, 64)
	clear(&h.touched)
	if len(h.touched_set) > 4096 {
		delete(h.touched_set)
		h.touched_set = make(map[fstree.Inode_Id]struct{}, h.allocator)
	} else {
		clear(&h.touched_set)
	}
	markers_clear(h)
	shrink(&h.io)
}

history_file :: proc(h: ^History, inode: fstree.Inode_Id) -> (f: ^File_State, err: Error) {
	if s, ok := h.files[inode]; ok {
		return s, .None
	}
	f = new(File_State, h.allocator)
	f.inode = inode
	f.new_refs = make([dynamic]Op_Ref, h.allocator)
	err = read_file_record(h, inode, &f.rec)
	if err == .None {
		err = load_text(h, f, h.g.heads[:])
	}
	if err != .None {
		file_free(h, f)
		return nil, err
	}
	h.files[inode] = f
	return f, .None
}

history_text_at :: proc(h: ^History, inode: fstree.Inode_Id, v: Version, allocator := context.allocator) -> (data: []u8, err: Error) {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return nil, .Not_Found
	}
	tmp: File_State
	tmp.inode = inode
	owned := false
	if f, ok := h.files[inode]; ok {
		if f.loaded && crdt.frontier_eq(f.text.version[:], lvs[:]) {
			return crdt.text_bytes(&f.text, allocator), .None
		}
		tmp.rec = f.rec
		tmp.new_refs = f.new_refs
	} else {
		owned = true
		if err = read_file_record(h, inode, &tmp.rec); err != .None {
			delete(tmp.rec.cp_version)
			delete(tmp.rec.cp_spans)
			return nil, err
		}
	}
	defer if owned {
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	defer fshist.text_drop(&tmp.st)
	if err = load_text(h, &tmp, lvs[:]); err != .None {
		return nil, err
	}
	return crdt.text_bytes(&tmp.text, allocator), .None
}

history_text_oid :: proc(h: ^History, inode: fstree.Inode_Id, v: Version) -> (oid: odb.Oid, ok: bool, err: Error) {
	if h.db == nil {
		return {}, false, .None
	}
	rec: File_Record
	refs := 0
	owned := false
	defer if owned {
		delete(rec.cp_version)
		delete(rec.cp_spans)
	}
	if f, cached := h.files[inode]; cached {
		rec = f.rec
		refs = len(f.new_refs)
	} else {
		owned = true
		read_file_record(h, inode, &rec) or_return
	}
	if !rec.has_cp || refs != 0 || rec.ops != rec.cp_count || rec.cp_len <= 0 {
		return {}, false, .None
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return {}, false, .None
	}
	cpv := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, rec.cp_version[:], &cpv) != .None {
		return {}, false, .None
	}
	if !crdt.graph_contains_all(&h.g, lvs[:], cpv[:]) || !odb.exists(h.db, odb.Oid(rec.cp_text)) {
		return {}, false, .None
	}
	return odb.Oid(rec.cp_text), true, .None
}

history_text_spans_at :: proc(h: ^History, inode: fstree.Inode_Id, v: []crdt.Lv, allocator := context.allocator) -> (data: []u8, spans: []crdt.Author_Span, err: Error) {
	tmp: File_State
	tmp.inode = inode
	defer {
		fshist.text_drop(&tmp.st)
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	read_file_record(h, inode, &tmp.rec) or_return
	load_text(h, &tmp, v) or_return
	return crdt.text_bytes(&tmp.text, allocator), crdt.text_spans(&tmp.text, &h.g, allocator), .None
}

@(private)
blob_log_add :: proc(h: ^History, inode: fstree.Inode_Id, reg: Blob_Reg) -> Error {
	key := inode_key("fb", inode)
	data, _ := kv_get(&h.kv, key, context.temp_allocator) or_return
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		e := read_blob_reg(&rd)
		if !prim.reader_ok(&rd) {
			return .Corrupt
		}
		if e.actor == reg.actor && e.seq == reg.seq {
			return .None
		}
	}
	buf := make([dynamic]u8, 0, len(data) + 64, context.temp_allocator)
	append(&buf, ..data)
	w := prim.writer(&buf)
	prim.write_uvarint(&w, reg.lamport)
	prim.write_id(&w, reg.actor)
	prim.write_uvarint(&w, reg.seq)
	oid := reg.oid
	prim.write_raw(&w, oid[:])
	prim.write_ivarint(&w, reg.size)
	return kv_put(&h.kv, key, buf[:])
}

@(private)
read_blob_reg :: proc(rd: ^prim.Reader) -> (e: Blob_Reg) {
	e.lamport = prim.read_uvarint(rd)
	e.actor = prim.read_id(rd)
	e.seq = prim.read_uvarint(rd)
	prim.read_fixed(rd, e.oid[:])
	e.size = prim.read_ivarint(rd)
	return
}

history_blob_at :: proc(h: ^History, inode: fstree.Inode_Id, v: []crdt.Lv) -> (reg: Blob_Reg, found: bool, err: Error) {
	data, ok := kv_get(&h.kv, inode_key("fb", inode), context.temp_allocator) or_return
	if !ok {
		return history_blob(h, inode)
	}
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		e := read_blob_reg(&rd)
		if !prim.reader_ok(&rd) {
			return {}, false, .Corrupt
		}
		lv, known := crdt.graph_lv(&h.g, crdt.Op_Id{e.actor, e.seq})
		if !known || !crdt.graph_contains(&h.g, v, lv) {
			continue
		}
		if !found || blob_newer(e, reg) {
			reg = e
			found = true
		}
	}
	return reg, found, .None
}

history_blob :: proc(h: ^History, inode: fstree.Inode_Id) -> (reg: Blob_Reg, found: bool, err: Error) {
	if f, ok := h.files[inode]; ok {
		return f.rec.blob, f.rec.has_blob, .None
	}
	rec: File_Record
	defer {
		delete(rec.cp_version)
		delete(rec.cp_spans)
	}
	read_file_record(h, inode, &rec) or_return
	return rec.blob, rec.has_blob, .None
}

history_markers :: proc(h: ^History) -> []Git_Marker {
	return h.markers[:]
}

history_touched :: proc(h: ^History) -> []fstree.Inode_Id {
	return h.touched[:]
}

@(private)
markers_clear :: proc(h: ^History) {
	for m in h.markers {
		delete(m.kind, h.allocator)
		delete(m.branch, h.allocator)
		delete(m.commit, h.allocator)
	}
	clear(&h.markers)
}

@(private)
stream_index :: proc(h: ^History, id: prim.Id) -> u32 {
	if len(h.stream_ids) == 0 {
		append(&h.stream_ids, h.self)
		append(&h.applied, 0)
		d0: crdt.Actor_Dict
		crdt.dict_init(&d0, h.allocator)
		append(&h.rdicts, d0)
	}
	for s, i in h.stream_ids {
		if s == id {
			return u32(i)
		}
	}
	append(&h.stream_ids, id)
	append(&h.applied, 0)
	d: crdt.Actor_Dict
	crdt.dict_init(&d, h.allocator)
	append(&h.rdicts, d)
	return u32(len(h.stream_ids) - 1)
}

@(private)
Target_Span :: struct {
	target: crdt.Op_Id,
	lo:     int,
	hi:     int,
	prefix: int,
}

@(private)
target_spans :: proc(b: ^crdt.Batch, allocator: runtime.Allocator) -> []Target_Span {
	out := make([dynamic]Target_Span, allocator)
	at := make(map[crdt.Op_Id]int, allocator)
	pos := 0
	for op, i in b.ops {
		if op.kind != .Opaque {
			if k, ok := at[op.target]; ok {
				out[k].hi = i + 1
			} else {
				at[op.target] = len(out)
				append(&out, Target_Span{op.target, i, i + 1, pos})
			}
		}
		pos += op.len
	}
	return out[:]
}

@(private)
span_view :: proc(b: ^crdt.Batch, sp: Target_Span, skip: int) -> (view: crdt.Batch, vskip: int, lead: int) {
	lead = max(0, sp.prefix - skip)
	view = b^
	view.ops = b.ops[sp.lo:sp.hi]
	view.seq = b.seq + u64(lead)
	return view, max(0, skip - sp.prefix), lead
}

@(private)
apply_batch :: proc(h: ^History, b: ^crdt.Batch, stream: u32, off: u64) -> Error {
	spans := target_spans(b, context.temp_allocator)
	files := make([]^File_State, len(spans), context.temp_allocator)
	for sp, i in spans {
		f := history_file(h, op_inode(h, sp.target)) or_return
		if f.from_cp && !descends_from_cp(h, f, b) {
			prev := make([dynamic]crdt.Lv, context.temp_allocator)
			append(&prev, ..f.text.version[:])
			load_text(h, f, prev[:], true) or_return
		}
		files[i] = f
	}
	first, skip, gerr := crdt.graph_add(&h.g, b)
	if gerr != .None {
		return .Corrupt
	}
	n := crdt.batch_len(b)
	for sp, i in spans {
		ino := op_inode(h, sp.target)
		f := files[i]
		append(&f.new_refs, Op_Ref{stream, off, u32(skip), u32(n)})
		f.dirty = true
		note_touched(h, ino)
		view, vskip, lead := span_view(b, sp, skip)
		crdt.log_add_batch(&f.log, &h.g, &view, sp.target, first + crdt.Lv(lead), vskip)
		views_feed(h, ino, &view, sp.target, first + crdt.Lv(lead), vskip)
	}
	lvidx_add(h, first, n - skip, stream, off)
	apply_tree_ops(h, b, first, skip, stream, off) or_return
	for sp, i in spans {
		ino := op_inode(h, sp.target)
		f := files[i]
		found := make([dynamic]crdt.Conflict, context.temp_allocator)
		if e := crdt.text_merge(&f.text, &h.g, &f.log, h.g.heads[:], &found); e != .None {
			return .Corrupt
		}
		record_text_conflicts(h, ino, found[:]) or_return
	}
	return .None
}

@(private)
batch_file :: proc(h: ^History, ino: fstree.Inode_Id, b: ^crdt.Batch) -> (f: ^File_State, err: Error) {
	f = history_file(h, ino) or_return
	if f.from_cp && !descends_from_cp(h, f, b) {
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		append(&lvs, ..h.g.heads[:])
		load_text(h, f, lvs[:], true) or_return
	}
	return f, .None
}

@(private)
descends_from_cp :: proc(h: ^History, f: ^File_State, b: ^crdt.Batch) -> bool {
	cpv := make([dynamic]crdt.Lv, context.temp_allocator)
	ps := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, f.rec.cp_version[:], &cpv) != .None || crdt.graph_version_lvs(&h.g, b.parents, &ps) != .None {
		return false
	}
	return crdt.graph_contains_all(&h.g, ps[:], cpv[:])
}

LVIDX_REC :: fshist.LVIDX_REC

@(private)
lvidx_add :: proc(h: ^History, first: crdt.Lv, n: int, stream: u32, off: u64) {
	if h.lvidx_n > 0 {
		b: [LVIDX_REC]u8
		got, err := prim.read_at(h.vfs, h.lvidx, b[:], i64((h.lvidx_n - 1) * LVIDX_REC))
		if err == .None && got == LVIDX_REC && i64(prim.get_u64le(b[0:8])) >= i64(first) {
			return
		}
	}
	b: [LVIDX_REC]u8
	prim.put_u64le(b[0:8], u64(first))
	prim.put_u32le(b[8:12], stream)
	prim.put_u32le(b[12:16], u32(n))
	prim.put_u64le(b[16:24], off)
	if prim.write_at(h.vfs, h.lvidx, b[:], i64(h.lvidx_n * LVIDX_REC)) == .None {
		h.lvidx_n += 1
	}
}

history_batch_at :: proc(h: ^History, lv: crdt.Lv) -> (first: crdt.Lv, n: int, stream: u32, off: u64, found: bool) {
	lo, hi := u64(0), h.lvidx_n
	b: [LVIDX_REC]u8
	for lo < hi {
		mid := (lo + hi) / 2
		got, err := prim.read_at(h.vfs, h.lvidx, b[:], i64(mid * LVIDX_REC))
		if err != .None || got != LVIDX_REC {
			return
		}
		if crdt.Lv(prim.get_u64le(b[0:8])) <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return
	}
	got, err := prim.read_at(h.vfs, h.lvidx, b[:], i64((lo - 1) * LVIDX_REC))
	if err != .None || got != LVIDX_REC {
		return
	}
	first = crdt.Lv(prim.get_u64le(b[0:8]))
	n = int(prim.get_u32le(b[12:16]))
	if lv >= first + n {
		return
	}
	return first, n, prim.get_u32le(b[8:12]), prim.get_u64le(b[16:24]), true
}

history_read_batch :: proc(h: ^History, stream: u32, off: u64, allocator := context.allocator) -> (b: crdt.Batch, err: Error) {
	buf := make([dynamic]u8, context.temp_allocator)
	body := read_stream(h, stream, i64(off), &buf) or_return
	payload, ok := batch_payload(body)
	if !ok {
		return {}, .Corrupt
	}
	dict := stream_dict(h, stream)
	bb, derr := crdt.batch_decode(payload, allocator, dict)
	if derr != .None {
		return {}, .Corrupt
	}
	return bb, .None
}

@(private)
apply_tree_ops :: proc(h: ^History, b: ^crdt.Batch, first: crdt.Lv, skip: int, stream: u32, off: u64) -> Error {
	lv := first
	rest := skip
	pos := 0
	for op in b.ops {
		if rest >= op.len {
			rest -= op.len
			pos += op.len
			continue
		}
		start := pos + rest
		cnt := op.len - rest
		rest = 0
		if op.kind == .Opaque && cnt == op.len {
			apply_opaque(h, b, u64(start), lv, op, stream, off) or_return
		}
		lv += cnt
		pos += op.len
	}
	return .None
}

@(private)
note_touched :: proc(h: ^History, ino: fstree.Inode_Id) {
	if ino in h.touched_set {
		return
	}
	h.touched_set[ino] = {}
	append(&h.touched, ino)
}

@(private)
apply_opaque :: proc(h: ^History, b: ^crdt.Batch, at: u64, lv: crdt.Lv, op: crdt.Op_Run, stream: u32, off: u64) -> Error {
	seq := b.seq + at
	actor := crdt.graph_intern(&h.g, b.actor)
	lamport := crdt.graph_lamport(&h.g, lv)
	id := fstree.Op_Id{actor, seq}
	decoded, ok := fshist.decode_opaque(op.content, h, proc(data: rawptr, id: crdt.Op_Id) -> fstree.Inode_Id {
		return op_inode((^History)(data), id)
	})
	if !ok {
		return .None
	}
	switch o in decoded {
	case fshist.Content_Op:
		reg := Blob_Reg {
			lamport = lamport,
			actor   = b.actor,
			seq     = seq,
			oid     = o.oid,
			size    = o.size,
		}
		f := history_file(h, o.inode) or_return
		if !f.rec.has_blob || blob_newer(reg, f.rec.blob) {
			f.rec.blob = reg
			f.rec.has_blob = true
			f.dirty = true
		}
		blob_log_add(h, o.inode, reg) or_return
		note_touched(h, o.inode)
	case fshist.Git_Op:
		k, _ := clone_string(o.kind, h.allocator)
		br, _ := clone_string(o.branch, h.allocator)
		c, _ := clone_string(o.commit, h.allocator)
		append(&h.markers, Git_Marker{k, br, c})
	case fshist.Tree_Op:
		if e := fstree.apply(&h.tree, id, lamport, o.op); e == nil {
			ino := fstree.op_inode(id, o.op)
			note_touched(h, ino)
			if _, mv := o.op.(fstree.Op_Move); mv {
				append(&h.moves, fstree.Move_Ref{event = {lamport = lamport, seq = seq, actor = actor}, inode = ino})
			}
		} else if e == .Unavailable {
			return .Io
		}
	}
	return .None
}

@(private)
blob_newer :: proc(a, b: Blob_Reg) -> bool {
	return fshist.blob_newer(a, b)
}

Local_Actor :: struct {
	ix:    u32,
	actor: prim.Id,
	on:    bool,
}

encode_tree_op :: proc(h: ^History, buf: ^[dynamic]u8, op: fstree.Op, la := Local_Actor{}) {
	ctx := Op_Ctx{h, la}
	fshist.encode_tree_op(buf, op, &ctx, op_ctx_map)
}

@(private)
Op_Ctx :: struct {
	h:  ^History,
	la: Local_Actor,
}

@(private)
op_ctx_map :: proc(data: rawptr, id: fstree.Inode_Id) -> crdt.Op_Id {
	c := (^Op_Ctx)(data)
	if c.la.on && id.actor == c.la.ix {
		return crdt.Op_Id{c.la.actor, id.seq}
	}
	return inode_op(c.h, id)
}

encode_content_op :: proc(h: ^History, buf: ^[dynamic]u8, inode: fstree.Inode_Id, oid: odb.Oid, size: i64, la := Local_Actor{}) {
	ctx := Op_Ctx{h, la}
	n := h.db.format == .Sha256 ? 32 : 20 if h.db != nil else 20
	fshist.encode_content_op(buf, op_ctx_map(&ctx, inode), fshist.Raw_Oid(oid), n, size)
}

encode_git_op :: proc(buf: ^[dynamic]u8, kind, branch, commit: string) {
	fshist.encode_git_op(buf, kind, branch, commit)
}

@(private)
file_free :: proc(h: ^History, f: ^File_State) {
	if f.loaded {
		crdt.text_destroy(&f.text)
		crdt.log_destroy(&f.log)
	}
	delete(f.rec.cp_version)
	delete(f.rec.cp_spans)
	delete(f.new_refs)
	free(f, h.allocator)
}

@(private)
copy_read :: proc(data: rawptr, src: crdt.Op_Id, dst: []u8, authors: ^[dynamic]crdt.Author_Span) -> int {
	return copy_read_depth((^History)(data), src, dst, authors, 0)
}

@(private)
copy_read_depth :: proc(h: ^History, src: crdt.Op_Id, dst: []u8, authors: ^[dynamic]crdt.Author_Span, depth: int) -> int {
	got := 0
	outer: for got < len(dst) && depth < 64 {
		id := crdt.Op_Id{src.actor, src.seq + u64(got)}
		lv, ok := crdt.graph_lv(&h.g, id)
		if !ok {
			break
		}
		_, _, stream, off, found := history_batch_at(h, lv)
		if !found {
			break
		}
		b, err := history_read_batch(h, stream, off, context.temp_allocator)
		if err != .None || b.actor != id.actor || id.seq < b.seq {
			break
		}
		rel := int(id.seq - b.seq)
		pos := 0
		for op in b.ops {
			if rel >= pos + op.len {
				pos += op.len
				continue
			}
			k := rel - pos
			avail := min(op.len - k, len(dst) - got)
			#partial switch op.kind {
			case .Insert:
				copy(dst[got:got + avail], op.content[k:k + avail])
				append(authors, crdt.Author_Span{id = id, op = id, len = avail})
			case .Insert_Ref:
				r := op.ref
				if !content_read(h, r.oid, r.offset + k, dst[got:got + avail]) {
					break outer
				}
				append(authors, crdt.Author_Span{id = id, op = id, len = avail})
			case .Insert_Copy:
				sub := copy_read_depth(h, crdt.Op_Id{op.src.actor, op.src.seq + u64(k)}, dst[got:got + avail], authors, depth + 1)
				if sub < avail {
					got += sub
					break outer
				}
			case:
				break outer
			}
			got += avail
			continue outer
		}
		break
	}
	return got
}

@(private)
content_read :: proc(data: rawptr, oid: crdt.Oid, offset: int, dst: []u8) -> bool {
	h := (^History)(data)
	if h.db == nil {
		return false
	}
	full := odb_oid(oid)
	if h.blob_data == nil || h.blob_cache != full {
		if h.blob_data != nil {
			delete(h.blob_data, h.allocator)
			h.blob_data = nil
		}
		t, d, err := odb.read(h.db, full, h.allocator)
		if err != .None || t != .Blob {
			if d != nil {
				delete(d, h.allocator)
			}
			return false
		}
		h.blob_data = d
		h.blob_cache = full
	}
	if offset < 0 || offset + len(dst) > len(h.blob_data) {
		return false
	}
	copy(dst, h.blob_data[offset:])
	return true
}

@(private)
load_text :: proc(h: ^History, f: ^File_State, v: []crdt.Lv, full := false) -> Error {
	src := fshist.Text_Source {
		data       = h,
		g          = &h.g,
		allocator  = h.allocator,
		content    = crdt.Content_Source{h, content_read},
		copies     = crdt.Copy_Source{h, copy_read},
		op_ref     = proc(data: rawptr, inode: fstree.Inode_Id, i: u32) -> (fshist.Op_Ref, fshist.Error) {
			h := (^History)(data)
			ref, err := read_op_ref(h, inode, i)
			if err != .None {
				h.src_err = err
				return {}, .Corrupt
			}
			return ref, .None
		},
		record     = proc(data: rawptr, stream: u32, off: u64, buf: ^[dynamic]u8) -> ([]u8, fshist.Error) {
			h := (^History)(data)
			body, err := read_stream(h, stream, i64(off), buf)
			if err == .Redacted {
				return nil, .Redacted
			}
			if err != .None {
				h.src_err = err
				return nil, .Corrupt
			}
			return body, .None
		},
		dict       = proc(data: rawptr, stream: u32) -> ^crdt.Actor_Dict {
			return stream_dict((^History)(data), stream)
		},
		checkpoint = proc(data: rawptr, oid: fshist.Raw_Oid, size: i64, allocator: runtime.Allocator) -> ([]u8, fshist.Error) {
			h := (^History)(data)
			if h.db == nil {
				return nil, .Not_Found
			}
			if d, ok := history_staged_data(h, odb.Oid(oid)); ok && i64(len(d)) == size {
				return d, .None
			}
			t, d, rerr := odb.read(h.db, odb.Oid(oid), allocator)
			if rerr != .None || t != .Blob || i64(len(d)) != size {
				return nil, .Not_Found
			}
			return d, .None
		},
	}
	h.src_err = .None
	e := fshist.text_load(&src, &f.st, f.inode, inode_op(h, f.inode), &f.rec, f.new_refs[:], v, full)
	if e == .None {
		return .None
	}
	if h.src_err != .None {
		return h.src_err
	}
	#partial switch e {
	case .Not_Found:
		return .Not_Found
	case .Invalid:
		return .Invalid
	case .No_Memory:
		return .No_Memory
	case .Redacted:
		return .Redacted
	}
	return .Corrupt
}

@(private)
read_stream :: proc(h: ^History, stream: u32, off: i64, buf: ^[dynamic]u8) -> (body: []u8, err: Error) {
	if stream == 0 {
		r: journal.Reader
		journal.journal_reader(&h.journal, &r, context.temp_allocator)
		defer journal.reader_close(&r)
		b, _, jerr := journal.record_at(&r, off)
		if jerr == .Redacted {
			return nil, .Redacted
		}
		if jerr != .None {
			return nil, from_journal(jerr)
		}
		clear(buf)
		append(buf, ..b)
		return buf[:], .None
	}
	if int(stream) >= len(h.stream_ids) || h.streams.read == nil {
		return nil, .Not_Found
	}
	clear(buf)
	if !h.streams.read(h.streams.data, h.stream_ids[stream], off, buf) {
		return nil, .Not_Found
	}
	if len(buf) == 0 {
		return nil, .Redacted
	}
	return buf[:], .None
}

@(private)
persist_file :: proc(h: ^History, id: fstree.Inode_Id, f: ^File_State) -> Error {
	for ref in f.new_refs {
		write_op_ref(h, id, f.rec.ops, ref) or_return
		f.rec.ops += 1
	}
	clear(&f.new_refs)
	if f.loaded && f.rec.ops - f.rec.cp_count >= CHECKPOINT_OPS && h.db != nil {
		data := crdt.text_bytes(&f.text, context.temp_allocator)
		oid, werr := history_stage_blob(h, data)
		if werr == .None {
			history_note_file_blob(h, id, oid, crdt.text_version(&f.text, &h.g, context.temp_allocator))
			clear(&f.rec.cp_version)
			append(&f.rec.cp_version, ..crdt.text_version(&f.text, &h.g, context.temp_allocator))
			clear(&f.rec.cp_spans)
			append(&f.rec.cp_spans, ..crdt.text_spans(&f.text, &h.g, context.temp_allocator))
			f.rec.cp_text = fshist.Raw_Oid(oid)
			f.rec.cp_len = i64(len(data))
			f.rec.cp_count = f.rec.ops
			f.rec.has_cp = true
		}
	}
	buf := make([dynamic]u8, context.temp_allocator)
	encode_file_record(&buf, &f.rec)
	kv_put(&h.kv, inode_key("f", id), buf[:]) or_return
	f.dirty = false
	return .None
}

@(private)
encode_file_record :: proc(buf: ^[dynamic]u8, r: ^File_Record) {
	fshist.encode_file_record(buf, r)
}

@(private)
read_file_record :: proc(h: ^History, id: fstree.Inode_Id, r: ^File_Record) -> Error {
	r.cp_version = make([dynamic]crdt.Op_Id, h.allocator)
	r.cp_spans = make([dynamic]crdt.Author_Span, h.allocator)
	data, found := kv_get(&h.kv, inode_key("f", id), context.temp_allocator) or_return
	if !found {
		return .None
	}
	return decode_file_record(data, r)
}

@(private)
decode_file_record :: proc(data: []u8, r: ^File_Record) -> Error {
	return .Corrupt if fshist.decode_file_record(data, r) != .None else .None
}

@(private)
write_op_ref :: proc(h: ^History, id: fstree.Inode_Id, i: u32, ref: Op_Ref) -> Error {
	key := ops_key(id, i / OPS_CHUNK)
	data, _ := kv_get(&h.kv, key, context.temp_allocator) or_return
	buf := make([dynamic]u8, 0, len(data) + 24, context.temp_allocator)
	append(&buf, ..data)
	fshist.encode_op_ref(&buf, ref)
	return kv_put(&h.kv, key, buf[:])
}

@(private)
read_op_ref :: proc(h: ^History, id: fstree.Inode_Id, i: u32) -> (ref: Op_Ref, err: Error) {
	data, found := kv_get(&h.kv, ops_key(id, i / OPS_CHUNK), context.temp_allocator) or_return
	if !found {
		return {}, .Corrupt
	}
	r, ok := fshist.op_ref_at(data, i % OPS_CHUNK)
	if !ok {
		return {}, .Corrupt
	}
	return r, .None
}

@(private)
persist_moves :: proc(h: ^History) -> Error {
	if len(h.moves) == 0 {
		return .None
	}
	for m in h.moves {
		chunk := h.moves_count / MOVES_CHUNK
		key := moves_key(chunk)
		data, _ := kv_get(&h.kv, key, context.temp_allocator) or_return
		buf := make([dynamic]u8, 0, len(data) + 32, context.temp_allocator)
		append(&buf, ..data)
		fshist.encode_move(&buf, m)
		kv_put(&h.kv, key, buf[:]) or_return
		h.moves_count += 1
	}
	clear(&h.moves)
	return .None
}

@(private)
load_state :: proc(h: ^History) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	meta, found := kv_get(&h.kv, transmute([]u8)string("g"), context.temp_allocator) or_return
	src := crdt.Graph_Source{h, graph_load}
	if found {
		if crdt.graph_open(&h.g, meta, src, h.allocator) != .None {
			return .Corrupt
		}
	} else {
		crdt.graph_init(&h.g, h.allocator, src)
	}
	tsrc := fstree.Source {
		data       = h,
		actor      = tree_actor,
		load_inode = tree_load_inode,
		load_node  = tree_load_node,
		load_moves = tree_load_moves,
	}
	max_lamport: u64
	for x in h.g.heads {
		max_lamport = max(max_lamport, crdt.graph_lamport(&h.g, x))
	}
	if fstree.init(&h.tree, tsrc, max_lamport, allocator = h.allocator) != nil {
		crdt.graph_destroy(&h.g)
		return .No_Memory
	}
	s, sfound := kv_get(&h.kv, transmute([]u8)string("s"), context.temp_allocator) or_return
	if sfound {
		rd := prim.reader(s)
		if prim.read_u8(&rd) != 2 {
			return .Corrupt
		}
		ns := prim.read_uvarint(&rd)
		if ns > u64(len(s)) {
			return .Corrupt
		}
		for i in 0 ..< ns {
			append(&h.stream_ids, prim.read_id(&rd))
			append(&h.applied, i64(prim.read_uvarint(&rd)))
			d: crdt.Actor_Dict
			crdt.dict_init(&d, h.allocator)
			if i > 0 {
				nd := prim.read_uvarint(&rd)
				if nd > u64(prim.reader_remaining(&rd)) {
					crdt.dict_destroy(&d)
					return .Corrupt
				}
				for _ in 0 ..< nd {
					crdt.dict_add(&d, prim.read_id(&rd))
				}
			}
			append(&h.rdicts, d)
		}
		nd := prim.read_uvarint(&rd)
		for _ in 0 ..< nd {
			crdt.dict_add(&h.dict, prim.read_id(&rd))
		}
		h.moves_count = prim.read_uvarint(&rd)
		if !prim.reader_ok(&rd) {
			return .Corrupt
		}
	}
	if len(h.stream_ids) == 0 {
		append(&h.stream_ids, h.self)
		append(&h.applied, 0)
		d: crdt.Actor_Dict
		crdt.dict_init(&d, h.allocator)
		append(&h.rdicts, d)
	}
	return .None
}

@(private)
stream_dict :: proc(h: ^History, i: u32) -> ^crdt.Actor_Dict {
	if i == 0 || int(i) >= len(h.rdicts) {
		return &h.dict
	}
	return &h.rdicts[i]
}

@(private)
replay_own :: proc(h: ^History) -> Error {
	end := journal.journal_durable_len(&h.journal)
	if h.applied[0] >= end {
		return .None
	}
	r: journal.Reader
	journal.journal_reader(&h.journal, &r, context.temp_allocator)
	defer journal.reader_close(&r)
	off := h.applied[0]
	for off < end {
		body, next, jerr := journal.record_at(&r, off)
		if jerr == .Redacted && next > off {
			off = next
			continue
		}
		if jerr != .None {
			return from_journal(jerr)
		}
		if len(body) > 0 && body[0] == REC_ACTORS {
			rd := prim.reader(body[1:])
			n := prim.read_uvarint(&rd)
			for _ in 0 ..< n {
				crdt.dict_add(&h.dict, prim.read_id(&rd))
			}
		} else if len(body) > 0 && body[0] == REC_REDACT {
			apply_redact_record(h, body) or_return
		} else if len(body) > 0 && body[0] == REC_REPLACE {
			apply_replace_record(h, 0, body, u64(off)) or_return
		} else if len(body) > 0 && body[0] == REC_SEAL {
			apply_seal_record(h, 0, body) or_return
		} else if len(body) > 0 && body[0] == REC_LINE {
			apply_line_record(h, h.self, body) or_return
		} else if len(body) > 0 && (body[0] == REC_BATCH || body[0] == REC_IMPORT) {
			b, derr := crdt.batch_decode(body[1:], context.temp_allocator, &h.dict)
			if derr != .None {
				return .Corrupt
			}
			parents := make([dynamic]crdt.Lv, context.temp_allocator)
			skip, gerr := crdt.graph_check(&h.g, &b, &parents)
			if gerr == .None && skip < crdt.batch_len(&b) {
				if body[0] == REC_IMPORT {
					import_apply(h, &b, 0, u64(off)) or_return
				} else {
					apply_batch(h, &b, 0, u64(off)) or_return
				}
				history_persist(h) or_return
				history_unload_files(h)
				crdt.graph_trim(&h.g)
				fstree.trim(&h.tree, 64)
			}
		}
		off = next
	}
	h.applied[0] = end
	err := history_persist(h)
	history_unload_files(h)
	return err
}

@(private)
graph_load :: proc(data: rawptr, key: crdt.Page_Key, out: ^[dynamic]u8) -> bool {
	h := (^History)(data)
	v, found, err := kv_get(&h.kv, page_key(key), context.temp_allocator)
	if err != .None || !found {
		return false
	}
	clear(out)
	append(out, ..v)
	return true
}

@(private)
tree_actor :: proc(data: rawptr, actor: u32) -> prim.Id {
	h := (^History)(data)
	return history_actor(h, actor)
}

@(private)
tree_load_inode :: proc(data: rawptr, id: fstree.Inode_Id) -> (record: []u8, found: bool) {
	h := (^History)(data)
	v, ok, err := kv_get(&h.kv, inode_key("ti", id), context.temp_allocator)
	return v, ok && err == .None
}

@(private)
tree_load_node :: proc(data: rawptr, key: fstree.Node_Key) -> (record: []u8, found: bool) {
	h := (^History)(data)
	v, ok, err := kv_get(&h.kv, node_key(key), context.temp_allocator)
	return v, ok && err == .None
}

@(private)
tree_load_moves :: proc(data: rawptr, from_lamport: u64, out: ^[dynamic]fstree.Move_Ref) -> bool {
	h := (^History)(data)
	chunks := (h.moves_count + MOVES_CHUNK - 1) / MOVES_CHUNK
	for c in 0 ..< chunks {
		v, ok, err := kv_get(&h.kv, moves_key(c), context.temp_allocator)
		if err != .None || !ok {
			return false
		}
		if !fshist.decode_moves(v, from_lamport, out) {
			return false
		}
	}
	for m in h.moves {
		if m.event.lamport >= from_lamport {
			append(out, m)
		}
	}
	return true
}

@(private)
page_key :: proc(k: crdt.Page_Key) -> []u8 {
	return fshist.page_key(k)
}

@(private)
inode_key :: proc(prefix: string, id: fstree.Inode_Id) -> []u8 {
	return fshist.inode_key(prefix, id)
}

@(private)
node_key :: proc(k: fstree.Node_Key) -> []u8 {
	return fshist.node_key(k)
}

@(private)
ops_key :: proc(id: fstree.Inode_Id, chunk: u32) -> []u8 {
	return fshist.ops_key(id, chunk)
}

@(private)
moves_key :: proc(chunk: u64) -> []u8 {
	return fshist.moves_key(chunk)
}

@(private)
line_key :: proc(name: string, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, 2 + len(name), allocator)
	out[0] = 'l'
	out[1] = ':'
	copy(out[2:], name)
	return out
}

encode_version :: proc(buf: ^[dynamic]u8, v: Version) {
	fshist.encode_version(buf, v)
}

decode_version :: proc(data: []u8, allocator := context.allocator) -> (v: Version, err: Error) {
	out, e := fshist.decode_version(data, allocator)
	return out, .Corrupt if e != .None else .None
}

odb_oid :: proc "contextless" (o: crdt.Oid) -> (out: odb.Oid) {
	x := o
	n := min(int(x.len), 32)
	copy(out[:n], x.bytes[:n])
	return
}

crdt_oid :: proc "contextless" (o: odb.Oid, format: odb.Hash_Format) -> (out: crdt.Oid) {
	x := o
	n := odb.oid_size(format)
	out.len = u8(n)
	copy(out.bytes[:n], x[:n])
	return
}

REC_REPLACE :: fshist.REC_REPLACE
Replace :: fshist.Replace
replace_decode :: fshist.replace_decode
replace_supersedes :: fshist.replace_supersedes

batch_payload :: proc(body: []u8) -> (payload: []u8, ok: bool) {
	return fshist.batch_payload(body)
}

@(private)
remap_ref :: proc(h: ^History, stream: u32, old_off: u64, new_off: u64, inodes: []fstree.Inode_Id) -> Error {
	b: [LVIDX_REC]u8
	for i in 0 ..< h.lvidx_n {
		got, err := prim.read_at(h.vfs, h.lvidx, b[:], i64(i * LVIDX_REC))
		if err != .None || got != LVIDX_REC {
			return .Io
		}
		if prim.get_u32le(b[8:12]) == stream && prim.get_u64le(b[16:24]) == old_off {
			prim.put_u64le(b[16:24], new_off)
			from_prim(prim.write_at(h.vfs, h.lvidx, b[:], i64(i * LVIDX_REC))) or_return
		}
	}
	for ino in inodes {
		rec: File_Record
		read_file_record(h, ino, &rec) or_return
		chunks := (rec.ops + OPS_CHUNK - 1) / OPS_CHUNK
		if rec.has_base && rec.base.stream == stream && rec.base.off == old_off {
			rec.base.off = new_off
			rb := make([dynamic]u8, context.temp_allocator)
			encode_file_record(&rb, &rec)
			kv_put(&h.kv, inode_key("f", ino), rb[:]) or_return
			if f, ok := h.files[ino]; ok {
				f.rec.base.off = new_off
			}
		}
		delete(rec.cp_version)
		delete(rec.cp_spans)
		for c in 0 ..< chunks {
			key := ops_key(ino, c)
			data, found := kv_get(&h.kv, key, context.temp_allocator) or_return
			if !found {
				continue
			}
			rd := prim.reader(data)
			out := make([dynamic]u8, 0, len(data) + 8, context.temp_allocator)
			w := prim.writer(&out)
			changed := false
			for !prim.reader_done(&rd) {
				st := prim.read_uvarint(&rd)
				off := prim.read_uvarint(&rd)
				from := prim.read_uvarint(&rd)
				to := prim.read_uvarint(&rd)
				if !prim.reader_ok(&rd) {
					return .Corrupt
				}
				if u32(st) == stream && off == old_off {
					off = new_off
					changed = true
				}
				prim.write_uvarint(&w, st)
				prim.write_uvarint(&w, off)
				prim.write_uvarint(&w, from)
				prim.write_uvarint(&w, to)
			}
			if changed {
				kv_put(&h.kv, key, out[:]) or_return
			}
		}
	}
	return .None
}

@(private)
apply_replace_record :: proc(h: ^History, stream: u32, body: []u8, off: u64) -> Error {
	old, n := prim.get_uvarint(body[1:])
	if n <= 0 {
		return .Corrupt
	}
	payload, ok := batch_payload(body)
	if !ok {
		return .Corrupt
	}
	b, derr := crdt.batch_decode(payload, context.temp_allocator, stream_dict(h, stream))
	if derr != .None {
		return .Corrupt
	}
	inodes := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	for op in b.ops {
		if op.kind != .Opaque {
			append(&inodes, op_inode(h, op.target))
		}
	}
	return replace_chain(h, stream, old, old, off, inodes[:])
}

REC_ALIAS :: fshist.REC_ALIAS
REC_LINE :: fshist.REC_LINE

history_alias :: proc(h: ^History, sources: []string, commit: string, v: Version) -> Error {
	clear(&h.io)
	w := prim.writer(&h.io)
	prim.write_u8(&w, REC_ALIAS)
	prim.write_uvarint(&w, u64(len(sources)))
	for s in sources {
		prim.write_str(&w, s)
	}
	prim.write_str(&w, commit)
	vb := make([dynamic]u8, context.temp_allocator)
	encode_version(&vb, v)
	prim.write_bytes(&w, vb[:])
	if _, jerr := journal.journal_append(&h.journal, h.io[:]); jerr != .None {
		return .Io
	}
	if journal.journal_commit(&h.journal) != .None {
		return .Io
	}
	h.applied[0] = journal.journal_durable_len(&h.journal)
	return .None
}
