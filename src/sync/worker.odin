package osync

import "base:runtime"
import csync "core:sync"
import "core:thread"
import "../prim"

Job_Kind :: enum u8 {
	Stream_Sync,
	Object_Commit,
	Remove,
	Redact,
}

Job :: struct {
	vfs:     prim.Vfs,
	kind:    Job_Kind,
	fd:      prim.Fd,
	dir_fd:  bool,
	path:    string,
	final:   string,
	result:  Error,
	existed: bool,
	value:   i64,
	seq:     u64,
	from:    i64,
	to:      i64,
	target:  rawptr,
	done:    Storage_Done,
	ctx:     rawptr,
	next:    ^Job,
}

Worker :: struct {
	mutex:     csync.Mutex,
	cond:      csync.Cond,
	queue:     ^Job,
	tail:      ^Job,
	done:      ^Job,
	threads:   [dynamic]^thread.Thread,
	idle:      int,
	limit:     int,
	stop:      bool,
	notifier:  _Notifier,
	watch:     prim.Watch,
	loop:      ^prim.Loop,
	on_done:   proc(data: rawptr, job: ^Job),
	data:      rawptr,
	allocator: runtime.Allocator,
}

worker_init :: proc(w: ^Worker, l: ^prim.Loop, limit: int, on_done: proc(data: rawptr, job: ^Job), data: rawptr, allocator := context.allocator) -> Error {
	w^ = {
		loop      = l,
		limit     = max(limit, 0),
		on_done   = on_done,
		data      = data,
		allocator = allocator,
	}
	w.threads = make([dynamic]^thread.Thread, allocator)
	_notifier_open(&w.notifier) or_return
	wt, err := prim.watch(l, _notifier_fd(&w.notifier), {.Read}, w, _worker_ready)
	if err != .None {
		_notifier_close(&w.notifier)
		return _from_prim(err)
	}
	w.watch = wt
	return .None
}

worker_destroy :: proc(w: ^Worker) {
	csync.mutex_lock(&w.mutex)
	w.stop = true
	csync.cond_broadcast(&w.cond)
	csync.mutex_unlock(&w.mutex)
	for t in w.threads {
		thread.join(t)
		thread.destroy(t)
	}
	delete(w.threads)
	_worker_ready(w.loop, prim.INVALID_FD, {}, w)
	if w.watch != 0 {
		prim.unwatch(w.loop, w.watch)
	}
	_notifier_close(&w.notifier)
	w.threads = nil
}

worker_submit :: proc(w: ^Worker, job: ^Job) -> Error {
	job.next = nil
	if w.limit == 0 {
		_job_run(job)
		w.on_done(w.data, job)
		return .None
	}
	csync.mutex_lock(&w.mutex)
	if w.tail == nil {
		w.queue = job
	} else {
		w.tail.next = job
	}
	w.tail = job
	spawn := w.idle == 0 && len(w.threads) < w.limit
	csync.cond_signal(&w.cond)
	csync.mutex_unlock(&w.mutex)
	if spawn {
		t := thread.create_and_start_with_data(w, _worker_main, init_context = runtime.default_context())
		if t != nil {
			if _, aerr := append(&w.threads, t); aerr != nil {
				thread.join(t)
				thread.destroy(t)
			}
		} else if len(w.threads) == 0 {
			return .No_Memory
		}
	}
	return .None
}

@(private)
_worker_main :: proc(data: rawptr) {
	w := cast(^Worker)data
	for {
		csync.mutex_lock(&w.mutex)
		for w.queue == nil && !w.stop {
			w.idle += 1
			csync.cond_wait(&w.cond, &w.mutex)
			w.idle -= 1
		}
		if w.queue == nil && w.stop {
			csync.mutex_unlock(&w.mutex)
			return
		}
		job := w.queue
		w.queue = job.next
		if w.queue == nil {
			w.tail = nil
		}
		csync.mutex_unlock(&w.mutex)
		_job_run(job)
		csync.mutex_lock(&w.mutex)
		job.next = w.done
		w.done = job
		csync.mutex_unlock(&w.mutex)
		_notifier_signal(&w.notifier)
	}
}

@(private)
_worker_ready :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	w := cast(^Worker)data
	_notifier_drain(&w.notifier)
	csync.mutex_lock(&w.mutex)
	list := w.done
	w.done = nil
	csync.mutex_unlock(&w.mutex)
	rev: ^Job
	for list != nil {
		nxt := list.next
		list.next = rev
		rev = list
		list = nxt
	}
	for rev != nil {
		nxt := rev.next
		rev.next = nil
		w.on_done(w.data, rev)
		rev = nxt
	}
}

@(private)
_job_run :: proc(job: ^Job) {
	path := job.path
	final := job.final
	switch job.kind {
	case .Stream_Sync:
		job.result = _from_prim(prim.datasync(job.vfs, job.fd))
		if job.result == .None && job.dir_fd {
			job.result = _from_prim(prim.sync_dir(job.vfs, prim.dir_name(path)))
		}
	case .Object_Commit:
		job.result = _from_prim(prim.datasync(job.vfs, job.fd))
		prim.close_file(job.vfs, job.fd)
		job.fd = prim.INVALID_FD
		if job.result == .None {
			dir := prim.dir_name(final)
			if merr := prim.mkdir(job.vfs, dir, 0o700); merr == .None {
				job.result = _from_prim(prim.sync_dir(job.vfs, prim.dir_name(dir)))
			} else if merr != .Exists {
				job.result = _from_prim(merr)
			}
		}
		if job.result == .None {
			if prim.exists(job.vfs, final) {
				job.existed = true
			} else {
				job.result = _from_prim(prim.rename(job.vfs, path, final))
			}
		}
		prim.remove(job.vfs, path)
		if job.result == .None && !job.existed {
			job.result = _from_prim(prim.sync_dir(job.vfs, prim.dir_name(final)))
		}
	case .Redact:
		job.result = slot_write(job.vfs, job.fd, Slot{seq = job.seq, value = job.value, start = job.value})
		if job.result == .None {
			job.result = _from_prim(prim.datasync(job.vfs, job.fd))
		}
		if job.result == .None {
			job.result = _redact_records(job.vfs, job.fd, job.from, job.to)
		}
		if job.result == .None {
			job.result = _from_prim(prim.datasync(job.vfs, job.fd))
		}
	case .Remove:
		job.result = _from_prim(prim.remove(job.vfs, path))
		if job.result == .Not_Found {
			job.result = .None
		}
		if job.result == .None {
			job.result = _from_prim(prim.sync_dir(job.vfs, prim.dir_name(path)))
		}
	}
}
