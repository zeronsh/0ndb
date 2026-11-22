package sim

import "core:fmt"
import "core:slice"
import "core:strings"
import eng "../../src/engine"
import "../../src/odb"

SIM_REMOTE_URL :: "sim://origin/"

Sim_Git_Req :: struct {
	node: int,
	inc:  int,
	req:  ^eng.Git_Fetch,
	live: bool,
}

Sim_Remote :: struct {
	objects: map[odb.Oid][]u8,
	reqs:    [dynamic]Sim_Git_Req,
	rng:     Rng,
	fetches: u64,
	served:  u64,
	refused: u64,
}

remote_init :: proc(w: ^World) {
	w.remote.objects = make(map[odb.Oid][]u8, w.allocator)
	w.remote.reqs = make([dynamic]Sim_Git_Req, w.allocator)
	rng_init(&w.remote.rng, w.cfg.seed, 77)
}

remote_destroy :: proc(w: ^World) {
	for _, v in w.remote.objects {
		delete(v, w.allocator)
	}
	delete(w.remote.objects)
	delete(w.remote.reqs)
}

remote_push :: proc(w: ^World, n: ^Node, root: string, oids: []odb.Oid) {
	db: odb.Odb
	vfs := disk_vfs(&n.disk)
	if odb.open(&db, vfs, root, nil, context.temp_allocator) != .None {
		return
	}
	defer odb.close(&db)
	for oid in oids {
		if _, has := w.remote.objects[oid]; has {
			continue
		}
		t, data, err := odb.read(&db, oid, context.temp_allocator)
		if err != .None || t != .Blob {
			continue
		}
		b := make([]u8, len(data), w.allocator)
		copy(b, data)
		w.remote.objects[oid] = b
	}
}

sim_git_remote :: proc(n: ^Node) -> eng.Git_Remote {
	return eng.Git_Remote{data = n, fetch = _sg_fetch, cancel = _sg_cancel}
}

@(private = "file")
_sg_fetch :: proc(data: rawptr, e: ^eng.Engine, req: ^eng.Git_Fetch) -> eng.Error {
	n := (^Node)(data)
	w := n.w
	if !strings.has_prefix(req.url, SIM_REMOTE_URL) {
		return .Unsupported
	}
	append(&w.remote.reqs, Sim_Git_Req{node = n.idx, inc = n.incarnation, req = req, live = true})
	w.remote.fetches += 1
	at := w.now + rng_range(&w.remote.rng, 1, 300) * 1_000_000
	schedule(w, Sim_Event{at = at, kind = .Git_Fetch, node = n.idx, arg = u64(len(w.remote.reqs) - 1)})
	return .None
}

@(private = "file")
_sg_cancel :: proc(data: rawptr, e: ^eng.Engine, req: ^eng.Git_Fetch) {
	n := (^Node)(data)
	for &q in n.w.remote.reqs {
		if q.live && q.req == req {
			q.live = false
		}
	}
}

remote_event :: proc(w: ^World, ev: ^Sim_Event) {
	if int(ev.arg) >= len(w.remote.reqs) {
		return
	}
	q := &w.remote.reqs[ev.arg]
	if !q.live {
		return
	}
	q.live = false
	n := w.nodes[q.node]
	if !n.alive || !n.e_open || n.incarnation != q.inc {
		return
	}
	req := q.req
	context = instance_context(&n.inst)
	err := eng.Error.None
	if n.partitioned {
		err = .Offline
		w.remote.refused += 1
	} else {
		db: odb.Odb
		if odb.open_store(&db, disk_vfs(&n.disk), req.git_dir, nil, req.format, context.temp_allocator) == .None {
			for oid in req.oids {
				if body, ok := w.remote.objects[oid]; ok {
					if _, werr := odb.write(&db, .Blob, body); werr == .None {
						w.remote.served += 1
					}
				}
			}
			odb.barrier(&db)
			odb.close(&db)
		} else {
			err = .Io
		}
	}
	if n.alive && n.e_open && n.incarnation == q.inc {
		eng.git_fetch_done(&n.e, req, err)
	}
	node_after(n)
}

check_move :: proc(w: ^World) {
	m := &w.model
	refs := make(map[int]string, w.allocator)
	defer {
		for _, v in refs {
			delete(v, w.allocator)
		}
		delete(refs)
	}
	for _, oi in m.objs {
		if !obj_exists(m, oi) || m.objs[oi].kind == .Map {
			continue
		}
		for idx in readers_of(w, oi) {
			d := digest_object(w, w.nodes[idx], oi)
			if d.complete {
				refs[oi] = strings.clone(_move_strip(d.text), w.allocator)
				delete(d.text, w.allocator)
				break
			}
		}
	}
	if len(refs) == 0 {
		return
	}
	mv := new(Node, w.allocator)
	mv.w = w
	mv.idx = len(w.nodes)
	mv.name = fmt.aprintf("mv%d", mv.idx, allocator = w.allocator)
	disk_init(&mv.disk, mv.name, w.allocator)
	mv.clock = Node_Clock{w = w, mono_off = rng_range(&w.remote.rng, 0, 1 << 40), wall_off = rng_range(&w.remote.rng, -30_000_000_000, 30_000_000_000)}
	mv.disk.wall = clock_wall
	mv.disk.wall_data = &mv.clock
	rng_init(&mv.disk.fail_rng, w.cfg.seed, 5000 + u64(mv.idx))
	mv.conns = make([dynamic]^Conn, w.allocator)
	mv.mounts = make([dynamic]Sim_Mount, w.allocator)
	mv.writers = make(map[string]Writer_Info, w.allocator)
	append(&w.nodes, mv)
	if !node_start(mv) {
		world_fail(w, "move: %s could not start", mv.name)
		return
	}
	for &sp, s in m.spaces {
		sponsor: ^Node
		for idx in sp.members {
			if w.nodes[idx].alive && w.nodes[idx].e_open {
				sponsor = w.nodes[idx]
				break
			}
		}
		if sponsor == nil {
			continue
		}
		proof: []u8
		{
			context = instance_context(&sponsor.inst)
			p, aerr := eng.member_add(&sponsor.e, sp.id, mv.identity, .Device, .Admin, .Approval, 0, w.allocator)
			node_after(sponsor)
			if aerr != .None {
				world_fail(w, "move: %s member_add for %s failed: %v", sponsor.name, mv.name, aerr)
				return
			}
			proof = p
		}
		context = instance_context(&mv.inst)
		if _, err := eng.space_join_enrollment(&mv.e, sp.id, proof, fmt.tprintf("space%d", s), "relay", w.relay.public); err != .None {
			world_fail(w, "move: %s space_join_enrollment failed: %v", mv.name, err)
			return
		}
		if err := eng.space_open(&mv.e, sp.id); err != .None {
			world_fail(w, "move: %s space_open failed: %v", mv.name, err)
			return
		}
		node_after(mv)
	}
	run_until(w, w.now + 120_000_000_000, true)
	for n in w.nodes {
		if n == mv || n.partitioned {
			continue
		}
		n.partitioned = true
		for c in n.conns {
			conn_reset(c, true)
		}
	}
	world_note(w, "move: every original device offline; %s reads %d objects from the relay and the remote", mv.name, len(refs))
	pending := make(map[int]string, w.allocator)
	defer delete(pending)
	for round in 0 ..< 12 {
		run_until(w, w.now + 120_000_000_000, true)
		if len(w.failures) > 0 || w.aborted {
			return
		}
		clear(&pending)
		order := make([dynamic]int, context.temp_allocator)
		for oi in refs {
			append(&order, oi)
		}
		slice.sort(order[:])
		for oi in order {
			ref := refs[oi]
			ob := &m.objs[oi]
			si := space_index(m, ob.o.space)
			if si < 0 {
				continue
			}
			d := digest_object(w, mv, oi)
			if !d.complete {
				pending[oi] = ""
				continue
			}
			got := _move_strip(d.text)
			if got != ref {
				world_fail(w, "move: %s reads %v %s differently with every original device offline:\n--- original\n%s--- %s\n%s", mv.name, ob.kind, id_short(ob.o.id), ref, mv.name, got)
			}
			delete(d.text, w.allocator)
			delete(ref, w.allocator)
			delete_key(&refs, oi)
		}
		if len(refs) == 0 {
			break
		}
		_ = round
	}
	left := make([dynamic]int, context.temp_allocator)
	for oi in pending {
		append(&left, oi)
	}
	slice.sort(left[:])
	for oi in left {
		ob := &m.objs[oi]
		holders, unavailable := eng.availability(&mv.e, ob.o, context.temp_allocator)
		if unavailable {
			world_note(w, "move: %v %s unavailable on %s (%d holders offline)", ob.kind, id_short(ob.o.id), mv.name, len(holders))
		}
		world_fail(w, "move: %s could not read %v %s with every original device offline", mv.name, ob.kind, id_short(ob.o.id))
	}
	world_note(w, "move: remote fetches %d, objects served %d, refused %d", w.remote.fetches, w.remote.served, w.remote.refused)
	for n in w.nodes {
		if n != mv {
			n.partitioned = false
		}
	}
	run_until(w, w.now + 120_000_000_000, true)
}

@(private = "file")
_move_strip :: proc(text: string) -> string {
	if !strings.has_prefix(text, "catalog ") {
		return text
	}
	i := strings.index_byte(text, '\n')
	return text[i + 1:] if i >= 0 else ""
}
