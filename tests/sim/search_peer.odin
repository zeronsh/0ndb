package sim

import "core:strings"
import eng "../../src/engine"
import "../../src/prim"
import "../../src/search"
import osync "../../src/sync"

Peer_Query :: struct {
	w:     ^World,
	n:     ^Node,
	op:    ^M_Op,
	id:    u64,
	done:  bool,
	hits:  [dynamic]search.Hit,
	state: [dynamic]eng.Search_Source,
}

op_search_peer :: proc(w: ^World, n: ^Node) {
	m := &w.model
	si := -1
	cands := make([dynamic]^M_Op, context.temp_allocator)
	for op in m.ops {
		if op.kind != .Send || len(op.token) < 3 || op.obj < 0 || !op_maybe(op) {
			continue
		}
		if !obj_reader(m, op.obj, n.idx) {
			continue
		}
		append(&cands, op)
	}
	if len(cands) == 0 {
		return
	}
	t := cands[rng_int(&w.rng, len(cands))]
	space := m.objs[t.obj].o.space
	si = space_index(m, space)
	if si < 0 || !space_member(&m.spaces[si], n.idx) {
		return
	}
	op := new_op(m, .Search_Peer, n, t.obj)
	op.target = t.idx
	q := new(Peer_Query, w.allocator)
	q.w = w
	q.n = n
	q.op = op
	q.hits = make([dynamic]search.Hit, w.allocator)
	q.state = make([dynamic]eng.Search_Source, w.allocator)
	context = instance_context(&n.inst)
	req := search.Request{limit = 8, now = eng.hlc_now(&n.e)}
	id, err := eng.search_everywhere(&n.e, space, t.token[1:len(t.token) - 1], req, .Everywhere, eng.Done{data = q, call = _peer_done})
	if err != .None {
		op_result(op, n, err)
		return
	}
	q.id = id
}

@(private = "file")
_peer_done :: proc(data: rawptr, e: ^eng.Engine, res: ^eng.Result, err: eng.Error) {
	q := (^Peer_Query)(data)
	w := q.w
	m := &w.model
	r := eng.search_result(e, q.id)
	if r != nil {
		for h in r.hits {
			x := h
			x.ref = transmute([]u8)strings.clone(string(h.ref), w.allocator)
			x.snippet = strings.clone(h.snippet, w.allocator)
			x.matches = nil
			x.fields = nil
			append(&q.hits, x)
			oi := _obj_of(m, h.object)
			if oi >= 0 && !obj_reader(m, oi, q.n.idx) {
				world_fail(w, "search: peer query on %s returned object %s it cannot read", q.n.name, id_short(h.object))
			}
		}
		for s in r.sources {
			append(&q.state, s)
		}
	}
	q.done = true
	if q.op != nil {
		op_done(q.op, 0, .None)
	}
}

@(private = "file")
_obj_of :: proc(m: ^Model, id: prim.Id) -> int {
	for &ob, i in m.objs {
		if ob.o.id == id {
			return i
		}
	}
	return -1
}

check_peer_redaction :: proc(w: ^World, all_secrets: []string, all_owners: []int) {
	secrets := make([dynamic]string, w.allocator)
	owners := make([dynamic]int, w.allocator)
	for s, i in all_secrets {
		if len(s) >= 3 {
			append(&secrets, strings.clone(s, w.allocator))
			append(&owners, all_owners[i])
		}
	}
	if len(secrets) == 0 {
		return
	}
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		m := &w.model
		for &sp in m.spaces {
			if !space_member(&sp, n.idx) {
				continue
			}
			for at := 0; at < len(secrets); at += 8 {
				end := min(at + 8, len(secrets))
				b := strings.builder_make(w.allocator)
				for s, k in secrets[at:end] {
					if k > 0 {
						strings.write_string(&b, " OR ")
					}
					strings.write_string(&b, s[1:len(s) - 1])
				}
				q := new(Peer_Query, w.allocator)
				q.w = w
				q.n = n
				q.hits = make([dynamic]search.Hit, w.allocator)
				q.state = make([dynamic]eng.Search_Source, w.allocator)
				{
					context = instance_context(&n.inst)
					req := search.Request{limit = 64, now = eng.hlc_now(&n.e)}
					id, err := eng.search_everywhere(&n.e, sp.id, strings.to_string(b), req, .Everywhere, eng.Done{data = q, call = _peer_done})
					node_after(n)
					if err != .None {
						continue
					}
					q.id = id
				}
				for round := 0; round < 64 && !q.done; round += 1 {
					run_until(w, w.now + 1_000_000_000, true)
				}
				if !q.done {
					world_fail(w, "search: peer query on %s never completed", n.name)
					return
				}
				for h in q.hits {
					for s, k in secrets[at:end] {
						tok := s[1:len(s) - 1]
						if strings.contains(h.snippet, tok) && _token_exact(h.snippet, tok) {
							redaction_finding(w, n, owners[at + k], "redaction: peer search on %s returns %s in a snippet (object %s): %q", n.name, s, id_short(h.object), h.snippet)
						}
					}
				}
			}
		}
	}
}

@(private = "file")
_token_exact :: proc(snippet: string, tok: string) -> bool {
	rest := snippet
	for {
		i := strings.index(rest, tok)
		if i < 0 {
			return false
		}
		after := i + len(tok)
		if after >= len(rest) || rest[after] < '0' || rest[after] > '9' {
			return true
		}
		rest = rest[i + 1:]
	}
}

check_index_rebuild :: proc(w: ^World) {
	target: ^Node
	for n in w.nodes {
		if n.alive && n.e_open && n.idx % 2 == 0 {
			target = n
			break
		}
	}
	if target == nil {
		return
	}
	n := target
	spaces := make([dynamic]prim.Id, w.allocator)
	defer delete(spaces)
	for &sp in w.model.spaces {
		if space_member(&sp, n.idx) {
			append(&spaces, sp.id)
		}
	}
	wiped := 0
	{
		context = instance_context(&n.inst)
		vfs := eng.vfs(&n.e)
		names := make([dynamic]string, context.temp_allocator)
		d: prim.Dir
		if prim.dir_open(vfs, &d, search_dir(n), context.temp_allocator) == .None {
			for {
				ent, ok, err := prim.dir_next(vfs, &d)
				if !ok || err != .None {
					break
				}
				append(&names, strings.concatenate({search_dir(n), "/", ent.name}, context.temp_allocator))
			}
			prim.dir_close(vfs, &d)
		}
		for p in names {
			if prim.remove(vfs, p) == .None {
				wiped += 1
			}
		}
	}
	live_close(n)
	{
		context = instance_context(&n.inst)
		if err := eng.close(&n.e); err != .None {
			world_note(w, "%s close before index wipe: %v", n.name, err)
		}
	}
	n.e_open = false
	osync.file_keyring_close(&n.keyring)
	n.key_open = false
	node_kill(n)
	world_note(w, "%s search index wiped (%d files) for a rebuild from content", n.name, wiped)
	schedule(w, Sim_Event{at = w.now + 200_000_000, kind = .Restart, node = n.idx})
	for round := 0; round < 16 && !(n.alive && n.e_open); round += 1 {
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !n.alive || !n.e_open {
		world_fail(w, "search: %s did not restart after its index was wiped", n.name)
		return
	}
	started := w.now
	rebuilt := false
	for round := 0; round < 32; round += 1 {
		run_until(w, w.now + 2_000_000_000, false)
		if !n.alive || !n.e_open {
			return
		}
		context = instance_context(&n.inst)
		busy := eng.search_indexing(&n.e)
		node_after(n)
		if !busy && round >= 2 {
			rebuilt = true
			break
		}
	}
	world_note(w, "%s search index rebuilt from content in %d ms", n.name, (w.now - started) / 1_000_000)
	if !rebuilt {
		world_fail(w, "search: rebuild of the wiped index on %s never finished", n.name)
	}
	run_until(w, w.now + 30_000_000_000, true)
}
