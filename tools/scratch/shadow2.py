def sub(p,*prs):
    s=open(p).read()
    for a,b,n in prs:
        assert s.count(a)==n,(p,s.count(a),a)
        s=s.replace(a,b)
    open(p,'w').write(s)
s=open('src/fs/shadow.odin').read()
i=s.index('find_path :: proc'); j=s.index('read_inode_slot ::',i)
f=s[i:j]
f=f.replace("	scanned: u64\n","	scanned: u64\n	bad := false\n",1)
f=f.replace("				return i + k, {}, false, .None\n","				return i + k, {}, false, .Corrupt if bad else .None\n",1)
f=f.replace("				if rerr == .None && r.path == path {","				bad ||= rerr == .Corrupt\n				if rerr == .None && r.path == path {",1)
open('src/fs/shadow.odin','w').write(s[:i]+f+s[j:])
sub('src/fs/ingest.odin',
("parent_tracked :: proc(p: ^Pass, rel: string) -> bool {","parent_tracked :: proc(p: ^Pass, rel: string) -> (tracked: bool, err: Error) {",1),
("""	if len(parent) == 0 {
		return true
	}
	for c in p.changes {
		if c.kind == .Create && c.path == parent && c.disk == .Dir {
			return true
		}
	}
	e, found, _ := shadow_get(&p.m.shadow, parent)
	return found && e.kind == .Dir
""","""	if len(parent) == 0 {
		return true, .None
	}
	for c in p.changes {
		if c.kind == .Create && c.path == parent && c.disk == .Dir {
			return true, .None
		}
	}
	e, found := shadow_get(&p.m.shadow, parent) or_return
	return found && e.kind == .Dir, .None
""",1),
("		parent_ok := parent_tracked(p, k)\n","		parent_ok := parent_tracked(p, k) or_return\n",1),
("		if !parent_tracked(p, rel) {\n","		if tracked := parent_tracked(p, rel) or_return; !tracked {\n",1),
("parent_inode :: proc(p: ^Pass, rel: string) -> (fstree.Inode_Id, bool) {","parent_inode :: proc(p: ^Pass, rel: string) -> (inode: fstree.Inode_Id, ok: bool, err: Error) {",1),
("		return fstree.ROOT, true\n	}\n	e, found, _ := shadow_get(&p.m.shadow, parent)\n	if found && e.kind == .Dir {\n		return e.inode, true\n	}\n	return {}, false\n","		return fstree.ROOT, true, .None\n	}\n	e, found := shadow_get(&p.m.shadow, parent) or_return\n	if found && e.kind == .Dir {\n		return e.inode, true, .None\n	}\n	return {}, false, .None\n",1),
("		parent, ok := parent_inode(p, c.path)\n","		parent, ok := parent_inode(p, c.path) or_return\n",1))
sub('src/fs/materialize.odin',
("tl: []crdt.Lv) -> (path: string, blocked: bool) {","tl: []crdt.Lv) -> (path: string, blocked: bool, err: Error) {",1),
("		return it.old, true\n	}","		return it.old, true, .None\n	}",1),
("			if _, known, _ := shadow_get(&m.shadow, it.path); !known &&","			if _, known := shadow_get(&m.shadow, it.path) or_return; !known &&",1),
("				return it.path, true\n","				return it.path, true, .None\n",1),
("	return \"\", false\n}\n\n@(private)\nmat_is_item","	return \"\", false, .None\n}\n\n@(private)\nmat_is_item",1),
("if p, blocked := mat_blocker(m, &it, tl[:]); blocked {","if p, blocked := mat_blocker(m, &it, tl[:]) or_return; blocked {",2))
sub('src/fs/mount.odin',("	prev, has_prev, _ := shadow_get(&m.shadow, rel)\n","	prev, has_prev, perr := shadow_get(&m.shadow, rel)\n	if perr != .None {\n		return\n	}\n",1))
