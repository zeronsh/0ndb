import re
def sub(p,*prs):
    s=open(p).read()
    for a,b in prs:
        assert s.count(a)==1,(p,s.count(a),a)
        s=s.replace(a,b)
    open(p,'w').write(s)
sub('src/fs/fs.odin',("	Reloading,\n	Deferred,\n}","	Reloading,\n	Deferred,\n	Newer,\n}"))
sub('src/fs/kv.odin',
("KV_MAGIC_V1 :: u64(0x3167_6f6c_7662_6430)\n","KV_MAGIC_V1 :: u64(0x3167_6f6c_7662_6430)\nKV_FAMILY :: u64(0x00ff_ffff_ffff_ffff)\n"),
("""	if got != KV_LOG_HEADER || (magic != KV_MAGIC && magic != KV_MAGIC_V1) {
		return .Corrupt
	}
""","""	if got == KV_LOG_HEADER && magic & KV_FAMILY == KV_MAGIC & KV_FAMILY && magic > KV_MAGIC {
		return .Newer
	}
	if got != KV_LOG_HEADER || (magic != KV_MAGIC && magic != KV_MAGIC_V1) {
		return .Corrupt
	}
"""))
sub('src/engine/engine.odin',("	Io,\n	Conflict,\n}","	Io,\n	Conflict,\n	Newer,\n}"))
sub('src/engine/store.odin',("	case .Redacted:\n		return .Missing\n	}\n	return .Io\n}\n","	case .Redacted:\n		return .Missing\n	case .Newer:\n		return .Newer\n	}\n	return .Io\n}\n"))
sub('src/engine/checkpoint.odin',("		_ckpt_discard(e, hdir)\n		return _ferr(lerr)","		if lerr != .Newer {\n			_ckpt_discard(e, hdir)\n		}\n		return _ferr(lerr)"))
sub('src/engine/plugs.odin',
("	mounts:    [dynamic]^Mounted,\n	jobs:","	mounts:    [dynamic]^Mounted,\n	refused:   [dynamic]Refused,\n	jobs:"),
("@(private)\nPlug_State :: struct {","Refused :: struct {\n	object: Object,\n	root:   string,\n}\n\n@(private)\nPlug_State :: struct {"),
("		e.plug.mounts = make([dynamic]^Mounted, e.allocator)\n","		e.plug.mounts = make([dynamic]^Mounted, e.allocator)\n		e.plug.refused = make([dynamic]Refused, e.allocator)\n"),
("		delete(e.plug.mounts)\n","		delete(e.plug.mounts)\n		for r in e.plug.refused {\n			delete(r.root, e.allocator)\n		}\n		delete(e.plug.refused)\n"),
("	hist := tree_history(e, o) or_return\n	defer if m == nil {\n		tree_release(e, o)\n	}\n	db := device_odb(e) or_return\n	mid :=","""	for r in e.plug.refused {
		if r.root == root && r.object != o {
			return nil, .Newer
		}
	}
	hist, herr := tree_history(e, o)
	if herr == .Newer {
		_refuse(e, o, root) or_return
	}
	if herr != .None {
		return nil, herr
	}
	defer if m == nil {
		tree_release(e, o)
	}
	tree_refused_clear(e, root)
	db := device_odb(e) or_return
	mid :="""),
("@(private)\n_mounts_durable ::","""@(private)
_refuse :: proc(e: ^Engine, o: Object, root: string) -> Error {
	for r in e.plug.refused {
		if r.root == root {
			return .None
		}
	}
	c, aerr := strings.clone(root, e.allocator)
	if aerr != nil {
		return .No_Memory
	}
	if _, perr := append(&e.plug.refused, Refused{o, c}); perr != nil {
		delete(c, e.allocator)
		return .No_Memory
	}
	return .None
}

tree_refused :: proc(e: ^Engine) -> []Refused {
	return e.plug.refused[:]
}

tree_refused_clear :: proc(e: ^Engine, root: string) -> bool {
	for r, i in e.plug.refused {
		if r.root == root {
			delete(r.root, e.allocator)
			ordered_remove(&e.plug.refused, i)
			return true
		}
	}
	return false
}

@(private)
_mounts_durable ::"""))
sub('src/capi/api/call.odin',
("	Timeout      = 26,\n","	Timeout      = 26,\n	Newer        = 27,\n"),
('STATUS_NAMES := [27]string','STATUS_NAMES := [28]string'),
('"spawn", "timeout"}','"spawn", "timeout", "newer"}'),
("	case .Conflict:\n		return .Conflict\n	}\n	return .Io\n}\n\nOp_Proc","	case .Conflict:\n		return .Conflict\n	case .Newer:\n		return .Newer\n	}\n	return .Io\n}\n\nOp_Proc"))
sub('src/capi/api/ops.odin',('"mounts:[Mounted]"','"mounts:[Mounted], refused:[Refused]"'))
p='src/capi/api/ops_tree.odin';s=open(p).read()
i=s.index('op_tree_mounts ::'); j=s.index('	o_end(o)\n	return .Ok',i)
s=s[:j]+"""	o_end(o)
	refused := eng.tree_refused(c.api.e)
	o_arr(o, "refused", len(refused))
	for r in refused {
		o_obj(o, "")
		o_object(o, "object", r.object)
		o_str(o, "root", r.root)
		o_end(o)
	}
"""+s[j:]
open(p,'w').write(s)
sub('src/cli/daemon.odin',
('			fmt.eprintfln("0ndb: cannot remount %s: %s", m.root, api.STATUS_NAMES[int(st)])','			fmt.eprintfln("0ndb: cannot remount %s: %s%s", m.root, api.STATUS_NAMES[int(st)], status_hint(st))'),
("			ordered_remove(&d.state.mounts, i)\n			found = true\n			break\n		}\n	}\n","			ordered_remove(&d.state.mounts, i)\n			found = true\n			break\n		}\n	}\n	if eng.tree_refused_clear(c.api.e, root) {\n		found = true\n	}\n"))
sub('src/cli/main.odin',
('		fmt.eprintf(" (%s)", api.STATUS_NAMES[int(st)])','		fmt.eprintf(" (%s)%s", api.STATUS_NAMES[int(st)], status_hint(st))'),
("report_error :: proc","""status_hint :: proc(st: api.Status) -> string {
	return ": its history was written by a newer 0ndb; update 0ndb" if st == .Newer else ""
}

report_error :: proc"""))
sub('src/cli/cmds_misc.odin',
("""	root := abs_path(a.pos[0])
	convo: api.Object
""","""	root := abs_path(a.pos[0])
	has_tree := flag_bool(a, "tree")
	for r in jarr(must(s, `{"op":"tree.mounts"}`), "refused") {
		if jstr(r, "root") == root && !has_tree {
			return report_error(.Newer, "cannot mount %s", root)
		}
	}
	convo: api.Object
"""),
("""			fmt.printfln("%s → tree %s (%s)", jstr(m, "root"), short(hex(ob.id)), jstr(m, "line"))
		}
""","""			fmt.printfln("%s → tree %s (%s)", jstr(m, "root"), short(hex(ob.id)), jstr(m, "line"))
		}
		for m in jarr(v, "refused") {
			ob, _ := api.parse_object(jstr(m, "object"))
			fmt.printfln("%s → tree %s (newer)%s", jstr(m, "root"), short(hex(ob.id)), status_hint(.Newer))
		}
"""),
("""		fmt.printfln("mount    %s → tree %s (%s)", jstr(m, "root"), short(hex(ob.id)), jstr(m, "line"))
	}
""","""		fmt.printfln("mount    %s → tree %s (%s)", jstr(m, "root"), short(hex(ob.id)), jstr(m, "line"))
	}
	for m in jarr(mt, "refused") {
		ob, _ := api.parse_object(jstr(m, "object"))
		fmt.printfln("mount    %s → tree %s (newer)%s", jstr(m, "root"), short(hex(ob.id)), status_hint(.Newer))
	}
"""))
sub('include/0ndb.h',("	ONDB_TIMEOUT = 26\n","	ONDB_TIMEOUT = 26,\n	ONDB_NEWER = 27\n"),("/* tree.mounts() -> mounts:[Mounted] */","/* tree.mounts() -> mounts:[Mounted], refused:[Refused] */"))
sub('docs/daemon-protocol.md',("| 95 | `tree.mounts` | – | mounts:[Mounted] |","| 95 | `tree.mounts` | – | mounts:[Mounted], refused:[Refused] |"),("| 8 | permission | 17 | no_space | 26 | timeout |","| 8 | permission | 17 | no_space | 26 | timeout |\n| | | | | 27 | newer |"))
sub('bindings/rust/ondb/src/error.rs',("[&str; 27]","[&str; 28]"),('    "timeout",\n','    "timeout",\n    "newer",\n'),("    pub const TIMEOUT: Status = Status(26);\n","    pub const TIMEOUT: Status = Status(26);\n    pub const NEWER: Status = Status(27);\n"))
