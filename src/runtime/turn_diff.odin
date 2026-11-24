package rt

import "base:runtime"
import "core:slice"
import "core:strings"
import "../convo"
import "../crdt"
import eng "../engine"
import "../fs"
import "../fstree"
import "../obj"
import "../prim"
import "../textdiff"

Turn_Blame :: struct {
	line_lo: int,
	line_hi: int,
	actor:   prim.Id,
	owner:   prim.Id,
	device:  prim.Id,
}

Turn_File :: struct {
	mount:   string,
	path:    string,
	from:    string,
	status:  string,
	binary:  bool,
	added:   int,
	removed: int,
	patch:   string,
	clipped: bool,
	blame:   []Turn_Blame,
}

Turn :: struct {
	msg:        Rid,
	actor:      prim.Id,
	stamp:      prim.Hlc,
	ended:      bool,
	files:      []Turn_File,
	more_files: int,
	added:      int,
	removed:    int,
}

Turn_Opts :: struct {
	patch:     bool,
	blame:     bool,
	max_chars: int,
	max_files: int,
}

@(private)
Turn_Mount :: struct {
	name:   string,
	tree:   prim.Id,
	before: []crdt.Op_Id,
	after:  []crdt.Op_Id,
}

@(private)
Turn_Span :: struct {
	msg:    Rid,
	actor:  prim.Id,
	stamp:  prim.Hlc,
	ended:  bool,
	mounts: [dynamic]Turn_Mount,
}

turn_diff :: proc(r: ^Runtime, o: Object, msg: Rid, opts: Turn_Opts, allocator := context.allocator, ready: eng.Ready = {}) -> (t: Turn, err: eng.Error) {
	context = eng.context_for(r.e)
	m := eng.convo_message(r.e, o, convo.Position{msg = msg}, context.temp_allocator, ready) or_return
	s, ok := _turn_span(r, o, m, ready) or_return
	if !ok {
		return Turn{msg = msg}, .None
	}
	return _turn_compute(r, o, &s, opts, allocator), .None
}

turn_history :: proc(r: ^Runtime, o: Object, from: convo.Position, limit: int, max_files: int, allocator := context.allocator, ready: eng.Ready = {}) -> (turns: []Turn, next: convo.Position, more: bool, err: eng.Error) {
	context = eng.context_for(r.e)
	out := make([dynamic]Turn, allocator)
	opts := Turn_Opts{max_files = max_files}
	pos := from
	want := limit if limit > 0 else 50
	scanned := 0
	for {
		p := eng.convo_page(r.e, o, pos, 64, context.temp_allocator, ready, .Older) or_return
		msgs := p.messages
		slice.sort_by(msgs, proc(a, b: convo.Message) -> bool {
			return a.depth > b.depth
		})
		for m in msgs {
			if len(out) >= want {
				next = convo.Position{msg = m.id}
				return out[:], next, true, .None
			}
			scanned += 1
			s, ok := _turn_span(r, o, m, ready) or_return
			if ok {
				append(&out, _turn_compute(r, o, &s, opts, allocator))
			}
		}
		if !p.more || len(msgs) == 0 || scanned >= 64 * want {
			return out[:], p.next, p.more, .None
		}
		pos = p.next
	}
}

@(private)
_turn_span :: proc(r: ^Runtime, o: Object, m: convo.Message, ready: eng.Ready) -> (s: Turn_Span, ok: bool, err: eng.Error) {
	if m.role != .Assistant {
		return {}, false, .None
	}
	s = Turn_Span{msg = m.id, mounts = make([dynamic]Turn_Mount, context.temp_allocator)}
	if !obj.rid_none(m.scope) {
		sc := eng.convo_turn_scope(r.e, o, m.scope, context.temp_allocator, ready) or_return
		s.actor = sc.actor
		s.stamp = sc.stamp if sc.stamp != 0 else m.hlc
		s.ended = true
		_turn_merge(&s, sc.before, true)
		_turn_merge(&s, sc.after, false)
	} else if run := run_find(r, o); run != nil && run.ws != nil && run.reply == m.id {
		s.actor = run.ws.actor
		s.stamp = m.hlc
		for mb in run.ws.members {
			if mb.m == nil || prim.id_is_zero(mb.run_line) {
				continue
			}
			end, found, lerr := fs.history_line(mb.m.history, line_name(mb.run_line), context.temp_allocator)
			if lerr != .None || !found {
				end = fs.mount_synced(mb.m)
			}
			append(&s.mounts, Turn_Mount{name = mb.name, tree = mb.tree, before = mb.start, after = slice.clone(end, context.temp_allocator)})
		}
	} else {
		return {}, false, .None
	}
	missing := false
	for x in s.mounts {
		missing ||= prim.id_is_zero(x.tree)
	}
	if missing {
		trees := make(map[string]prim.Id, context.temp_allocator)
		if fl, ferr := eng.convo_files_at(r.e, o, m.id, context.temp_allocator); ferr == .None {
			for f in fl {
				trees[f.mount] = f.tree
			}
		}
		if ms, merr := eng.convo_mounts(r.e, o, context.temp_allocator); merr == .None {
			for x in ms {
				if x.name not_in trees {
					trees[x.name] = x.tree
				}
			}
		}
		for &x in s.mounts {
			if prim.id_is_zero(x.tree) {
				x.tree = trees[x.name] or_else {}
			}
		}
	}
	return s, true, .None
}

@(private)
_turn_merge :: proc(s: ^Turn_Span, blob: []u8, start: bool) {
	rd := prim.reader(blob)
	n := prim.read_uvarint(&rd)
	for _ in 0 ..< n {
		name := prim.read_str(&rd)
		vb := prim.read_bytes(&rd)
		if !prim.reader_ok(&rd) {
			return
		}
		v, _, _, ok := version_decode(vb)
		if !ok {
			continue
		}
		at := -1
		for m, i in s.mounts {
			if m.name == name {
				at = i
			}
		}
		if at < 0 {
			at = len(s.mounts)
			append(&s.mounts, Turn_Mount{name = strings.clone(name, context.temp_allocator)})
		}
		m := &s.mounts[at]
		if start && m.before == nil {
			m.before = v
		} else if !start {
			m.after = v
		}
	}
}

@(private)
_turn_compute :: proc(r: ^Runtime, o: Object, s: ^Turn_Span, opts: Turn_Opts, allocator: runtime.Allocator) -> Turn {
	t := Turn{msg = s.msg, actor = s.actor, stamp = s.stamp, ended = s.ended}
	files := make([dynamic]Turn_File, allocator)
	budget := opts.max_chars if opts.max_chars > 0 else 200_000
	slice.sort_by(s.mounts[:], proc(a, b: Turn_Mount) -> bool {
		return a.name < b.name
	})
	for m in s.mounts {
		if prim.id_is_zero(m.tree) || len(m.after) == 0 {
			continue
		}
		tree := Object{o.space, m.tree}
		h, herr := eng.tree_history(r.e, tree)
		if herr != .None {
			continue
		}
		_turn_mount(h, m, opts, &budget, &t, &files, allocator)
		eng.tree_release(r.e, tree)
	}
	if opts.max_files > 0 && len(files) > opts.max_files {
		t.more_files = len(files) - opts.max_files
		resize(&files, opts.max_files)
	}
	t.files = files[:]
	return t
}

@(private)
_turn_mount :: proc(h: ^fs.History, m: Turn_Mount, opts: Turn_Opts, budget: ^int, t: ^Turn, files: ^[dynamic]Turn_File, allocator: runtime.Allocator) {
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	al := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.before, &bl) != .None || crdt.graph_version_lvs(&h.g, m.after, &al) != .None {
		return
	}
	gone := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	came := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, bl[:], al[:], &gone, &came)
	cand := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	structural := false
	_fd_touched(h, gone[:], &cand, &structural)
	_fd_touched(h, came[:], &cand, &structural)
	if len(cand) == 0 {
		return
	}
	sa, e1 := fs.version_snapshot(h, bl[:])
	if e1 != .None {
		return
	}
	defer fstree.snapshot_destroy(&sa)
	sb, e2 := fs.version_snapshot(h, al[:])
	if e2 != .None {
		return
	}
	defer fstree.snapshot_destroy(&sb)
	for ino in _sorted_inodes(cand) {
		ia, oka, _ := fstree.info(&sa, ino, context.temp_allocator)
		ib, okb, _ := fstree.info(&sb, ino, context.temp_allocator)
		pa := oka && ia.present && ia.kind != .Dir
		pb := okb && ib.present && ib.kind != .Dir
		if !pa && !pb {
			continue
		}
		path_a, path_b: string
		if pa {
			path_a, _, _ = fstree.path(&sa, ino, context.temp_allocator)
		}
		if pb {
			path_b, _, _ = fstree.path(&sb, ino, context.temp_allocator)
		}
		binary := (pa && ia.kind == .File && .Opaque in ia.flags) || (pb && ib.kind == .File && .Opaque in ib.flags)
		a, b: []u8
		spans: []crdt.Author_Span
		same := false
		if binary {
			ra, ha, _ := fs.history_blob_at(h, ino, bl[:])
			rb, hb, _ := fs.history_blob_at(h, ino, al[:])
			same = pa && pb && ha == hb && ra.oid == rb.oid
		} else {
			if pa {
				a = _turn_content(h, ino, ia, m.before, bl[:], false, nil)
			}
			if pb {
				b = _turn_content(h, ino, ib, m.after, al[:], opts.blame, &spans)
			}
			same = pa && pb && string(a) == string(b)
		}
		f := Turn_File{mount = strings.clone(m.name, allocator), binary = binary}
		switch {
		case !pa:
			f.status = "added"
			f.path = path_b
		case !pb:
			f.status = "removed"
			f.path = path_a
		case path_a != path_b:
			f.status = "moved"
			f.path = path_b
			f.from = strings.clone(path_a, allocator)
		case !same:
			f.status = "modified"
			f.path = path_b
		case:
			continue
		}
		f.path = strings.clone(f.path, allocator)
		if !binary {
			txt, st, derr := textdiff.unified(a, b, textdiff.DEFAULT_UNIFIED, context.temp_allocator)
			if derr == nil {
				f.added = st.added
				f.removed = st.removed
				if opts.patch {
					ha := strings.concatenate({"a/", m.name, "/", path_a}, context.temp_allocator) if pa else "/dev/null"
					hb := strings.concatenate({"b/", m.name, "/", path_b}, context.temp_allocator) if pb else "/dev/null"
					full := strings.concatenate({"--- ", ha, "\n+++ ", hb, "\n", string(txt)}, context.temp_allocator)
					clip, cut := utf8_clip(full, max(budget^, 0))
					f.patch = strings.clone(clip, allocator)
					f.clipped = cut
					budget^ -= len(clip)
				}
			}
			if opts.blame && pb {
				f.blame = _turn_blame(h, b, spans, allocator)
			}
		}
		t.added += f.added
		t.removed += f.removed
		append(files, f)
	}
}

@(private)
_turn_content :: proc(h: ^fs.History, ino: fstree.Inode_Id, inf: fstree.Info, v: []crdt.Op_Id, lvs: []crdt.Lv, blame: bool, spans: ^[]crdt.Author_Span) -> []u8 {
	if inf.kind == .Symlink {
		return transmute([]u8)inf.target
	}
	if blame {
		data, sp, err := fs.history_text_spans_at(h, ino, lvs, context.temp_allocator)
		if err == .None {
			spans^ = sp
			return data
		}
		return nil
	}
	data, _ := fs.history_text_at(h, ino, v, context.temp_allocator)
	return data
}

@(private)
_turn_blame :: proc(h: ^fs.History, data: []u8, spans: []crdt.Author_Span, allocator: runtime.Allocator) -> []Turn_Blame {
	Tally :: struct {
		actor: prim.Id,
		n:     int,
	}
	out := make([dynamic]Turn_Blame, allocator)
	tally := make([dynamic]Tally, context.temp_allocator)
	line := 1
	finish :: proc(h: ^fs.History, out: ^[dynamic]Turn_Blame, tally: ^[dynamic]Tally, line: ^int) {
		best := 0
		for x, i in tally {
			if x.n > tally[best].n {
				best = i
			}
		}
		who := tally[best].actor
		if n := len(out); n > 0 && out[n - 1].actor == who && out[n - 1].line_hi == line^ {
			out[n - 1].line_hi = line^ + 1
		} else {
			owner, _ := fs.history_owner_of(h, who)
			append(out, Turn_Blame{line_lo = line^, line_hi = line^ + 1, actor = who, owner = owner, device = fs.history_present_actor(h, who)})
		}
		line^ += 1
		clear(tally)
	}
	add :: proc(tally: ^[dynamic]Tally, actor: prim.Id, n: int) {
		for &x in tally {
			if x.actor == actor {
				x.n += n
				return
			}
		}
		append(tally, Tally{actor, n})
	}
	at := 0
	for s in spans {
		lo := min(at, len(data))
		hi := min(at + s.len, len(data))
		at = hi
		p := lo
		for p < hi {
			q := p
			for q < hi && data[q] != '\n' {
				q += 1
			}
			nl := q < hi
			end := q + 1 if nl else q
			add(&tally, s.id.actor, end - p)
			p = end
			if nl {
				finish(h, &out, &tally, &line)
			}
		}
	}
	if len(tally) > 0 {
		finish(h, &out, &tally, &line)
	}
	return out[:]
}
