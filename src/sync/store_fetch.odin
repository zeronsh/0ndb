#+build linux, darwin, windows
package osync

import "base:runtime"

TIER_BLOCK :: 256 << 10
TIER_CACHE :: 4 << 20
TIER_TRIES :: 3

Object_Read :: struct {
	key:  string,
	off:  i64,
	n:    i64,
	done: proc(req: ^Object_Read, err: Error, bytes: []u8),
	ctx:  rawptr,
	host: rawptr,
}

object_read_done :: proc(req: ^Object_Read, err: Error, bytes: []u8) {
	req.done(req, err, bytes)
}

@(private)
Tier_Block_Key :: struct {
	space: Space_Id,
	seq:   u64,
	block: i64,
}

@(private)
Tier_Wait :: struct {
	cb:  proc(ctx: rawptr, err: Error),
	ctx: rawptr,
}

@(private)
Tier_Fetch :: struct {
	req:    Object_Read,
	t:      ^Tier_Store,
	alloc:  runtime.Allocator,
	bk:     Tier_Block_Key,
	name:   string,
	busy:   bool,
	inline: bool,
	err:    Error,
	data:   []u8,
	tries:  int,
	used:   u64,
	pins:   int,
	stale:  bool,
	waits:  [dynamic]Tier_Wait,
}

@(private)
Tier_Range :: struct {
	t:      ^Tier_Store,
	left:   int,
	err:    Error,
	held:   [dynamic]^Tier_Fetch,
	cb:     proc(ctx: rawptr, rg: ^Tier_Range, err: Error),
	ctx:    rawptr,
}

@(private)
_tier_block :: proc(t: ^Tier_Store, space: Space_Id, seq: u64, block: i64, wait: Tier_Wait = {}) -> (f: ^Tier_Fetch, ready: bool, err: Error) {
	bk := Tier_Block_Key{space, seq, block}
	t.tick += 1
	if cur, ok := t.blocks[bk]; ok {
		f = cur
		f.used = t.tick
		if f.busy {
			if wait.cb != nil {
				append(&f.waits, wait)
			}
			return f, false, .None
		}
		if f.stale && f.pins == 0 {
			f.stale = false
			f.tries = 0
			t.cache -= i64(len(f.data))
			delete(f.data, t.allocator)
			f.data = nil
		} else if f.err == .None {
			return f, true, .None
		}
		if f.tries >= TIER_TRIES {
			e := f.err
			_tier_block_free(t, f)
			return nil, false, e
		}
	} else {
		f = new(Tier_Fetch, t.allocator)
		f^ = {t = t, alloc = t.allocator, bk = bk, used = t.tick}
		f.name, _ = _clone_string(_tier_key(space, seq), t.allocator)
		f.waits = make([dynamic]Tier_Wait, t.allocator)
		t.blocks[bk] = f
	}
	if wait.cb != nil {
		append(&f.waits, wait)
	}
	f.busy = true
	f.err = .None
	f.tries += 1
	f.inline = true
	f.req = Object_Read{key = f.name, off = block * TIER_BLOCK, n = TIER_BLOCK, done = _tier_fetch_done, ctx = f}
	t.inflight += 1
	t.cfg.objects.read(t.cfg.objects.data, &f.req)
	f.inline = false
	if f.busy {
		return f, false, .None
	}
	if f.err != .None {
		return f, false, .None
	}
	return f, true, .None
}

@(private)
_tier_fetch_done :: proc(req: ^Object_Read, err: Error, bytes: []u8) {
	f := cast(^Tier_Fetch)req.ctx
	t := f.t
	if t == nil {
		delete(f.name, f.alloc)
		delete(f.waits)
		free(f, f.alloc)
		return
	}
	t.inflight -= 1
	f.busy = false
	f.err = err
	if err == .None {
		d, aerr := make([]u8, len(bytes), t.allocator)
		if aerr != nil {
			f.err = .No_Memory
		} else {
			copy(d, bytes)
			f.data = d
			t.cache += i64(len(d))
			t.gets += 1
			t.get_bytes += u64(len(d))
		}
	}
	f.pins += 1
	_tier_cache_trim(t)
	f.pins -= 1
	if f.inline {
		for w in f.waits {
			w.cb(w.ctx, f.err)
		}
		clear(&f.waits)
		return
	}
	waits := make([]Tier_Wait, len(f.waits), context.temp_allocator)
	copy(waits, f.waits[:])
	clear(&f.waits)
	for w in waits {
		w.cb(w.ctx, f.err)
	}
	if t.ready_cb != nil {
		t.ready_cb(t.ready_ctx)
	}
}

@(private)
_tier_block_free :: proc(t: ^Tier_Store, f: ^Tier_Fetch) {
	if cur, ok := t.blocks[f.bk]; ok && cur == f {
		delete_key(&t.blocks, f.bk)
	}
	t.cache -= i64(len(f.data))
	delete(f.data, t.allocator)
	delete(f.name, t.allocator)
	delete(f.waits)
	free(f, t.allocator)
}

@(private)
_tier_blocks_forget :: proc(t: ^Tier_Store, space: Space_Id, seq: u64) {
	gone := make([dynamic]^Tier_Fetch, context.temp_allocator)
	for bk, f in t.blocks {
		if bk.space != space || bk.seq != seq {
			continue
		}
		if f.busy || f.pins > 0 || len(f.waits) > 0 {
			f.stale = true
		} else {
			append(&gone, f)
		}
	}
	for f in gone {
		_tier_block_free(t, f)
	}
}

@(private)
_tier_cache_trim :: proc(t: ^Tier_Store) {
	for t.cache > TIER_CACHE {
		victim: ^Tier_Fetch
		for _, f in t.blocks {
			if f.busy || f.pins > 0 || len(f.waits) > 0 || f.err != .None {
				continue
			}
			if victim == nil || f.used < victim.used {
				victim = f
			}
		}
		if victim == nil {
			return
		}
		_tier_block_free(t, victim)
	}
}

@(private)
_tier_cache_drop :: proc(t: ^Tier_Store) {
	ids := make([dynamic]^Tier_Fetch, 0, len(t.blocks), context.temp_allocator)
	for _, f in t.blocks {
		append(&ids, f)
	}
	for f in ids {
		if f.busy {
			delete_key(&t.blocks, f.bk)
			clear(&f.waits)
			f.t = nil
			if t.cfg.objects.cancel != nil {
				t.cfg.objects.cancel(t.cfg.objects.data, &f.req)
			}
			continue
		}
		_tier_block_free(t, f)
	}
	for _, rw in t.rewrites {
		rw.t = nil
		if rw.busy && t.cfg.objects.cancel != nil {
			t.cfg.objects.cancel(t.cfg.objects.data, &rw.req)
		}
	}
	clear(&t.rewrites)
}

@(private)
_tier_rec_at :: proc "contextless" (c: ^Tier_Cold, pos: i64) -> (rec: Tier_Rec, ok: bool) {
	#reverse for r in c.recs {
		if r.at <= pos && pos < r.at + r.n {
			return r, true
		}
	}
	return {}, false
}

@(private)
_tier_block_get :: proc(t: ^Tier_Store, space: Space_Id, seq: u64, block: i64) -> (f: ^Tier_Fetch, ready: bool, err: Error) {
	for {
		f, ready, err = _tier_block(t, space, seq, block)
		if err != .None || ready || f.busy {
			return
		}
		if f.tries >= TIER_TRIES {
			e := f.err if f.err != .None else Error.Io
			_tier_block_free(t, f)
			return nil, false, e
		}
	}
}

@(private)
_tier_cold_read :: proc(sp: ^Tier_Space, c: ^Tier_Cold, at: i64, dst: []u8) -> Error {
	t := sp.t
	end := at + i64(len(dst))
	pending := false
	for pos := at; pos < end; {
		rec, ok := _tier_rec_at(c, pos)
		if !ok {
			return .Io
		}
		off := i64(rec.off) + pos - rec.at
		block := off / TIER_BLOCK
		n := min(min(end, rec.at + rec.n) - pos, (block + 1) * TIER_BLOCK - off)
		f, ready, err := _tier_block_get(t, sp.id, rec.seq, block)
		if err != .None {
			return err
		}
		if !ready {
			pending = true
		} else if !pending {
			lo := off - block * TIER_BLOCK
			if lo + n > i64(len(f.data)) {
				return .Io
			}
			copy(dst[pos - at:][:n], f.data[lo:][:n])
		}
		pos += n
	}
	if pending {
		return .Pending
	}
	t.cold_reads += 1
	t.cold_bytes += u64(len(dst))
	return .None
}

@(private)
_tier_cold_fetch :: proc(sp: ^Tier_Space, c: ^Tier_Cold, at, n: i64, cb: proc(ctx: rawptr, rg: ^Tier_Range, err: Error), ctx: rawptr) {
	t := sp.t
	rg := new(Tier_Range, t.allocator)
	rg^ = {t = t, cb = cb, ctx = ctx, left = 1}
	rg.held = make([dynamic]^Tier_Fetch, t.allocator)
	end := at + n
	for pos := at; pos < end && rg.err == .None; {
		rec, ok := _tier_rec_at(c, pos)
		if !ok {
			rg.err = .Io
			break
		}
		off := i64(rec.off) + pos - rec.at
		block := off / TIER_BLOCK
		f, ready, err := _tier_block_get(t, sp.id, rec.seq, block)
		if err != .None {
			rg.err = err
			break
		}
		f.pins += 1
		append(&rg.held, f)
		if !ready {
			append(&f.waits, Tier_Wait{_tier_range_part, rg})
			rg.left += 1
		}
		pos += min(min(end, rec.at + rec.n) - pos, (block + 1) * TIER_BLOCK - off)
	}
	_tier_range_part(rg, .None)
}

@(private)
_tier_range_part :: proc(ctx: rawptr, err: Error) {
	rg := cast(^Tier_Range)ctx
	if err != .None && rg.err == .None {
		rg.err = err
	}
	rg.left -= 1
	if rg.left > 0 {
		return
	}
	rg.cb(rg.ctx, rg, rg.err)
}

@(private)
_tier_range_end :: proc(rg: ^Tier_Range) {
	t := rg.t
	for f in rg.held {
		f.pins -= 1
	}
	delete(rg.held)
	free(rg, t.allocator)
	_tier_cache_trim(t)
}
