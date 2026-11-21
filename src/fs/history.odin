package fs

import "base:runtime"
import "core:slice"
import "../crdt"
import "../fstree"
import "../journal"
import "../odb"
import "../prim"

REC_BATCH :: u8(1)
REC_IMPORT :: u8(3)
REC_ACTORS :: u8(2)

TOP_CREATE :: u8(1)
TOP_MOVE :: u8(2)
TOP_REMOVE :: u8(3)
TOP_RESTORE :: u8(4)
TOP_FLAGS :: u8(5)
TOP_TARGET :: u8(6)
TOP_CONTENT :: u8(16)
TOP_GIT :: u8(17)

CHECKPOINT_OPS :: 64
OPS_CHUNK :: 256
MOVES_CHUNK :: 512

Version :: []crdt.Op_Id

Stream_Source :: struct {
	data: rawptr,
	read: proc(data: rawptr, stream: prim.Id, off: i64, out: ^[dynamic]u8) -> bool,
}

Blob_Reg :: struct {
	lamport: u64,
	actor:   prim.Id,
	seq:     u64,
	oid:     odb.Oid,
	size:    i64,
}

Op_Ref :: struct {
	stream: u32,
	off:    u64,
	from:   u32,
	to:     u32,
}

File_Record :: struct {
	blob:       Blob_Reg,
	has_blob:   bool,
	cp_version: [dynamic]crdt.Op_Id,
	cp_text:    odb.Oid,
	cp_spans:   [dynamic]crdt.Author_Span,
	cp_len:     i64,
	cp_count:   u32,
	has_cp:     bool,
	ops:        u32,
}

File_State :: struct {
	inode:  fstree.Inode_Id,
	rec:    File_Record,
	text:   crdt.Text,
	log:    crdt.Text_Log,
	loaded: bool,
	dirty:  bool,
	new_refs: [dynamic]Op_Ref,
}

Git_Marker :: struct {
	kind:   string,
	branch: string,
	commit: string,
}

History :: struct {
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
	pins:       [dynamic]odb.Oid,
	lvidx:      prim.Fd,
	lvidx_n:    u64,
	markers:    [dynamic]Git_Marker,
}

history_open :: proc(h: ^History, vfs: prim.Vfs, dir: string, id: prim.Id, self: prim.Id, db: ^odb.Odb, streams := Stream_Source{}, allocator := context.allocator) -> Error {
	h^ = {
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
	if err := history_wake(h); err != .None {
		delete(h.dir, allocator)
		h.dir = ""
		return err
	}
	return .None
}

history_close :: proc(h: ^History) {
	history_sleep(h)
	delete(h.dir, h.allocator)
	h.dir = ""
}

history_wake :: proc(h: ^History) -> Error {
	if h.awake {
		return .None
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	from_prim(prim.mkdir_all(h.vfs, h.dir, 0o700)) or_return
	kv_open(&h.kv, h.vfs, h.dir, "state", h.allocator) or_return
	jpath, _ := path_join(h.dir, "fs.journal", context.temp_allocator)
	if jerr := journal.journal_open(&h.journal, h.vfs, jpath, allocator = h.allocator); jerr != .None {
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
	}
	return err
}

history_sleep :: proc(h: ^History) {
	if !h.awake {
		return
	}
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
	if !ok {
		return nil, false, .None
	}
	v = decode_version(data, allocator) or_return
	return v, true, .None
}

history_set_line :: proc(h: ^History, name: string, v: Version) -> Error {
	key := line_key(name, context.temp_allocator)
	buf := make([dynamic]u8, context.temp_allocator)
	encode_version(&buf, v)
	kv_put(&h.kv, key, buf[:]) or_return
	return kv_commit(&h.kv)
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
		rec.has_cp = true
		rec.cp_text = odb_oid(op.ref.oid)
		rec.cp_len = i64(op.len)
		rec.cp_version = make([dynamic]crdt.Op_Id, context.temp_allocator)
		rec.cp_spans = make([dynamic]crdt.Author_Span, context.temp_allocator)
		append(&rec.cp_version, crdt.Op_Id{b.actor, at + u64(op.len) - 1})
		append(&rec.cp_spans, crdt.Author_Span{id = {b.actor, at}, op = {b.actor, at}, len = op.len})
		clear(&buf)
		encode_file_record(&buf, &rec)
		ino := op_inode(h, op.target)
		kv_put(&h.kv, inode_key("f", ino), buf[:]) or_return
		if f, ok := h.files[ino]; ok {
			file_free(h, f)
			delete_key(&h.files, ino)
		}
	}
	return .None
}

history_commit_local :: proc(h: ^History, b: ^crdt.Batch) -> (off: i64, err: Error) {
	parents := make([dynamic]crdt.Lv, context.temp_allocator)
	skip, gerr := crdt.graph_check(&h.g, b, &parents)
	if gerr != .None || skip != 0 {
		return 0, .Invalid
	}
	n := crdt.batch_len(b)
	valid := n
	for t in text_targets(b, context.temp_allocator) {
		f := history_file(h, op_inode(h, t)) or_return
		v, terr := crdt.text_check(&f.text, &h.g, &f.log, b, t, 0, parents[:])
		if terr != .None {
			return 0, .Corrupt
		}
		valid = min(valid, v)
	}
	if valid != n {
		return 0, .Invalid
	}
	o := journal_batch(h, b) or_return
	apply_batch(h, b, 0, u64(o)) or_return
	h.applied[0] = journal.journal_durable_len(&h.journal)
	return o, history_persist(h)
}

@(private)
journal_batch :: proc(h: ^History, b: ^crdt.Batch, kind := REC_BATCH) -> (off: i64, err: Error) {
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
	if h.db != nil {
		if e := odb.barrier(h.db); e != .None {
			return 0, from_odb(e)
		}
	}
	if journal.journal_commit(&h.journal) != .None {
		return 0, .Io
	}
	if len(h.applied) == 0 {
		append(&h.applied, 0)
		append(&h.stream_ids, h.self)
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
	if body[0] == REC_REDACT {
		apply_redact_record(h, body) or_return
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
	for t in text_targets(&b, context.temp_allocator) {
		f := history_file(h, op_inode(h, t)) or_return
		v, terr := crdt.text_check(&f.text, &h.g, &f.log, &b, t, skip, parents[:])
		if terr != .None {
			return 0, .Corrupt
		}
		valid = min(valid, v)
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
	for id, f in h.files {
		if f.dirty {
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
	return kv_commit(&h.kv)
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
	read_file_record(h, inode, &f.rec) or_return
	load_text(h, f, h.g.heads[:]) or_return
	h.files[inode] = f
	return f, .None
}

history_text_at :: proc(h: ^History, inode: fstree.Inode_Id, v: Version, allocator := context.allocator) -> (data: []u8, err: Error) {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return nil, .Not_Found
	}
	f := history_file(h, inode) or_return
	if crdt.frontier_eq(f.text.version[:], lvs[:]) {
		return crdt.text_bytes(&f.text, allocator), .None
	}
	tmp: File_State
	tmp.inode = inode
	tmp.rec = f.rec
	if err = load_text(h, &tmp, lvs[:]); err != .None {
		return nil, err
	}
	defer {
		crdt.text_destroy(&tmp.text)
		crdt.log_destroy(&tmp.log)
	}
	return crdt.text_bytes(&tmp.text, allocator), .None
}

history_text_spans_at :: proc(h: ^History, inode: fstree.Inode_Id, v: []crdt.Lv, allocator := context.allocator) -> (data: []u8, spans: []crdt.Author_Span, err: Error) {
	tmp: File_State
	tmp.inode = inode
	read_file_record(h, inode, &tmp.rec) or_return
	defer {
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	load_text(h, &tmp, v) or_return
	defer {
		crdt.text_destroy(&tmp.text)
		crdt.log_destroy(&tmp.log)
	}
	return crdt.text_bytes(&tmp.text, allocator), crdt.text_spans(&tmp.text, &h.g, allocator), .None
}

history_blob :: proc(h: ^History, inode: fstree.Inode_Id) -> (reg: Blob_Reg, found: bool, err: Error) {
	f := history_file(h, inode) or_return
	return f.rec.blob, f.rec.has_blob, .None
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
text_targets :: proc(b: ^crdt.Batch, allocator: runtime.Allocator) -> []crdt.Op_Id {
	out := make([dynamic]crdt.Op_Id, allocator)
	for op in b.ops {
		if op.kind == .Opaque {
			continue
		}
		seen := false
		for t in out {
			if t == op.target {
				seen = true
				break
			}
		}
		if !seen {
			append(&out, op.target)
		}
	}
	return out[:]
}

@(private)
apply_batch :: proc(h: ^History, b: ^crdt.Batch, stream: u32, off: u64) -> Error {
	first, skip, gerr := crdt.graph_add(&h.g, b)
	if gerr != .None {
		return .Corrupt
	}
	n := crdt.batch_len(b)
	targets := text_targets(b, context.temp_allocator)
	for t in targets {
		ino := op_inode(h, t)
		f := history_file(h, ino) or_return
		crdt.log_add_batch(&f.log, &h.g, b, t, first, skip)
		append(&f.new_refs, Op_Ref{stream, off, u32(skip), u32(n)})
		f.dirty = true
		note_touched(h, ino)
	}
	lvidx_add(h, first, n - skip, stream, off)
	apply_tree_ops(h, b, first, skip, stream, off) or_return
	for t in targets {
		f := h.files[op_inode(h, t)]
		if e := crdt.text_merge(&f.text, &h.g, &f.log, h.g.heads[:]); e != .None {
			return .Corrupt
		}
	}
	return .None
}

LVIDX_REC :: 24

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
	for x in h.touched {
		if x == ino {
			return
		}
	}
	append(&h.touched, ino)
}

@(private)
apply_opaque :: proc(h: ^History, b: ^crdt.Batch, at: u64, lv: crdt.Lv, op: crdt.Op_Run, stream: u32, off: u64) -> Error {
	r := prim.reader(op.content)
	tag := prim.read_u8(&r)
	seq := b.seq + at
	actor := crdt.graph_intern(&h.g, b.actor)
	lamport := crdt.graph_lamport(&h.g, lv)
	id := fstree.Op_Id{actor, seq}
	read_inode :: proc(h: ^History, r: ^prim.Reader) -> fstree.Inode_Id {
		a := prim.read_id(r)
		s := prim.read_uvarint(r)
		return op_inode(h, crdt.Op_Id{a, s})
	}
	tree_op: fstree.Op
	switch tag {
	case TOP_CREATE:
		parent := read_inode(h, &r)
		kind := prim.read_u8(&r)
		flags := prim.read_u8(&r)
		name := prim.read_str(&r)
		target := prim.read_str(&r)
		if kind > u8(max(fstree.Kind)) {
			return .None
		}
		tree_op = fstree.Op_Create{parent, name, fstree.Kind(kind), transmute(fstree.Flags)flags & fstree.ALL_FLAGS, target}
	case TOP_MOVE:
		inode := read_inode(h, &r)
		parent := read_inode(h, &r)
		name := prim.read_str(&r)
		tree_op = fstree.Op_Move{inode, parent, name}
	case TOP_REMOVE:
		tree_op = fstree.Op_Remove{read_inode(h, &r)}
	case TOP_RESTORE:
		tree_op = fstree.Op_Restore{read_inode(h, &r)}
	case TOP_FLAGS:
		inode := read_inode(h, &r)
		mask := prim.read_u8(&r)
		value := prim.read_u8(&r)
		tree_op = fstree.Op_Set_Flags{inode, transmute(fstree.Flags)mask & fstree.ALL_FLAGS, transmute(fstree.Flags)value & fstree.ALL_FLAGS}
	case TOP_TARGET:
		inode := read_inode(h, &r)
		tree_op = fstree.Op_Set_Target{inode, prim.read_str(&r)}
	case TOP_CONTENT:
		inode := read_inode(h, &r)
		reg := Blob_Reg {
			lamport = lamport,
			actor   = b.actor,
			seq     = seq,
		}
		osz := prim.read_u8(&r)
		if osz > 32 {
			return .None
		}
		prim.read_fixed(&r, reg.oid[:osz])
		reg.size = i64(prim.read_uvarint(&r))
		if !prim.reader_ok(&r) {
			return .None
		}
		f := history_file(h, inode) or_return
		if !f.rec.has_blob || blob_newer(reg, f.rec.blob) {
			f.rec.blob = reg
			f.rec.has_blob = true
			f.dirty = true
		}
		note_touched(h, inode)
		return .None
	case TOP_GIT:
		kind := prim.read_str(&r)
		branch := prim.read_str(&r)
		commit := prim.read_str(&r)
		if prim.reader_ok(&r) {
			k, _ := clone_string(kind, h.allocator)
			br, _ := clone_string(branch, h.allocator)
			c, _ := clone_string(commit, h.allocator)
			append(&h.markers, Git_Marker{k, br, c})
		}
		return .None
	case:
		return .None
	}
	if !prim.reader_ok(&r) {
		return .None
	}
	if e := fstree.apply(&h.tree, id, lamport, tree_op); e == nil {
		ino := fstree.op_inode(id, tree_op)
		note_touched(h, ino)
		if _, ok := tree_op.(fstree.Op_Move); ok {
			append(&h.moves, fstree.Move_Ref{event = {lamport = lamport, seq = seq, actor = actor}, inode = ino})
		}
	} else if e == .Unavailable {
		return .Io
	}
	return .None
}

@(private)
blob_newer :: proc(a, b: Blob_Reg) -> bool {
	if a.lamport != b.lamport {
		return a.lamport > b.lamport
	}
	if a.actor != b.actor {
		return crdt.id_less(b.actor, a.actor)
	}
	return a.seq > b.seq
}

encode_tree_op :: proc(h: ^History, buf: ^[dynamic]u8, op: fstree.Op) {
	w := prim.writer(buf)
	put :: proc(h: ^History, w: ^prim.Writer, id: fstree.Inode_Id) {
		o := inode_op(h, id)
		prim.write_id(w, o.actor)
		prim.write_uvarint(w, o.seq)
	}
	switch o in op {
	case fstree.Op_Create:
		prim.write_u8(&w, TOP_CREATE)
		put(h, &w, o.parent)
		prim.write_u8(&w, u8(o.kind))
		prim.write_u8(&w, transmute(u8)o.flags)
		prim.write_str(&w, o.name)
		prim.write_str(&w, o.target)
	case fstree.Op_Move:
		prim.write_u8(&w, TOP_MOVE)
		put(h, &w, o.inode)
		put(h, &w, o.parent)
		prim.write_str(&w, o.name)
	case fstree.Op_Remove:
		prim.write_u8(&w, TOP_REMOVE)
		put(h, &w, o.inode)
	case fstree.Op_Restore:
		prim.write_u8(&w, TOP_RESTORE)
		put(h, &w, o.inode)
	case fstree.Op_Set_Flags:
		prim.write_u8(&w, TOP_FLAGS)
		put(h, &w, o.inode)
		prim.write_u8(&w, transmute(u8)o.mask)
		prim.write_u8(&w, transmute(u8)o.value)
	case fstree.Op_Set_Target:
		prim.write_u8(&w, TOP_TARGET)
		put(h, &w, o.inode)
		prim.write_str(&w, o.target)
	}
}

encode_content_op :: proc(h: ^History, buf: ^[dynamic]u8, inode: fstree.Inode_Id, oid: odb.Oid, size: i64) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_CONTENT)
	o := inode_op(h, inode)
	prim.write_id(&w, o.actor)
	prim.write_uvarint(&w, o.seq)
	n := h.db.format == .Sha256 ? 32 : 20 if h.db != nil else 20
	prim.write_u8(&w, u8(n))
	x := oid
	prim.write_raw(&w, x[:n])
	prim.write_uvarint(&w, u64(size))
}

encode_git_op :: proc(buf: ^[dynamic]u8, kind, branch, commit: string) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_GIT)
	prim.write_str(&w, kind)
	prim.write_str(&w, branch)
	prim.write_str(&w, commit)
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
load_text :: proc(h: ^History, f: ^File_State, v: []crdt.Lv) -> Error {
	if f.loaded {
		crdt.text_destroy(&f.text)
		crdt.log_destroy(&f.log)
		f.loaded = false
	}
	if f.rec.has_cp {
		ok, err := load_from_checkpoint(h, f, v)
		if err != .None {
			return err
		}
		if ok {
			return .None
		}
	}
	crdt.text_init(&f.text, h.allocator)
	crdt.log_init(&f.log, h.allocator, crdt.Content_Source{h, content_read}, crdt.Copy_Source{h, copy_read})
	f.loaded = true
	replay_ops(h, f, 0) or_return
	if e := crdt.text_merge(&f.text, &h.g, &f.log, v); e != .None {
		return .Corrupt
	}
	return .None
}

@(private)
load_from_checkpoint :: proc(h: ^History, f: ^File_State, v: []crdt.Lv) -> (ok: bool, err: Error) {
	cpv := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, f.rec.cp_version[:], &cpv) != .None {
		return false, .None
	}
	if !crdt.graph_contains_all(&h.g, v, cpv[:]) {
		return false, .None
	}
	data: []u8
	if f.rec.cp_len > 0 {
		if h.db == nil {
			return false, .None
		}
		t, d, rerr := odb.read(h.db, f.rec.cp_text, context.temp_allocator)
		if rerr != .None || t != .Blob || i64(len(d)) != f.rec.cp_len {
			return false, .None
		}
		data = d
	}
	if crdt.text_from(&f.text, &h.g, data, f.rec.cp_spans[:], f.rec.cp_version[:], h.allocator) != .None {
		return false, .None
	}
	crdt.log_init(&f.log, h.allocator, crdt.Content_Source{h, content_read}, crdt.Copy_Source{h, copy_read})
	f.loaded = true
	replay_ops(h, f, f.rec.cp_count) or_return
	if e := crdt.text_merge(&f.text, &h.g, &f.log, v); e != .None {
		crdt.text_destroy(&f.text)
		crdt.log_destroy(&f.log)
		f.loaded = false
		return false, .None
	}
	return true, .None
}

@(private)
replay_ops :: proc(h: ^History, f: ^File_State, from: u32) -> Error {
	target := inode_op(h, f.inode)
	buf := make([dynamic]u8, context.temp_allocator)
	for i := from; i < f.rec.ops; i += 1 {
		ref := read_op_ref(h, f.inode, i) or_return
		replay_ref(h, f, target, ref, &buf) or_return
	}
	for ref in f.new_refs {
		replay_ref(h, f, target, ref, &buf) or_return
	}
	return .None
}

@(private)
replay_ref :: proc(h: ^History, f: ^File_State, target: crdt.Op_Id, ref: Op_Ref, buf: ^[dynamic]u8) -> Error {
	body, rerr := read_stream(h, ref.stream, i64(ref.off), buf)
	if rerr == .Redacted {
		return .None
	}
	rerr or_return
	payload, pok := batch_payload(body)
	if !pok {
		return .Corrupt
	}
	dict := stream_dict(h, ref.stream)
	b, derr := crdt.batch_decode(payload, context.temp_allocator, dict)
	if derr != .None {
		return .Corrupt
	}
	use := &b
	if ref.to < u32(crdt.batch_len(&b)) {
		cut, cerr := crdt.batch_slice(&b, 0, int(ref.to), context.temp_allocator)
		if cerr != .None {
			return .Corrupt
		}
		use = &cut
	}
	first, ok := crdt.graph_lv(&h.g, crdt.Op_Id{use.actor, use.seq})
	if !ok {
		return .Corrupt
	}
	crdt.log_add_batch(&f.log, &h.g, use, target, first, 0)
	return .None
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
			return nil, .Corrupt
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
		oid, werr := odb.write(h.db, .Blob, data)
		if werr == .None {
			history_note_blob(h, oid)
			clear(&f.rec.cp_version)
			append(&f.rec.cp_version, ..crdt.text_version(&f.text, &h.g, context.temp_allocator))
			clear(&f.rec.cp_spans)
			append(&f.rec.cp_spans, ..crdt.text_spans(&f.text, &h.g, context.temp_allocator))
			f.rec.cp_text = oid
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
	w := prim.writer(buf)
	prim.write_bool(&w, r.has_blob)
	if r.has_blob {
		prim.write_uvarint(&w, r.blob.lamport)
		prim.write_id(&w, r.blob.actor)
		prim.write_uvarint(&w, r.blob.seq)
		oid := r.blob.oid
		prim.write_raw(&w, oid[:])
		prim.write_ivarint(&w, r.blob.size)
	}
	prim.write_uvarint(&w, u64(r.ops))
	prim.write_bool(&w, r.has_cp)
	if r.has_cp {
		prim.write_uvarint(&w, u64(r.cp_count))
		oid := r.cp_text
		prim.write_raw(&w, oid[:])
		prim.write_ivarint(&w, r.cp_len)
		prim.write_uvarint(&w, u64(len(r.cp_version)))
		for v in r.cp_version {
			prim.write_id(&w, v.actor)
			prim.write_uvarint(&w, v.seq)
		}
		prim.write_uvarint(&w, u64(len(r.cp_spans)))
		for s in r.cp_spans {
			prim.write_id(&w, s.id.actor)
			prim.write_uvarint(&w, s.id.seq)
			prim.write_uvarint(&w, u64(s.len))
			flags: u8 = 1 if s.redacted else 0
			if s.op != s.id {
				flags |= 2
			}
			prim.write_u8(&w, flags)
			if s.op != s.id {
				prim.write_id(&w, s.op.actor)
				prim.write_uvarint(&w, s.op.seq)
			}
		}
	}
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
	rd := prim.reader(data)
	r.has_blob = prim.read_bool(&rd)
	if r.has_blob {
		r.blob.lamport = prim.read_uvarint(&rd)
		r.blob.actor = prim.read_id(&rd)
		r.blob.seq = prim.read_uvarint(&rd)
		prim.read_fixed(&rd, r.blob.oid[:])
		r.blob.size = prim.read_ivarint(&rd)
	}
	r.ops = u32(prim.read_uvarint(&rd))
	r.has_cp = prim.read_bool(&rd)
	if r.has_cp {
		r.cp_count = u32(prim.read_uvarint(&rd))
		prim.read_fixed(&rd, r.cp_text[:])
		r.cp_len = prim.read_ivarint(&rd)
		nv := prim.read_uvarint(&rd)
		if nv > u64(prim.reader_remaining(&rd)) {
			return .Corrupt
		}
		for _ in 0 ..< nv {
			a := prim.read_id(&rd)
			append(&r.cp_version, crdt.Op_Id{a, prim.read_uvarint(&rd)})
		}
		ns := prim.read_uvarint(&rd)
		if ns > u64(prim.reader_remaining(&rd)) {
			return .Corrupt
		}
		for _ in 0 ..< ns {
			a := prim.read_id(&rd)
			seq := prim.read_uvarint(&rd)
			l := prim.read_uvarint(&rd)
			flags := prim.read_u8(&rd)
			span := crdt.Author_Span {
				id       = {a, seq},
				op       = {a, seq},
				len      = int(l),
				redacted = flags & 1 != 0,
			}
			if flags & 2 != 0 {
				span.op.actor = prim.read_id(&rd)
				span.op.seq = prim.read_uvarint(&rd)
			}
			append(&r.cp_spans, span)
		}
	}
	if !prim.reader_ok(&rd) {
		return .Corrupt
	}
	return .None
}

@(private)
write_op_ref :: proc(h: ^History, id: fstree.Inode_Id, i: u32, ref: Op_Ref) -> Error {
	key := ops_key(id, i / OPS_CHUNK)
	data, _ := kv_get(&h.kv, key, context.temp_allocator) or_return
	buf := make([dynamic]u8, 0, len(data) + 24, context.temp_allocator)
	append(&buf, ..data)
	w := prim.writer(&buf)
	prim.write_uvarint(&w, u64(ref.stream))
	prim.write_uvarint(&w, ref.off)
	prim.write_uvarint(&w, u64(ref.from))
	prim.write_uvarint(&w, u64(ref.to))
	return kv_put(&h.kv, key, buf[:])
}

@(private)
read_op_ref :: proc(h: ^History, id: fstree.Inode_Id, i: u32) -> (ref: Op_Ref, err: Error) {
	data, found := kv_get(&h.kv, ops_key(id, i / OPS_CHUNK), context.temp_allocator) or_return
	if !found {
		return {}, .Corrupt
	}
	rd := prim.reader(data)
	for k: u32 = 0; k <= i % OPS_CHUNK; k += 1 {
		ref.stream = u32(prim.read_uvarint(&rd))
		ref.off = prim.read_uvarint(&rd)
		ref.from = u32(prim.read_uvarint(&rd))
		ref.to = u32(prim.read_uvarint(&rd))
	}
	if !prim.reader_ok(&rd) {
		return {}, .Corrupt
	}
	return ref, .None
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
		w := prim.writer(&buf)
		prim.write_uvarint(&w, m.event.lamport)
		prim.write_uvarint(&w, m.event.seq)
		prim.write_uvarint(&w, u64(m.event.actor))
		prim.write_uvarint(&w, u64(m.inode.actor))
		prim.write_uvarint(&w, m.inode.seq)
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
			return .Corrupt
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
		rd := prim.reader(v)
		for !prim.reader_done(&rd) {
			m: fstree.Move_Ref
			m.event.lamport = prim.read_uvarint(&rd)
			m.event.seq = prim.read_uvarint(&rd)
			m.event.actor = u32(prim.read_uvarint(&rd))
			m.inode.actor = u32(prim.read_uvarint(&rd))
			m.inode.seq = prim.read_uvarint(&rd)
			if !prim.reader_ok(&rd) {
				return false
			}
			if m.event.lamport >= from_lamport {
				append(out, m)
			}
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
	out := make([]u8, 10, context.temp_allocator)
	out[0] = 'g'
	out[1] = 'p'
	prim.put_u32le(out[2:6], k.actor)
	prim.put_u32le(out[6:10], k.page)
	return out
}

@(private)
inode_key :: proc(prefix: string, id: fstree.Inode_Id) -> []u8 {
	out := make([]u8, len(prefix) + 12, context.temp_allocator)
	n := copy(out, prefix)
	prim.put_u32le(out[n:], id.actor)
	prim.put_u64le(out[n + 4:], id.seq)
	return out
}

@(private)
node_key :: proc(k: fstree.Node_Key) -> []u8 {
	out := make([]u8, 22, context.temp_allocator)
	out[0] = 't'
	out[1] = 'n'
	prim.put_u32le(out[2:6], k.dir.actor)
	prim.put_u64le(out[6:14], k.dir.seq)
	prim.put_u64le(out[14:22], k.node)
	return out
}

@(private)
ops_key :: proc(id: fstree.Inode_Id, chunk: u32) -> []u8 {
	out := make([]u8, 18, context.temp_allocator)
	out[0] = 'f'
	out[1] = 'o'
	prim.put_u32le(out[2:6], id.actor)
	prim.put_u64le(out[6:14], id.seq)
	prim.put_u32le(out[14:18], chunk)
	return out
}

@(private)
moves_key :: proc(chunk: u64) -> []u8 {
	out := make([]u8, 10, context.temp_allocator)
	out[0] = 'm'
	out[1] = 'v'
	prim.put_u64le(out[2:10], chunk)
	return out
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
	w := prim.writer(buf)
	prim.write_uvarint(&w, u64(len(v)))
	for x in v {
		prim.write_id(&w, x.actor)
		prim.write_uvarint(&w, x.seq)
	}
}

decode_version :: proc(data: []u8, allocator := context.allocator) -> (v: Version, err: Error) {
	rd := prim.reader(data)
	n := prim.read_uvarint(&rd)
	if n > u64(len(data)) {
		return nil, .Corrupt
	}
	out := make([]crdt.Op_Id, int(n), allocator)
	for i in 0 ..< int(n) {
		out[i].actor = prim.read_id(&rd)
		out[i].seq = prim.read_uvarint(&rd)
	}
	if !prim.reader_ok(&rd) {
		delete(out, allocator)
		return nil, .Corrupt
	}
	slice.sort_by(out, crdt.op_id_less)
	return out, .None
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

REC_REPLACE :: u8(5)

batch_payload :: proc(body: []u8) -> (payload: []u8, ok: bool) {
	if len(body) == 0 {
		return nil, false
	}
	switch body[0] {
	case REC_BATCH, REC_IMPORT:
		return body[1:], true
	case REC_REPLACE:
		_, n := prim.get_uvarint(body[1:])
		if n <= 0 || 1 + n + 1 > len(body) {
			return nil, false
		}
		return body[1 + n + 1:], true
	}
	return nil, false
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
	return remap_ref(h, stream, old, off, inodes[:])
}
