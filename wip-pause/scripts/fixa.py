import sys
p=sys.argv[1]+'/src/fs/ingest.odin'; s=open(p).read()
a='''	if want != disk_oid {
		return false, .None
	}
	adopt_version(p, line, ver) or_return
	e := Entry{inode = ino, kind = .File, stat = c.stat, oid = disk_oid, ver = ver^}'''
assert s.count(a)==1
s=s.replace(a,'''	if want != disk_oid {
		return false, .None
	}
	fver: u32
	if .Opaque in info.flags {
		adopt_version(p, line, ver) or_return
		fver = ver^
	} else {
		own := inode_frontier(h, ino, ll) or_return
		t := history_text_at(h, ino, own, context.temp_allocator) or_return
		if got, _ := odb.hash(m.db.format, .Blob, t); got != disk_oid {
			return false, .None
		}
		ids := make([dynamic]fstree.Op_Id, context.temp_allocator)
		for id in own {
			append(&ids, op_inode(h, id))
		}
		fver = shadow_version_add(&m.shadow, ids[:]) or_return
	}
	e := Entry{inode = ino, kind = .File, stat = c.stat, oid = disk_oid, ver = fver}''')
a='''@(private)
adopt_version :: proc('''
s=s.replace(a,'''@(private)
inode_frontier :: proc(h: ^History, ino: fstree.Inode_Id, ll: []crdt.Lv) -> (v: []crdt.Op_Id, err: Error) {
	tmp: File_State
	tmp.inode = ino
	if f, ok := h.files[ino]; ok {
		tmp.rec = f.rec
		tmp.new_refs = f.new_refs
	} else {
		read_file_record(h, ino, &tmp.rec) or_return
	}
	defer fshist.text_drop(&tmp.st)
	load_text(h, &tmp, ll, true) or_return
	tops := make([dynamic]crdt.Lv, context.temp_allocator)
	if cl, ok := crdt.graph_lv(&h.g, inode_op(h, ino)); ok {
		append(&tops, cl)
	}
	for e in tmp.log.entries {
		last := e.lv + crdt.Lv(max(e.len, 1)) - 1
		if crdt.graph_contains(&h.g, ll, last) {
			append(&tops, last)
		}
	}
	out := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, tops[:], nil, &out)
	return crdt.graph_version_ids(&h.g, out[:], context.temp_allocator), .None
}

'''+a,1)
open(p,'w').write(s)
