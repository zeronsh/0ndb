package sim

import "core:encoding/endian"
import "core:strings"
import eng "../../src/engine"
import "../../src/odb"
import "../../src/prim"

@(private = "file")
Ck_Watch :: struct {
	node: int,
	obj:  int,
}

@(private = "file", thread_local)
ck_watch: [dynamic]Ck_Watch

STAT_CK_PUBLISHED: Stat
STAT_CK_LOADS: Stat
STAT_CK_CRASHES: Stat
STAT_ODB_VERIFIED: Stat

@(init)
_ckpt_init :: proc "contextless" () {
	register_op(41, "checkpoint", _ck_weight, _ck_run)
	register_world(41, nil, _ck_destroy)
	register_step(41, _ck_step)
	register_restarted(26, check_odb_intact)
	register_collect(41, _ck_collect)
	register_stat_line(63, "checkpoints")
	STAT_CK_PUBLISHED = register_stat(63, 0, "published")
	STAT_CK_LOADS = register_stat(63, 1, "loaded")
	STAT_CK_CRASHES = register_stat(63, 2, "crashes_after_load_sync")
	STAT_ODB_VERIFIED = register_stat(62, 2, "objects_verified")
}

@(private = "file")
_ck_destroy :: proc(w: ^World) {
	delete(ck_watch)
	ck_watch = nil
}

@(private = "file")
_ck_collect :: proc(w: ^World, res: ^Run_Result) {
	for n in w.nodes {
		res.stats.extra[int(STAT_CK_CRASHES)] += n.disk.blob_ckpt_crashes
	}
}

@(private = "file")
_ck_kind :: proc(k: M_Kind) -> bool {
	return k == .Tree
}

@(private = "file")
_ck_weight :: proc(w: ^World) -> int {
	if w.cfg.storage != .Auto {
		return 0
	}
	for ob in w.model.objs {
		if _ck_kind(ob.kind) {
			return 2
		}
	}
	return 0
}

@(private = "file")
_ck_run :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open || n.disk.dead {
		return
	}
	m := &w.model
	cands := make([dynamic]int, context.temp_allocator)
	for &ob, oi in m.objs {
		if _ck_kind(ob.kind) && obj_exists(m, oi) && obj_reader(m, oi, n.idx) {
			si := space_index(m, ob.o.space)
			if si >= 0 && space_member(&m.spaces[si], n.idx) {
				append(&cands, oi)
			}
		}
	}
	if len(cands) == 0 {
		return
	}
	oi := cands[rng_int(&w.rng, len(cands))]
	ob := &m.objs[oi]
	context = instance_context(&n.inst)
	defer node_after(n)
	err := eng.object_promote_run(&n.e, ob.o)
	length, _, found := eng.checkpoint_info(&n.e, ob.o)
	world_note(w, "%s checkpoint %v %s -> %v (length %d found %v)", n.name, ob.kind, id_short(ob.o.id), err, length, found)
	if err != .None {
		return
	}
	if !found || length <= 0 {
		return
	}
	stat_add(w, STAT_CK_PUBLISHED)
	if ck_watch == nil {
		ck_watch = make([dynamic]Ck_Watch, w.allocator)
	}
	si := space_index(m, ob.o.space)
	for b in w.nodes {
		if b == n || si < 0 || !space_member(&m.spaces[si], b.idx) {
			continue
		}
		dup := false
		for x in ck_watch {
			if x.node == b.idx && x.obj == oi {
				dup = true
				break
			}
		}
		if !dup {
			append(&ck_watch, Ck_Watch{node = b.idx, obj = oi})
		}
	}
}

@(private = "file")
_ck_step :: proc(w: ^World, n: ^Node) {
	if len(ck_watch) == 0 || n.disk.dead {
		return
	}
	for i := 0; i < len(ck_watch); {
		x := &ck_watch[i]
		if x.node != n.idx {
			i += 1
			continue
		}
		_, loaded, found := eng.checkpoint_info(&n.e, w.model.objs[x.obj].o)
		if !found {
			i += 1
			continue
		}
		if loaded && w.cfg.crash_rate > 0 {
			stat_add(w, STAT_CK_LOADS)
			world_note(w, "%s loaded checkpoint of %s; next object sync crashes", n.name, id_short(w.model.objs[x.obj].o.id))
			n.disk.blob_crash = 1
			n.disk.blob_crash_n = 0
			n.disk.blob_ckpt = true
		}
		unordered_remove(&ck_watch, i)
	}
}

check_odb_intact :: proc(w: ^World, n: ^Node) {
	if !n.alive || n.disk.dead || !n.e_open || !n.e.db_open {
		return
	}
	context = instance_context(&n.inst)
	n.disk.probe += 1
	defer n.disk.probe -= 1
	db := &n.e.db
	root := odb.primary_dir(db)
	if root == "" {
		return
	}
	hn := odb.oid_size(db.format) * 2
	hex := "0123456789abcdef"
	for i in 0 ..< 256 {
		fan := [2]u8{hex[i >> 4], hex[i & 15]}
		dir := strings.concatenate({root, "/", string(fan[:])}, context.temp_allocator)
		names := _ck_list(db.vfs, dir)
		for name in names {
			if len(name) != hn - 2 {
				continue
			}
			oid, _, ok := odb.oid_from_hex(strings.concatenate({string(fan[:]), name}, context.temp_allocator))
			if ok {
				_ck_verify(w, n, db, oid, "loose")
			}
		}
	}
	pdir := strings.concatenate({root, "/pack"}, context.temp_allocator)
	for name in _ck_list(db.vfs, pdir) {
		if !strings.has_prefix(name, "pack-") || !strings.has_suffix(name, ".idx") {
			continue
		}
		idx, rerr := prim.read_file(db.vfs, strings.concatenate({pdir, "/", name}, context.temp_allocator), context.temp_allocator)
		hsz := odb.oid_size(db.format)
		if rerr != .None || len(idx) < 8 + 1024 {
			world_fail(w, "odb: %s pack index %s under its final name does not read (%v, %d bytes)", n.name, name, rerr, len(idx))
			continue
		}
		count := int(endian.unchecked_get_u32be(idx[8 + 255 * 4:]))
		if len(idx) < 8 + 1024 + count * hsz {
			world_fail(w, "odb: %s pack index %s is torn: %d entries in %d bytes", n.name, name, count, len(idx))
			continue
		}
		for k in 0 ..< count {
			oid: odb.Oid
			copy(oid[:hsz], idx[8 + 1024 + k * hsz:][:hsz])
			_ck_verify(w, n, db, oid, name)
		}
	}
}

@(private = "file")
_ck_list :: proc(vfs: prim.Vfs, dir: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	d: prim.Dir
	if prim.dir_open(vfs, &d, dir, context.temp_allocator) != .None {
		return out
	}
	defer prim.dir_close(vfs, &d)
	for {
		e, more, err := prim.dir_next(vfs, &d)
		if err != .None || !more {
			break
		}
		append(&out, strings.clone(e.name, context.temp_allocator))
	}
	return out
}

@(private = "file")
_ck_verify :: proc(w: ^World, n: ^Node, db: ^odb.Odb, oid: odb.Oid, where_: string) {
	stat_add(w, STAT_ODB_VERIFIED)
	hb: [odb.MAX_HEX]u8
	t, data, err := odb.read(db, oid, context.temp_allocator)
	if err != .None {
		world_fail(w, "odb: %s object %s (%s) under its final name does not read: %v", n.name, odb.oid_to_string(oid, db.format, &hb), where_, err)
		return
	}
	got, herr := odb.hash(db.format, t, data)
	if herr != .None || got != oid {
		world_fail(w, "odb: %s object %s (%s) under its final name holds other content", n.name, odb.oid_to_string(oid, db.format, &hb), where_)
	}
}
