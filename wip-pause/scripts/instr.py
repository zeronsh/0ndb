import sys
root=sys.argv[1]
p=root+'/src/fs/mount.odin'; s=open(p).read()
a='''	if len(lost) > 0 {
		drop_lost(m, "", lost[:]) or_return
	}
	if recovered {
'''
assert s.count(a)==1
s=s.replace(a,'''	if len(lost) > 0 {
		drop_lost(m, "", lost[:]) or_return
	}
	sig_out, sig_obs, sig_edit, sig_in := 0, 0, 0, 0
	for it in m.intents {
		lv, okl := crdt.graph_lv(&h.g, crdt.Op_Id{it.actor, it.seq})
		if !okl { continue }
		if crdt.graph_contains(&h.g, have[:], lv) { continue }
		_, _, st, off, bok := history_batch_at(h, lv)
		if !bok { continue }
		b, be := history_read_batch(h, st, off, context.temp_allocator)
		if be != .None { continue }
		outside := false
		for pid in b.parents {
			if pl, pok := crdt.graph_lv(&h.g, pid); !pok || !crdt.graph_contains(&h.g, have[:], pl) { outside = true }
		}
		if !outside { sig_in += 1; continue }
		sig_out += 1
		edit := false
		for op in b.ops { if op.kind != .Opaque { edit = true } }
		if edit { sig_edit += 1 } else { sig_obs += 1 }
	}
	fmt.eprintfln("SIGR intents=%d in=%d outside=%d observe_only=%d edits=%d", len(m.intents), sig_in, sig_out, sig_obs, sig_edit)
	defer {
		se, _, _ := shadow_get(&m.shadow, "a.txt")
		dd, _ := prim.read_file(m.vfs, "/work/named-n0-git/a.txt", context.temp_allocator)
		tt, _ := history_text_at(h, se.inode, m.synced[:], context.temp_allocator)
		owed := false
		for q in m.absent { owed ||= q == "a.txt" }
		for q in m.reshow { owed ||= q == "a.txt" }
		fmt.eprintfln("SIGE ver=%d owed=%v synced_w=%v disk_w=%v same=%v", se.ver != 0 ? 1 : 0, owed, strings.contains(string(tt), "other line"), strings.contains(string(dd), "other line"), string(tt) == string(dd))
	}
	if recovered {
''')
if '"core:fmt"' not in s: s=s.replace('package fs\n','package fs\n\nimport "core:fmt"\n',1)
open(p,'w').write(s)
print('core:strings' in s)
t=open('/home/user/gates/retarget/nv.odin').read()
t=t.replace('for bits in 0 ..< 10 {','for bits in ([]int{2, 3, 6, 7}) {').replace('for kind in Named_Kind {','for kind in ([]Named_Kind{.Checkout_Existing}) {')
t=t.replace('''				failures, res := named_version_run(1, arm, k)
''','''				fmt.eprintf("SIGK %v p=%v c=%v k=%d\\n", kind, arm.process, arm.control, k)
				failures, res := named_version_run(1, arm, k)
''')
open(root+'/tests/sim/named_version_crash.odin','w').write(t)
