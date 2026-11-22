#+build linux, darwin, windows
package osync

import "base:runtime"
import "../prim"

Dir_Object_Store :: struct {
	vfs:       prim.Vfs,
	root:      string,
	puts:      u64,
	bytes:     u64,
	gets:      u64,
	get_bytes: u64,
	worker:    Worker,
	allocator: runtime.Allocator,
}

dir_object_store_init :: proc(d: ^Dir_Object_Store, l: ^prim.Loop, vfs: prim.Vfs, root: string, threads := 1, allocator := context.allocator) -> Error {
	d^ = {vfs = vfs, allocator = allocator}
	d.root = _clone_string(root, allocator) or_return
	if err := worker_init(&d.worker, l, threads, _dir_put_done, d, allocator); err != .None {
		delete(d.root, allocator)
		d.root = ""
		return err
	}
	return .None
}

dir_object_store_destroy :: proc(d: ^Dir_Object_Store) {
	if d.worker.loop == nil {
		return
	}
	worker_destroy(&d.worker)
	d.worker = {}
	delete(d.root, d.allocator)
	d.root = ""
}

dir_object_store :: proc(d: ^Dir_Object_Store) -> Object_Store {
	return Object_Store{data = d, put = _dir_put, read = _dir_read, drain = _dir_drain}
}

@(private)
_dir_read :: proc(data: rawptr, req: ^Object_Read) {
	d := cast(^Dir_Object_Store)data
	path, _ := prim.path_join(context.temp_allocator, d.root, req.key)
	fd, oerr := prim.open_file(d.vfs, path)
	if oerr != .None {
		object_read_done(req, _from_prim(oerr), nil)
		return
	}
	defer prim.close_file(d.vfs, fd)
	n := req.n
	if n < 0 {
		size, serr := prim.file_size(d.vfs, fd)
		if serr != .None {
			object_read_done(req, _from_prim(serr), nil)
			return
		}
		n = max(size - req.off, 0)
	}
	buf := make([]u8, int(n), context.temp_allocator)
	got, rerr := prim.read_at(d.vfs, fd, buf, req.off)
	d.gets += 1
	d.get_bytes += u64(max(got, 0))
	object_read_done(req, _from_prim(rerr), buf[:max(got, 0)])
}

@(private)
_dir_put :: proc(data: rawptr, key: string, bytes: []u8, done: Storage_Done, ctx: rawptr) {
	d := cast(^Dir_Object_Store)data
	path, perr := prim.path_join(d.allocator, d.root, key)
	if perr != .None {
		done(ctx, _from_prim(perr), 0)
		return
	}
	job := new(Job, d.allocator)
	buf := make([]u8, len(bytes), d.allocator)
	if job == nil || (buf == nil && len(bytes) > 0) {
		delete(path, d.allocator)
		delete(buf, d.allocator)
		free(job, d.allocator)
		done(ctx, .No_Memory, 0)
		return
	}
	copy(buf, bytes)
	job^ = Job{vfs = d.vfs, kind = .Object_Put, path = path, data = buf, done = done, ctx = ctx}
	if err := worker_submit(&d.worker, job); err != .None {
		_dir_job_free(d, job)
		done(ctx, err, 0)
	}
}

@(private)
_dir_put_done :: proc(data: rawptr, job: ^Job) {
	d := cast(^Dir_Object_Store)data
	result := job.result
	n := i64(len(job.data)) if result == .None else 0
	done, ctx := job.done, job.ctx
	if result == .None {
		d.puts += 1
		d.bytes += u64(n)
	}
	_dir_job_free(d, job)
	done(ctx, result, n)
}

@(private)
_dir_job_free :: proc(d: ^Dir_Object_Store, job: ^Job) {
	delete(job.path, d.allocator)
	delete(job.data, d.allocator)
	free(job, d.allocator)
}

@(private)
_dir_drain :: proc(data: rawptr) {
	worker_drain(&(cast(^Dir_Object_Store)data).worker)
}
