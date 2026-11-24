import sys
m,root=sys.argv[1],sys.argv[2]
I=root+'/src/fs/ingest.odin'; B=root+'/src/fs/base.odin'; M=root+'/src/fs/mount.odin'
def sub(p,a,b,c=1):
    s=open(p).read(); assert s.count(a)==c,(p,a[:80],s.count(a)); open(p,'w').write(s.replace(a,b))
if m=='landed': sub(I,'landed := st.step != {} && (st.step in m.landed || m.landed_gone)','landed := false')
elif m=='firstmatch': sub(I,'			replayed = true\n			cur = st.oid\n			last = st\n','			replayed = true\n			cur = st.oid\n			last = st\n			if st.oid == disk_oid { break }\n')
elif m=='devicerule': sub(I,'(st.step == {} && st.scope != {} && shown','(st.step == {} && shown')
elif m=='departing': sub(I,'				replay_departing(m, p.long, &replayed) or_return\n','')
elif m=='union': sub(I,'crdt.graph_version_lvs(&h.g, replayed.heads[:], &rl) != .None','false')
elif m=='reshow': sub(I,'		for path in replayed.paths {\n			mount_reshow_add(m, path)\n		}','')
elif m=='rest': sub(I,'		if replayed && !gone {\n			if settled','		if false && replayed && !gone {\n			if settled')
elif m=='steplog': sub(B,'logged.needed = a.step == {} && (c.scope != nil || c.scope_id != {})','logged.needed = false')
elif m=='steplog2': sub(B,'	logged.needed = true\n		}','	logged.needed = false\n		}')
elif m=='namedbase': sub(I,'	if c.old.ver != 0 && c.old.inode == inode {','	if false {')
elif m=='lostused': sub(M,'''		if a.step != {} {
			from = min(from, a.at)
		}''','''		if !a.used && a.step != {} {
			from = min(from, a.at)
		}''')
elif m=='entryheads': sub(I,'named.ver != 0 {','false {')
else: raise SystemExit('unknown')
