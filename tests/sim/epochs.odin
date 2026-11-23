package sim

import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

@(init)
_epochs_init :: proc "contextless" () {
	register_final_check(122, check_epochs)
}

@(private = "file")
Epoch_View :: struct {
	node:    ^Node,
	records: int,
	tag:     osync.Epoch_Tag,
	has:     bool,
}

check_epochs :: proc(w: ^World) {
	views := make(map[prim.Id][dynamic]Epoch_View, context.temp_allocator)
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		notes, err := eng.verify_epochs(&n.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "epochs: %s verify failed: %v", n.name, err)
		}
		for x in notes {
			world_fail(w, "%s %s", n.name, x)
		}
		for info in eng.space_list(&n.e, context.temp_allocator) {
			if !info.open || info.mode != .End_To_End {
				continue
			}
			st, serr := eng.space_members_status(&n.e, info.id)
			if serr != .None {
				continue
			}
			tag, has := eng.space_epoch_current(&n.e, info.id)
			if _, ok := views[info.id]; !ok {
				views[info.id] = make([dynamic]Epoch_View, w.ctx.temp_allocator)
			}
			append(&views[info.id], Epoch_View{n, st.records, tag, has})
		}
		node_after(n)
	}
	context = w.ctx
	current := make(map[prim.Id]osync.Epoch_Tag, context.temp_allocator)
	for space in prim.sorted_keys(views) {
		if space not_in views {
			continue
		}
		list := views[space]
		most := 0
		for v in list {
			most = max(most, v.records)
		}
		first := -1
		for v, i in list {
			if v.records != most || !v.has {
				continue
			}
			if first < 0 {
				first = i
				current[space] = v.tag
				continue
			}
			if v.tag != list[first].tag {
				world_fail(w, "epochs: space %s: %s and %s hold the same %d membership records but resolve different current epochs %x and %x", id_short(space), list[first].node.name, v.node.name, most, list[first].tag, v.tag)
			}
		}
	}
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		for g in eng.grant_picks(&n.e, context.temp_allocator) {
			cur, ok := current[g.space]
			if !ok {
				continue
			}
			held := false
			for t in g.tags {
				held ||= t == cur
			}
			if held && g.pick != cur {
				world_fail(w, "epochs: %s picks epoch %x for its grant of %s in space %s, the roster's current is %x", n.name, g.pick, id_short(g.object), id_short(g.space), cur)
			}
		}
		node_after(n)
	}
}
