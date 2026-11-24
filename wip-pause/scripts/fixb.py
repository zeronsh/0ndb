import sys
p=sys.argv[1]+'/src/fs/mount.odin'; s=open(p).read()
a='''		spans := []crdt.Lv_Span{{lv = lv, len = int(it.n)}}
		spans_touched(h, spans, &touched) or_return
		recovered = true
'''
assert s.count(a)==1
s=s.replace(a,'''		spans := []crdt.Lv_Span{{lv = lv, len = int(it.n)}}
		proven := true
		{
			_, _, ist, ioff, iok := history_batch_at(h, lv)
			if !iok {
				return .Corrupt
			}
			ib := history_read_batch(h, ist, ioff, context.temp_allocator) or_return
			base := make([dynamic]crdt.Lv, context.temp_allocator)
			crdt.version_union(&h.g, have[:], ends[:], &base)
			for pid in ib.parents {
				pl, pok := crdt.graph_lv(&h.g, pid)
				proven &&= pok && crdt.graph_contains(&h.g, base[:], pl)
			}
		}
		if !proven {
			own := make(map[fstree.Inode_Id]bool, context.temp_allocator)
			spans_touched(h, spans, &own) or_return
			end := crdt.Op_Id{it.actor, it.seq + it.n - 1}
			append(&apart, Recovered_Intent{end = end, touched = own})
			continue
		}
		spans_touched(h, spans, &touched) or_return
		recovered = true
''')
s=s.replace('''	by_intent := make([dynamic]Recovered_Intent, context.temp_allocator)
	lost := make''','''	by_intent := make([dynamic]Recovered_Intent, context.temp_allocator)
	apart := make([dynamic]Recovered_Intent, context.temp_allocator)
	lost := make''',1)
a='''	m.jpend = mount_jlen(m)
	history_trim(h)
	return mount_settle(m)
}'''
assert s.count(a)==1
s=s.replace(a,'''	for it in apart {
		for ino in sorted_inodes(it.touched) {
			rel, e, had := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return
			if !had || e.kind != .File {
				continue
			}
			at := [1]crdt.Op_Id{it.end}
			t, terr := history_text_at(h, ino, at[:], context.temp_allocator)
			if terr != .None {
				continue
			}
			one := [1]fstree.Op_Id{op_inode(h, it.end)}
			e.ver = shadow_version_add(&m.shadow, one[:]) or_return
			e.stat = {}
			if m.db != nil {
				e.oid, _ = odb.hash(m.db.format, .Blob, t)
			}
			shadow_put(&m.shadow, rel, e) or_return
			mount_reshow_add(m, rel)
		}
	}
'''+a)
open(p,'w').write(s)
