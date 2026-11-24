p='src/fs/shadow.odin';s=open(p).read()
def one(a,b):
    global s
    assert s.count(a)==1,(s.count(a),a)
    s=s.replace(a,b)
one("""				r, rerr := read_rec(s, slot.off, &s.probe)
				if rerr != .None || r.del || r.entry.inode == inode {
""","""				r, rerr := read_rec(s, slot.off, &s.probe)
				if rerr != .None && rerr != .Corrupt {
					return rerr
				}
				if rerr != .None || r.del || r.entry.inode == inode {
""")
one("""			r, rerr := read_rec(s, slot.off, &s.probe)
			if rerr == .None && r.entry.inode == inode {
""","""			r, rerr := read_rec(s, slot.off, &s.probe)
			if rerr != .None && rerr != .Corrupt {
				return rerr
			}
			if rerr == .None && r.entry.inode == inode {
""")
one("""				r, rerr2 := read_rec(s, off, &s.probe)
				if rerr2 == .None && r.path == path {
""","""				r, rerr := read_rec(s, off, &s.probe)
				if rerr != .None && rerr != .Corrupt {
					return 0, {}, false, rerr
				}
				if rerr == .None && r.path == path {
""")
one("""			r, err := read_rec(s, prim.get_u64le(block[k + 8:k + 16]), &s.scratch)
			if err == .None && !r.del {
""","""			r, err := read_rec(s, prim.get_u64le(block[k + 8:k + 16]), &s.scratch)
			if err != .None && err != .Corrupt {
				return err
			}
			if err == .None && !r.del {
""")
open(p,'w').write(s)
