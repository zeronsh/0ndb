#+build linux, darwin, windows
package prim

import "base:runtime"

@(private)
_Drain :: struct {
	out:   ^[dynamic]u8,
	limit: int,
	open:  int,
	err:   Error,
	ws:    [2]Watch,
	fds:   [2]Fd,
}

@(private)
_drain_on :: proc(l: ^Loop, fd: Fd, ev: Events, data: rawptr) {
	d := (^_Drain)(data)
	k := 0 if fd == d.fds[0] else 1
	tmp: [16384]u8
	for {
		n, err := read(fd, tmp[:])
		if err == .Would_Block || err == .Interrupted {
			return
		}
		if err != .None || n == 0 {
			if err != .None && err != .Broken_Pipe {
				d.err = err
			}
			unwatch(l, d.ws[k])
			d.ws[k] = 0
			d.open -= 1
			return
		}
		if k == 0 && d.out != nil && len(d.out) < d.limit {
			append(d.out, ..tmp[:min(n, d.limit - len(d.out))])
		}
	}
}

child_drain :: proc(c: ^Child, out: ^[dynamic]u8, limit: int) -> Error {
	arena: runtime.Arena
	if runtime.arena_init(&arena, 64 * 1024, context.allocator) != nil {
		return .No_Memory
	}
	defer runtime.arena_destroy(&arena)
	context.temp_allocator = runtime.arena_allocator(&arena)
	l: Loop
	loop_init(&l, context.allocator) or_return
	defer loop_destroy(&l)
	d := _Drain {
		out   = out,
		limit = limit,
		fds   = {c.stdout, c.stderr},
	}
	for fd, k in d.fds {
		if fd == INVALID_FD {
			continue
		}
		w, err := watch(&l, fd, {.Read}, &d, _drain_on)
		if err != .None {
			for j in 0 ..< k {
				if d.ws[j] != 0 {
					unwatch(&l, d.ws[j])
				}
			}
			return err
		}
		d.ws[k] = w
		d.open += 1
	}
	for d.open > 0 {
		if err := loop_step(&l, true); err != .None {
			return err
		}
	}
	return d.err
}
