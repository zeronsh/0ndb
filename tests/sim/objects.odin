package sim

import "../../src/prim"
import osync "../../src/sync"

Sim_Objects :: struct {
	inner:   osync.Object_Store,
	loop:    ^prim.Loop,
	rng:     Rng,
	slow_ms: i64,
	fail:    u64,
	reads:   u64,
	failed:  u64,
	pending: int,
}

@(private = "file")
Sim_Obj_Req :: struct {
	so:   ^Sim_Objects,
	req:  ^osync.Object_Read,
	err:  osync.Error,
	data: []u8,
}

sim_objects :: proc(so: ^Sim_Objects) -> osync.Object_Store {
	return osync.Object_Store{data = so, put = _so_put, read = _so_read}
}

@(private = "file")
_so_put :: proc(data: rawptr, key: string, bytes: []u8, done: osync.Storage_Done, ctx: rawptr) {
	so := (^Sim_Objects)(data)
	so.inner.put(so.inner.data, key, bytes, done, ctx)
}

@(private = "file")
_so_read :: proc(data: rawptr, req: ^osync.Object_Read) {
	so := (^Sim_Objects)(data)
	q := new(Sim_Obj_Req)
	q.so, q.req = so, req
	inner := osync.Object_Read{key = req.key, off = req.off, n = req.n, ctx = q, done = proc(r: ^osync.Object_Read, err: osync.Error, bytes: []u8) {
		q := (^Sim_Obj_Req)(r.ctx)
		q.err = err
		if err == .None {
			q.data = make([]u8, len(bytes))
			copy(q.data, bytes)
		}
	}}
	so.inner.read(so.inner.data, &inner)
	so.reads += 1
	if q.err == .None && so.fail > 0 && rng_chance(&so.rng, so.fail, 100) {
		q.err = .Io
		so.failed += 1
	}
	so.pending += 1
	prim.timer(so.loop, rng_range(&so.rng, 0, so.slow_ms), q, proc(l: ^prim.Loop, data: rawptr) {
		q := (^Sim_Obj_Req)(data)
		q.so.pending -= 1
		osync.object_read_done(q.req, q.err, q.data)
		delete(q.data)
		free(q)
	})
}
