package fs

import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"

@(private)
Span_Pos :: struct {
	actor: prim.Id,
	seq:   u64,
	len:   int,
	pos:   int,
}

@(private)
span_index :: proc(spans: []crdt.Author_Span) -> []Span_Pos {
	out := make([]Span_Pos, len(spans), context.temp_allocator)
	pos := 0
	for s, i in spans {
		out[i] = Span_Pos{s.op.actor, s.op.seq, s.len, pos}
		pos += s.len
	}
	slice.sort_by(out, proc(a, b: Span_Pos) -> bool {
		if a.actor != b.actor {
			return crdt.id_less(a.actor, b.actor)
		}
		return a.seq < b.seq
	})
	return out
}

@(private)
span_find :: proc(idx: []Span_Pos, id: crdt.Op_Id) -> int {
	lo, hi := 0, len(idx)
	for lo < hi {
		mid := (lo + hi) / 2
		x := idx[mid]
		if crdt.id_less(x.actor, id.actor) || (x.actor == id.actor && x.seq + u64(x.len) <= id.seq) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(idx) && idx[lo].actor == id.actor && idx[lo].seq <= id.seq && id.seq < idx[lo].seq + u64(idx[lo].len) {
		return idx[lo].pos + int(id.seq - idx[lo].seq)
	}
	return -1
}

@(private)
Revert_Edit :: struct {
	pos:  int,
	del:  int,
	src:  crdt.Op_Id,
	ins:  int,
}

mount_revert :: proc(m: ^Mount, before: Version, after: Version) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	mount_sync(m) or_return
	h := m.history
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	al := make([dynamic]crdt.Lv, context.temp_allocator)
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, before, &bl) != .None || crdt.graph_version_lvs(&h.g, after, &al) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &cl) != .None {
		return .Not_Found
	}
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, bl[:], al[:], &only_b, &only_a)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	spans_touched(h, only_a[:], &touched) or_return
	if len(touched) == 0 {
		return .None
	}
	before_sync := make([]crdt.Op_Id, len(m.synced), context.temp_allocator)
	copy(before_sync, m.synced[:])
	for ino in sorted_inodes(touched) {
		_, e, had := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return
		if !had || e.ver == 0 {
			continue
		}
		ids, vok := shadow_version(&m.shadow, e)
		if !vok {
			return .Corrupt
		}
		for id in ids {
			lv, ok := crdt.graph_lv(&h.g, inode_op(h, id))
			if !ok {
				return .Corrupt
			}
			one := [1]crdt.Lv{lv}
			both := make([dynamic]crdt.Lv, context.temp_allocator)
			crdt.version_union(&h.g, cl[:], one[:], &both)
			clear(&cl)
			append(&cl, ..both[:])
		}
	}
	clear(&m.synced)
	append(&m.synced, ..crdt.graph_version_ids(&h.g, cl[:], context.temp_allocator))
	swapped := true
	defer if swapped {
		clear(&m.synced)
		append(&m.synced, ..before_sync)
	}
	bounds := make(map[prim.Id][2]u64, context.temp_allocator)
	in_scope :: proc(h: ^History, bounds: ^map[prim.Id][2]u64, bl, al: []crdt.Lv, id: crdt.Op_Id) -> bool {
		bd, ok := bounds[id.actor]
		if !ok {
			bd = {actor_bound(h, bl, id.actor), actor_bound(h, al, id.actor)}
			bounds[id.actor] = bd
		}
		return bd[0] <= id.seq && id.seq < bd[1]
	}
	snap_b := version_snapshot(h, bl[:]) or_return
	defer fstree.snapshot_destroy(&snap_b)
	snap_a := version_snapshot(h, al[:]) or_return
	defer fstree.snapshot_destroy(&snap_a)
	snap_c := version_snapshot(h, cl[:]) or_return
	defer fstree.snapshot_destroy(&snap_c)
	b: Builder
	builder_init(&b, h, m.actor)
	for ino in sorted_inodes(touched) {
		ib, okb, e1 := fstree.info(&snap_b, ino, context.temp_allocator)
		ia, oka, e2 := fstree.info(&snap_a, ino, context.temp_allocator)
		ic, okc, e3 := fstree.info(&snap_c, ino, context.temp_allocator)
		if e1 != nil || e2 != nil || e3 != nil {
			return .Corrupt
		}
		pb := okb && ib.present
		pa := oka && ia.present
		pc := okc && ic.present
		if pa && !pb {
			if pc {
				builder_tree(&b, fstree.Op_Remove{inode = ino})
			}
			continue
		}
		if pb && !pa {
			if !pc {
				builder_tree(&b, fstree.Op_Restore{inode = ino})
				if !okc || ic.parent != ib.parent || ic.name != ib.name {
					builder_tree(&b, fstree.Op_Move{inode = ino, parent = ib.parent, name = ib.name})
				}
			}
			continue
		}
		if !pb || !pc {
			continue
		}
		if (ia.parent != ib.parent || ia.name != ib.name) && ic.parent == ia.parent && ic.name == ia.name {
			builder_tree(&b, fstree.Op_Move{inode = ino, parent = ib.parent, name = ib.name})
		}
		if ia.flags != ib.flags && ic.flags == ia.flags {
			builder_tree(&b, fstree.Op_Set_Flags{inode = ino, mask = fstree.ALL_FLAGS, value = ib.flags})
		}
		if ib.kind == .Symlink && ia.target != ib.target && ic.target == ia.target {
			builder_tree(&b, fstree.Op_Set_Target{inode = ino, target = ib.target})
		}
		if ib.kind != .File {
			continue
		}
		if .Opaque in ib.flags {
			rb, hb := history_blob_at(h, ino, bl[:]) or_return
			ra, ha := history_blob_at(h, ino, al[:]) or_return
			rc, hc := history_blob_at(h, ino, cl[:]) or_return
			if hb && ha && hc && rb.oid != ra.oid && rc.oid == ra.oid {
				builder_content(&b, ino, odb.Oid(rb.oid), rb.size)
			}
			continue
		}
		_, sb := history_text_spans_at(h, ino, bl[:], context.temp_allocator) or_return
		_, sa := history_text_spans_at(h, ino, al[:], context.temp_allocator) or_return
		_, sc := history_text_spans_at(h, ino, cl[:], context.temp_allocator) or_return
		ia_idx := span_index(sa)
		ic_idx := span_index(sc)
		edits := make([dynamic]Revert_Edit, context.temp_allocator)
		pos := 0
		for s in sc {
			for k := 0; k < s.len; {
				id := crdt.Op_Id{s.op.actor, s.op.seq + u64(k)}
				if !in_scope(h, &bounds, bl[:], al[:], id) {
					k += 1
					continue
				}
				j := k + 1
				for j < s.len && in_scope(h, &bounds, bl[:], al[:], crdt.Op_Id{s.op.actor, s.op.seq + u64(j)}) {
					j += 1
				}
				append(&edits, Revert_Edit{pos = pos + k, del = j - k})
				k = j
			}
			pos += s.len
		}
		bpos := 0
		for s, si in sb {
			k := 0
			for k < s.len {
				id := crdt.Op_Id{s.op.actor, s.op.seq + u64(k)}
				if span_find(ia_idx, id) >= 0 || span_find(ic_idx, id) >= 0 {
					k += 1
					continue
				}
				j := k + 1
				for j < s.len {
					nid := crdt.Op_Id{s.op.actor, s.op.seq + u64(j)}
					if span_find(ia_idx, nid) >= 0 || span_find(ic_idx, nid) >= 0 {
						break
					}
					j += 1
				}
				at := 0
				found := false
				for q := bpos + k - 1; q >= 0 && !found; q -= 1 {
					lid := op_at(sb, q)
					if p := span_find(ic_idx, lid); p >= 0 {
						at = p + 1
						found = true
					}
				}
				append(&edits, Revert_Edit{pos = at, src = id, ins = j - k})
				k = j
			}
			bpos += s.len
			_ = si
		}
		slice.stable_sort_by(edits[:], proc(x, y: Revert_Edit) -> bool {return x.pos > y.pos})
		for ed in edits {
			if ed.del > 0 {
				builder_delete(&b, ino, ed.pos, ed.del)
			} else if ed.ins > 0 {
				builder_copy(&b, ino, ed.pos, ed.src, ed.ins)
			}
		}
		history_unload_files(h)
	}
	if b.n == 0 {
		return .None
	}
	if cerr := builder_commit(m, &b); cerr != .None && cerr != .Reloading {
		return cerr
	}
	swapped = false
	clear(&m.synced)
	append(&m.synced, ..before_sync)
	if merr := mount_materialize(m); merr != .Reloading {
		return merr
	}
	m.reload_owed = true
	mount_reload_retry(m)
	return .None
}

@(private)
op_at :: proc(spans: []crdt.Author_Span, pos: int) -> crdt.Op_Id {
	at := 0
	for s in spans {
		if pos < at + s.len {
			return crdt.Op_Id{s.op.actor, s.op.seq + u64(pos - at)}
		}
		at += s.len
	}
	return {}
}

@(private)
actor_bound :: proc(h: ^History, v: []crdt.Lv, actor: prim.Id) -> u64 {
	lo, hi := u64(0), crdt.graph_known(&h.g, actor)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{actor, mid})
		if ok && crdt.graph_contains(&h.g, v, lv) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}
