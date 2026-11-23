package sim

import "base:runtime"
import osync "../../src/sync"

@(private = "file")
Held_Commit :: struct {
	id:     osync.Stream_Id,
	at:     i64,
	done:   osync.Storage_Done,
	ctx:    rawptr,
	result: osync.Error,
	value:  i64,
	ready:  bool,
}

@(private = "file")
Held_Writer :: struct {
	s:  rawptr,
	at: i64,
}

@(private = "file")
Commit_Hold :: struct {
	w:       ^World,
	open:    proc(data: rawptr, ns: rawptr, id: osync.Stream_Id, create: bool) -> (s: rawptr, length: i64, err: osync.Error),
	close:   proc(data: rawptr, s: rawptr),
	begin:   proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: osync.Error),
	commit:  proc(data: rawptr, w: rawptr, done: osync.Storage_Done, ctx: rawptr),
	abort:   proc(data: rawptr, w: rawptr),
	ids:     map[rawptr]osync.Stream_Id,
	writers: map[rawptr]Held_Writer,
	held:    [dynamic]^Held_Commit,
}

@(private = "file")
@(thread_local)
_ch: ^Commit_Hold

@(init)
_commit_hold_init :: proc "contextless" () {
	register_world(71, proc(w: ^World) {
		if _ch != nil {
			for h in _ch.held {
				free(h, runtime.heap_allocator())
			}
			delete(_ch.ids)
			delete(_ch.writers)
			delete(_ch.held)
			free(_ch, runtime.heap_allocator())
		}
		_ch = nil
	})
}

commit_hold_wrap :: proc(w: ^World, st: ^osync.Relay_Storage) {
	if _ch == nil {
		_ch = new(Commit_Hold, runtime.heap_allocator())
		_ch.ids = make(map[rawptr]osync.Stream_Id, runtime.heap_allocator())
		_ch.writers = make(map[rawptr]Held_Writer, runtime.heap_allocator())
		_ch.held = make([dynamic]^Held_Commit, runtime.heap_allocator())
	}
	_ch.w = w
	clear(&_ch.ids)
	clear(&_ch.writers)
	for h in _ch.held {
		free(h, runtime.heap_allocator())
	}
	clear(&_ch.held)
	_ch.open, _ch.close, _ch.begin, _ch.commit, _ch.abort = st.stream_open, st.stream_close, st.append_begin, st.append_commit, st.append_abort
	st.stream_open = proc(data: rawptr, ns: rawptr, id: osync.Stream_Id, create: bool) -> (s: rawptr, length: i64, err: osync.Error) {
		s, length, err = _ch.open(data, ns, id, create)
		if err == .None && s != nil {
			_ch.ids[s] = id
		}
		return
	}
	st.stream_close = proc(data: rawptr, s: rawptr) {
		delete_key(&_ch.ids, s)
		_ch.close(data, s)
	}
	st.append_begin = proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (wr: rawptr, err: osync.Error) {
		wr, err = _ch.begin(data, s, at, total)
		if err == .None && wr != nil {
			_ch.writers[wr] = Held_Writer{s, at}
		}
		return
	}
	st.append_abort = proc(data: rawptr, wr: rawptr) {
		delete_key(&_ch.writers, wr)
		_ch.abort(data, wr)
	}
	st.append_commit = proc(data: rawptr, wr: rawptr, done: osync.Storage_Done, ctx: rawptr) {
		hw, sok := _ch.writers[wr]
		delete_key(&_ch.writers, wr)
		id, iok := _ch.ids[hw.s]
		if !sok || !iok || !relay_commit_held(_ch.w, id, hw.at) {
			_ch.commit(data, wr, done, ctx)
			return
		}
		h := new(Held_Commit, runtime.heap_allocator())
		h^ = {id = id, at = hw.at, done = done, ctx = ctx}
		append(&_ch.held, h)
		_ch.commit(data, wr, proc(c: rawptr, result: osync.Error, value: i64) {
			h := cast(^Held_Commit)c
			h.result, h.value, h.ready = result, value, true
		}, h)
	}
}

commit_hold_flush :: proc(w: ^World) {
	if _ch == nil || _ch.w != w {
		return
	}
	for i := 0; i < len(_ch.held); {
		h := _ch.held[i]
		if !h.ready || relay_commit_held(w, h.id, h.at) {
			i += 1
			continue
		}
		ordered_remove(&_ch.held, i)
		h.done(h.ctx, h.result, h.value)
		free(h, runtime.heap_allocator())
	}
}
