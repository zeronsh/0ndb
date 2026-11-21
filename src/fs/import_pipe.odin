package fs

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "../crdt"
import "../odb"
import "../prim"

@(private)
Pipe_Shadow :: struct {
	path:  string,
	entry: Entry,
}

@(private)
Pipe_Tree :: struct {
	path: string,
	oid:  odb.Oid,
}

Pipe_Chunk :: struct {
	arena:    virtual.Arena,
	ops:      []crdt.Op_Run,
	seq0:     u64,
	n:        int,
	lamport:  u64,
	parents:  [dynamic]crdt.Op_Id,
	shadow:   [dynamic]Pipe_Shadow,
	trees:    [dynamic]Pipe_Tree,
	pack:     odb.Pack_Builder,
	has_pack: bool,
}

Pipe :: struct {
	m:       ^Mount,
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	slot:    ^Pipe_Chunk,
	slot_b:  ^Pipe_Chunk,
	quit:    bool,
	quit_b:  bool,
	err:     Error,
	worker:  ^thread.Thread,
	worker_b: ^thread.Thread,
	state:   sync.Mutex,
	maps:    sync.Mutex,
	shadow:  sync.Mutex,
	trees:   bool,
	inline:  bool,
	seq:     u64,
	lamport: u64,
	parents: [dynamic]crdt.Op_Id,
}

@(private)
chunk_new :: proc(st: ^Import_State) -> (c: ^Pipe_Chunk, err: Error) {
	c = new(Pipe_Chunk, runtime.heap_allocator())
	if c == nil {
		return nil, .No_Memory
	}
	if virtual.arena_init_growing(&c.arena, 1 << 20) != nil {
		free(c, runtime.heap_allocator())
		return nil, .No_Memory
	}
	a := virtual.arena_allocator(&c.arena)
	c.parents = make([dynamic]crdt.Op_Id, a)
	c.shadow = make([dynamic]Pipe_Shadow, a)
	c.trees = make([dynamic]Pipe_Tree, a)
	if st.use_pack {
		if odb.pack_begin(&c.pack, st.m.db) == .None {
			odb.pack_set_local(&c.pack, true)
			c.has_pack = true
		}
	}
	return c, .None
}

@(private)
chunk_free :: proc(c: ^Pipe_Chunk) {
	if c.has_pack {
		odb.pack_abort(&c.pack)
	}
	virtual.arena_destroy(&c.arena)
	free(c, runtime.heap_allocator())
}

@(private)
chunk_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	st := (^Import_State)(data)
	if st.cur == nil {
		return virtual.arena_allocator_proc(&st.chunk, mode, size, alignment, old_memory, old_size, loc)
	}
	return virtual.arena_allocator_proc(&st.cur.arena, mode, size, alignment, old_memory, old_size, loc)
}

@(private)
import_shadow :: proc(st: ^Import_State, path: string, e: Entry) -> Error {
	if st.cur == nil {
		return shadow_append(&st.m.shadow, path, e)
	}
	p, _ := clone_string(path, virtual.arena_allocator(&st.cur.arena))
	append(&st.cur.shadow, Pipe_Shadow{p, e})
	return .None
}

@(private)
frame_free :: proc(f: ^Dir_Frame) {
	heap := runtime.heap_allocator()
	for e in f.kids {
		delete(e.name, heap)
	}
	delete(f.kids)
	f.kids = nil
}

@(private)
frame_add :: proc(st: ^Import_State, name: string, oid: odb.Oid, mode: u32) {
	f := &st.stack[len(st.stack) - 1]
	if f.partial || st.pipe == nil || !st.pipe.trees {
		return
	}
	heap := runtime.heap_allocator()
	if f.kids == nil {
		f.kids = make([dynamic]odb.Tree_Entry, heap)
	}
	n, err := clone_string(name, heap)
	if err != nil || oid == {} {
		f.partial = true
		return
	}
	append(&f.kids, odb.Tree_Entry{name = n, oid = oid, mode = mode})
}

@(private)
import_dir_pop :: proc(st: ^Import_State) -> Error {
	f := pop(&st.stack)
	defer frame_free(&f)
	parent := &st.stack[len(st.stack) - 1]
	if f.partial || st.cur == nil || st.packp == nil || !st.cur.has_pack {
		parent.partial = true
		return .None
	}
	if len(f.kids) == 0 {
		return .None
	}
	odb.tree_sort(f.kids[:])
	oid, err := odb.pack_add_tree(st.packp, f.kids[:])
	if err != .None {
		parent.partial = true
		return .None
	}
	p, perr := clone_string(f.path, virtual.arena_allocator(&st.cur.arena))
	if perr != nil {
		return .No_Memory
	}
	append(&st.cur.trees, Pipe_Tree{p, oid})
	frame_add(st, path_name(f.path), oid, odb.MODE_TREE)
	return .None
}

@(private)
pipe_start :: proc(st: ^Import_State, p: ^Pipe) -> Error {
	m := st.m
	p^ = {
		m      = m,
		trees  = !m.has_git,
		inline = m.vfs.procs != prim.os_vfs().procs,
	}
	p.parents = make([dynamic]crdt.Op_Id, st.long)
	append(&p.parents, ..m.synced[:])
	p.seq = history_next_seq(m.history, m.actor)
	p.lamport = history_lamport_after(m.history, m.synced[:])
	history_actor_ix(m.history, m.actor)
	st.pipe = p
	m.shadow.map_lock = &p.maps
	m.history.kv.map_lock = &p.maps
	m.shadow.lock = &p.shadow
	c := chunk_new(st) or_return
	st.cur = c
	st.packp = &c.pack
	if p.inline {
		return .None
	}
	p.worker = thread.create_and_start_with_data(p, pipe_main, context)
	p.worker_b = thread.create_and_start_with_data(p, pipe_main_b, context)
	if p.worker == nil || p.worker_b == nil {
		chunk_free(c)
		st.cur = nil
		st.pipe = nil
		return .No_Memory
	}
	return .None
}

@(private)
pipe_builder :: proc(st: ^Import_State) {
	p := st.pipe
	b := &st.b
	b^ = {
		h     = st.m.history,
		actor = st.m.actor,
		aix   = b.aix,
		seq0  = p.seq,
		local = true,
	}
	b.ops = make([dynamic]crdt.Op_Run, context.temp_allocator)
	b.imports = make([dynamic]Import_File, context.temp_allocator)
}

@(private)
pipe_rotate :: proc(st: ^Import_State, final: bool) -> Error {
	p := st.pipe
	c := st.cur
	c.ops = st.b.ops[:]
	c.seq0 = st.b.seq0
	c.n = st.b.n
	c.lamport = p.lamport
	append(&c.parents, ..p.parents[:])
	if c.n > 0 {
		p.seq = c.seq0 + u64(c.n)
		p.lamport += u64(c.n)
		clear(&p.parents)
		append(&p.parents, crdt.Op_Id{st.b.actor, c.seq0 + u64(c.n) - 1})
	}
	err: Error
	if p.inline {
		err = pipe_stage_a(p, c)
		if err == .None {
			err = pipe_stage_b(p, c)
		}
		chunk_free(c)
		st.cur = nil
		st.packp = nil
		if err != .None {
			p.err = err
			return err
		}
		if final {
			return .None
		}
		n := chunk_new(st) or_return
		st.cur = n
		st.packp = &n.pack
		st.use_pack = n.has_pack
		st.files = 0
		return .None
	}
	sync.mutex_lock(&p.mutex)
	for p.slot != nil && p.err == .None {
		sync.cond_wait(&p.cond, &p.mutex)
	}
	err = p.err
	if err == .None {
		p.slot = c
		sync.cond_broadcast(&p.cond)
	}
	sync.mutex_unlock(&p.mutex)
	if err != .None {
		chunk_free(c)
		st.cur = nil
		return err
	}
	st.cur = nil
	st.packp = nil
	if final {
		return .None
	}
	n := chunk_new(st) or_return
	st.cur = n
	st.packp = &n.pack
	st.use_pack = n.has_pack
	st.files = 0
	return .None
}

@(private)
pipe_finish :: proc(st: ^Import_State) -> Error {
	p := st.pipe
	if p == nil {
		return .None
	}
	sync.mutex_lock(&p.mutex)
	p.quit = true
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mutex)
	if p.worker != nil {
		thread.join(p.worker)
		thread.destroy(p.worker)
	}
	sync.mutex_lock(&p.mutex)
	p.quit_b = true
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mutex)
	if p.worker_b != nil {
		thread.join(p.worker_b)
		thread.destroy(p.worker_b)
	}
	if p.slot != nil {
		chunk_free(p.slot)
		p.slot = nil
	}
	if p.slot_b != nil {
		chunk_free(p.slot_b)
		p.slot_b = nil
	}
	st.m.shadow.map_lock = nil
	st.m.history.kv.map_lock = nil
	st.m.shadow.lock = nil
	st.pipe = nil
	return p.err
}

@(private)
pipe_main :: proc(data: rawptr) {
	p := (^Pipe)(data)
	for {
		sync.mutex_lock(&p.mutex)
		for p.slot == nil && !p.quit {
			sync.cond_wait(&p.cond, &p.mutex)
		}
		c := p.slot
		sync.mutex_unlock(&p.mutex)
		if c == nil {
			return
		}
		err := pipe_stage_a(p, c)
		sync.mutex_lock(&p.mutex)
		if err == .None {
			for p.slot_b != nil && p.err == .None {
				sync.cond_wait(&p.cond, &p.mutex)
			}
			err = p.err
		}
		if err == .None {
			p.slot_b = c
		} else {
			chunk_free(c)
			if p.err == .None {
				p.err = err
			}
		}
		p.slot = nil
		sync.cond_broadcast(&p.cond)
		sync.mutex_unlock(&p.mutex)
		if err != .None {
			return
		}
	}
}

@(private)
pipe_main_b :: proc(data: rawptr) {
	p := (^Pipe)(data)
	for {
		sync.mutex_lock(&p.mutex)
		for p.slot_b == nil && !p.quit_b {
			sync.cond_wait(&p.cond, &p.mutex)
		}
		c := p.slot_b
		sync.mutex_unlock(&p.mutex)
		if c == nil {
			return
		}
		err := pipe_stage_b(p, c)
		chunk_free(c)
		sync.mutex_lock(&p.mutex)
		p.slot_b = nil
		if err != .None && p.err == .None {
			p.err = err
		}
		sync.cond_broadcast(&p.cond)
		sync.mutex_unlock(&p.mutex)
		if err != .None {
			return
		}
	}
}

@(private)
pipe_stage_a :: proc(p: ^Pipe, c: ^Pipe_Chunk) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 20) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	m := p.m
	h := m.history
	if c.has_pack {
		if odb.pack_count(&c.pack) > 0 {
			if _, perr := odb.pack_finish(&c.pack); perr != .None {
				return from_odb(perr)
			}
		} else {
			odb.pack_abort(&c.pack)
		}
		c.has_pack = false
	}
	if c.n > 0 {
		batch := crdt.Batch {
			actor   = m.actor,
			seq     = c.seq0,
			lamport = c.lamport,
			parents = c.parents[:],
			ops     = c.ops,
		}
		sync.mutex_lock(&p.state)
		append(&m.intents, Intent{m.actor, c.seq0, u64(c.n)})
		serr := save_mount_state(m)
		sync.mutex_unlock(&p.state)
		serr or_return
		history_commit_import(h, &batch) or_return
		sync.mutex_lock(&p.state)
		clear(&m.synced)
		append(&m.synced, crdt.Op_Id{m.actor, c.seq0 + u64(c.n) - 1})
		sync.mutex_unlock(&p.state)
	}
	history_trim(h)
	return .None
}

@(private)
pipe_stage_b :: proc(p: ^Pipe, c: ^Pipe_Chunk) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 20) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	m := p.m
	for s in c.shadow {
		shadow_append(&m.shadow, s.path, s.entry) or_return
	}
	shadow_persist(&m.shadow) or_return
	for t in c.trees {
		e, found := shadow_get(&m.shadow, t.path) or_return
		if found && e.kind == .Dir {
			e.oid = t.oid
			shadow_put(&m.shadow, t.path, e) or_return
		}
	}
	shadow_persist(&m.shadow) or_return
	if mount_deferred(m) {
		return .None
	}
	sync.mutex_lock(&p.state)
	defer sync.mutex_unlock(&p.state)
	for it, i in m.intents {
		if it.seq == c.seq0 && it.actor == m.actor {
			ordered_remove(&m.intents, i)
			break
		}
	}
	return save_mount_state(m)
}
