package fs

import "core:crypto/blake2b"
import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fshist"
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

scope_pseudo :: proc(conversation: prim.Id, mount: prim.Id, line: string) -> (pseudo: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb agent actor"
	blake2b.update(&ctx, transmute([]u8)tag)
	c, mid := conversation, mount
	blake2b.update(&ctx, c[:])
	blake2b.update(&ctx, mid[:])
	blake2b.update(&ctx, transmute([]u8)line)
	blake2b.final(&ctx, pseudo[:])
	return
}

mount_revert_pseudo :: proc(mount: prim.Id, line: string, owner: prim.Id) -> (pseudo: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb mount revert"
	blake2b.update(&ctx, transmute([]u8)tag)
	mid := mount
	blake2b.update(&ctx, mid[:])
	blake2b.update(&ctx, transmute([]u8)line)
	oid := owner
	blake2b.update(&ctx, oid[:])
	blake2b.final(&ctx, pseudo[:])
	return
}

Pending_Revert :: struct {
	before: [dynamic]crdt.Op_Id,
	after:  [dynamic]crdt.Op_Id,
	owner:  prim.Id,
}

mount_revert :: proc(m: ^Mount, before: Version, after: Version, owner: prim.Id) -> Error {
	if err := mount_sync(m); err == .Deferred {
		p := Pending_Revert{before = make([dynamic]crdt.Op_Id, m.allocator), after = make([dynamic]crdt.Op_Id, m.allocator), owner = owner}
		append(&p.before, ..before)
		append(&p.after, ..after)
		append(&m.reverts, p)
		mount_schedule(m, max(m.opts.settle_ms, 1))
		return .None
	} else if err != .None {
		return err
	}
	return _mount_revert(m, before, after, owner)
}

@(private)
mount_reverts_run :: proc(m: ^Mount) -> Error {
	for len(m.reverts) > 0 {
		p := m.reverts[0]
		ordered_remove(&m.reverts, 0)
		err := _mount_revert(m, p.before[:], p.after[:], p.owner)
		delete(p.before)
		delete(p.after)
		err or_return
	}
	return .None
}

@(private)
_mount_revert :: proc(m: ^Mount, before: Version, after: Version, owner: prim.Id) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	h := m.history
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	al := make([dynamic]crdt.Lv, context.temp_allocator)
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, before, &bl) != .None || crdt.graph_version_lvs(&h.g, after, &al) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &cl) != .None {
		return .Not_Found
	}
	pseudo := mount_revert_pseudo(m.id, m.line, owner)
	ractor := fshist.ingestion_actor(h.self, pseudo)
	if known := crdt.graph_known(&h.g, ractor); known > 0 {
		if prev, pok := crdt.graph_lv(&h.g, crdt.Op_Id{ractor, known - 1}); pok {
			one := [1]crdt.Lv{prev}
			both := make([dynamic]crdt.Lv, context.temp_allocator)
			crdt.version_union(&h.g, cl[:], one[:], &both)
			clear(&cl)
			append(&cl, ..both[:])
		}
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
	builder_init(&b, h, ractor)
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
				builder_copy_root(&b, ino, ed.pos, ed.src, ed.ins)
			}
		}
		history_unload_files(h)
	}
	if b.n == 0 {
		return .None
	}
	history_register_owned_actor(h, ractor, pseudo, owner) or_return
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

@(private)
event_actor :: proc(m: ^Mount, base: prim.Id, parents: []crdt.Op_Id, digest: [32]u8) -> (actor: prim.Id, err: Error) {
	h := m.history
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb event actor"
	blake2b.update(&ctx, transmute([]u8)tag)
	b := base
	blake2b.update(&ctx, b[:])
	n: [8]u8
	prim.put_u64le(n[:], u64(len(m.line)))
	blake2b.update(&ctx, n[:])
	blake2b.update(&ctx, transmute([]u8)m.line)
	sorted := slice.clone(parents, context.temp_allocator)
	slice.sort_by(sorted, proc(x, y: crdt.Op_Id) -> bool {
		if x.actor != y.actor {
			return crdt.id_less(x.actor, y.actor)
		}
		return x.seq < y.seq
	})
	prim.put_u64le(n[:], u64(len(sorted)))
	blake2b.update(&ctx, n[:])
	for id in sorted {
		a := id.actor
		blake2b.update(&ctx, a[:])
		prim.put_u64le(n[:], id.seq)
		blake2b.update(&ctx, n[:])
	}
	d := digest
	blake2b.update(&ctx, d[:])
	pseudo: prim.Id
	blake2b.final(&ctx, pseudo[:])
	actor = fshist.ingestion_actor(h.self, pseudo)
	if _, known := history_actor_owner(h, actor); !known {
		history_register_line_actor(h, actor, pseudo, base) or_return
		m.event_actors += 1
	}
	return actor, .None
}

@(private)
scope_line_actor :: proc(m: ^Mount, actor: prim.Id) -> prim.Id {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb scope line"
	blake2b.update(&ctx, transmute([]u8)tag)
	a := actor
	blake2b.update(&ctx, a[:])
	blake2b.update(&ctx, transmute([]u8)m.line)
	pseudo: prim.Id
	blake2b.final(&ctx, pseudo[:])
	la := fshist.ingestion_actor(m.history.self, pseudo)
	if _, known := history_actor_owner(m.history, la); !known {
		history_register_line_actor(m.history, la, pseudo, actor)
	}
	return la
}
