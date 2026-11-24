import sys,subprocess
m,root=sys.argv[1],sys.argv[2]
I=root+'/src/fs/ingest.odin'; B=root+'/src/fs/base.odin'; H=root+'/src/fs/history.odin'; M=root+'/src/fs/mount.odin'
def sub(p,a,b,c=1):
    s=open(p).read(); assert s.count(a)==c,(p,a[:80],s.count(a)); open(p,'w').write(s.replace(a,b))
if m=='landed': sub(H,'	return found, .None\n}\n\nhistory_scope_of','	return false, .None\n}\n\nhistory_scope_of')
elif m=='firstmatch': sub(I,'''			replayed = true
			cur = st.oid
			last = st
''','''			replayed = true
			cur = st.oid
			last = st
			if st.oid == disk_oid { break }
''')
elif m=='devicerule': sub(I,'(st.step == {} && st.scope != {} && shown','(st.step == {} && shown')
elif m=='departing': sub(I,'				replay_departing(m, p.long, &replayed) or_return\n','')
elif m=='forkheads': sub(I,'''		for path in replayed.paths {
			mount_reshow_add(m, path)
		}''','',) ; 
elif m=='rest': sub(I,'		if replayed && !gone {\n			if settled','		if false && replayed && !gone {\n			if settled')
elif m=='steplog': sub(B,'logged.needed = a.step == {} && (c.scope != nil || c.scope_id != {})','logged.needed = false').__class__
elif m=='namedbase': sub(I,'	if c.old.ver != 0 && c.old.inode == inode {','	if false {')
else: raise SystemExit('unknown')
