def sub(p,*prs):
    s=open(p).read()
    for a,b,n in prs:
        assert s.count(a)==n,(p,s.count(a),a); s=s.replace(a,b)
    open(p,'w').write(s)
sub('src/fs/heal.odin',("	m := x.m\n	kids, kerr","	kids, kerr",1))
sub('src/fs/mount.odin',
("	reshow:      ","	held:        [dynamic]string,\n	opened:      bool,\n	reshow:      ",1),
("	m.reshow = make([dynamic]string, allocator)\n","	m.reshow = make([dynamic]string, allocator)\n	m.held = make([dynamic]string, allocator)\n",1),
("	delete(m.reshow)\n	for k in m.dirty {","	delete(m.reshow)\n	for c in m.held {\n		delete(c, m.allocator)\n	}\n	delete(m.held)\n	for k in m.dirty {",1),
("			shadow_open(&m.shadow, m.vfs, sp, format, m.allocator) or_return","			shadow_open(&m.shadow, m.vfs, sp, format, m.allocator, m.shadow_mark) or_return",1),
("			m.reload_ms = 0\n			m.reload_owed = false\n		}\n		return err\n	}\n	sp, _","			m.reload_ms = 0\n			m.reload_owed = false\n			err = mount_heal(m)\n		}\n		return err\n	}\n	sp, _",1),
("		m.watched = true\n	}\n	return .None\n}\n\nmount_hibernate","		m.watched = true\n	}\n	return mount_heal(m)\n}\n\nmount_hibernate",1),
("	prim.write_ivarint(&w, rec.reflog_pos)\n	sum :=","	prim.write_ivarint(&w, rec.reflog_pos)\n	prim.write_uvarint(&w, u64(len(m.held)))\n	for p in m.held {\n		prim.write_str(&w, p)\n	}\n	sum :=",1),
("		rec_reflog = prim.read_ivarint(&rd)\n	}\n	m.jpend","		rec_reflog = prim.read_ivarint(&rd)\n	}\n	if prim.reader_remaining(&rd) > 0 {\n		nh := prim.read_uvarint(&rd)\n		if nh > u64(prim.reader_remaining(&rd)) {\n			return false, .Corrupt\n		}\n		for _ in 0 ..< nh {\n			p := prim.read_str(&rd)\n			if prim.reader_ok(&rd) {\n				mount_held_add(m, p)\n			}\n		}\n	}\n	m.jpend",1),
("	rerr := mount_open_rest(m, fresh)\n	if err := rerr;","	rerr := mount_open_rest(m, fresh)\n	if rerr == .Corrupt && m.shadow.damaged {\n		mount_heal(m) or_return\n		rerr = mount_open_rest(m, fresh)\n	}\n	if err := rerr;",1),
("	if err == .Reloading {\n		mount_reload_retry(m)\n	}\n	if fence {","	if err == .Reloading {\n		mount_reload_retry(m)\n	}\n	if err == .Corrupt && m.shadow.damaged {\n		m.rescan = true\n		mount_schedule(m, 0)\n	}\n	if fence {",1))
s=open('src/fs/mount.odin').read(); s=s.replace("	opened:      bool,\n","",1); open('src/fs/mount.odin','w').write(s)
sub('src/fs/ingest.odin',
("add_create :: proc(p: ^Pass, rel: string, d: Probe) -> Error {\n","add_create :: proc(p: ^Pass, rel: string, d: Probe) -> Error {\n	if held := mount_held_settle(p.m, rel, d) or_return; held {\n		mark_seen(p, rel)\n		return .None\n	}\n",1),
("add_modify :: proc(p: ^Pass, rel: string, d: Probe, e: Entry) {\n","add_modify :: proc(p: ^Pass, rel: string, d: Probe, e: Entry) -> Error {\n	if held := mount_held_settle(p.m, rel, d) or_return; held {\n		mark_seen(p, rel)\n		return .None\n	}\n",1),
("		add_modify(p, rel, d, e)\n","		return add_modify(p, rel, d, e)\n",2),
("add_remove_tree :: proc(p: ^Pass, rel: string, e: Entry) -> Error {\n	m := p.m\n","add_remove_tree :: proc(p: ^Pass, rel: string, e: Entry) -> Error {\n	m := p.m\n	if len(m.held) > 0 && mount_held_has(m, rel) {\n		mark_seen(p, rel)\n		return .None\n	}\n",1))
s=open('src/fs/ingest.odin').read()
i=s.index("add_modify :: proc"); j=s.index("\n}\n",i); 
s=s[:j]+"\n	return .None"+s[j:]
open('src/fs/ingest.odin','w').write(s)
sub('src/fs/materialize.odin',("materialize_inner :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> Error {\n","materialize_inner :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> Error {\n	if len(m.held) > 0 && (it.present && mount_held_has(m, it.path) || it.has_old && mount_held_has(m, it.old)) {\n		mount_reshow_add(m, it.path if it.present else it.old)\n		return .None\n	}\n",1))
