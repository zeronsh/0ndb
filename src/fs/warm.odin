package fs

import "core:os"
import "core:sync"
import "core:thread"
import "../odb"
import "../prim"

WARM_FILES :: ODIN_OS == .Windows
WARM_MIN :: 32
WARM_POLL_MS :: 10

@(private)
Warm_Job :: struct {
	vfs:     prim.Vfs,
	paths:   [dynamic]string,
	next:    int,
	left:    int,
	workers: [dynamic]^thread.Thread,
}

@(private)
warm_park :: proc(m: ^Mount) -> bool {
	if !WARM_FILES {
		return false
	}
	if m.warm != nil {
		return true
	}
	if m.warmed {
		m.warmed = false
		return false
	}
	if m.reg == nil || m.reg.loop == nil || m.vfs.procs != prim.os_vfs().procs {
		return false
	}
	paths := make([dynamic]string, m.allocator)
	warm_paths(m, &paths)
	if len(paths) < WARM_MIN {
		for p in paths {
			delete(p, m.allocator)
		}
		delete(paths)
		return false
	}
	warm_start(m, paths)
	return true
}

@(private)
warm_paths :: proc(m: ^Mount, out: ^[dynamic]string) {
	if !m.imported && m.has_git {
		warm_loose_objects(m, out)
		return
	}
	for k in prim.unordered(m.dirty) {
		if path_internal(k) {
			continue
		}
		abuf: prim.Path_Buf
		p, _ := clone_string(abs_path(m, k, abuf[:]), m.allocator)
		append(out, p)
	}
	if m.has_git && m.imported && git_index_stamp(m.vfs, m.git) != m.stamp {
		warm_index_changed(m, out)
	}
}

@(private)
warm_index_changed :: proc(m: ^Mount, out: ^[dynamic]string) {
	r: Index_Reader
	if index_open(&r, m.vfs, m.git.dir, m.git_format, context.temp_allocator) != .None {
		return
	}
	defer index_close(&r)
	seen := make(map[string]bool, context.temp_allocator)
	for p in out {
		seen[p] = true
	}
	base := m.git.common if len(m.git.common) > 0 else m.git.dir
	objects, _ := path_join(base, "objects", context.temp_allocator)
	for {
		e, ok, err := index_next(&r)
		if err != .None || !ok {
			return
		}
		if e.stage != 0 || e.mode & 0o170000 != 0o100000 {
			continue
		}
		mtime := i64(e.mtime_s) * 1_000_000_000 + i64(e.mtime_ns)
		if old, found, serr := shadow_get(&m.shadow, e.path); serr == .None && found && old.stat.mtime_ns == mtime && old.stat.size == i64(e.size) {
			continue
		}
		abuf: prim.Path_Buf
		abs := abs_path(m, e.path, abuf[:])
		if seen[abs] {
			continue
		}
		p, _ := clone_string(abs, m.allocator)
		append(out, p)
		hb: [odb.MAX_HEX]u8
		hex := odb.oid_to_string(e.oid, m.git_format, &hb)
		fan, _ := path_join(objects, hex[:2], context.temp_allocator)
		lp, _ := path_join(fan, hex[2:], m.allocator)
		append(out, lp)
	}
}

@(private)
warm_import :: proc(m: ^Mount) {
	if !WARM_FILES || !m.has_git || m.vfs.procs != prim.os_vfs().procs {
		return
	}
	paths := make([dynamic]string, m.allocator)
	warm_loose_objects(m, &paths)
	if len(paths) < WARM_MIN {
		for p in paths {
			delete(p, m.allocator)
		}
		delete(paths)
		return
	}
	job := Warm_Job{vfs = m.vfs, paths = paths}
	job.workers = make([dynamic]^thread.Thread, m.allocator)
	n := min(max(m.opts.threads, 1), max(os.get_processor_core_count(), 1), len(paths))
	sync.atomic_store(&job.left, n)
	for _ in 0 ..< n {
		w := thread.create_and_start_with_poly_data(&job, warm_worker)
		if w == nil {
			sync.atomic_sub(&job.left, 1)
			continue
		}
		append(&job.workers, w)
	}
	for w in job.workers {
		thread.join(w)
		thread.destroy(w)
	}
	delete(job.workers)
	for p in paths {
		delete(p, m.allocator)
	}
	delete(paths)
}

@(private)
warm_loose_objects :: proc(m: ^Mount, out: ^[dynamic]string) {
	base := m.git.common if len(m.git.common) > 0 else m.git.dir
	root, _ := path_join(base, "objects", context.temp_allocator)
	hex := "0123456789abcdef"
	for i in 0 ..< 256 {
		fan := [2]u8{hex[i >> 4], hex[i & 15]}
		dir, _ := path_join(root, string(fan[:]), context.temp_allocator)
		d: prim.Dir
		if prim.dir_open(m.vfs, &d, dir, context.temp_allocator) != .None {
			continue
		}
		for {
			ent, more, err := prim.dir_next(m.vfs, &d)
			if err != .None || !more {
				break
			}
			if len(ent.name) < 38 {
				continue
			}
			p, _ := path_join(dir, ent.name, m.allocator)
			append(out, p)
		}
		prim.dir_close(m.vfs, &d)
	}
}

@(private)
warm_start :: proc(m: ^Mount, paths: [dynamic]string) {
	job := new(Warm_Job, m.allocator)
	job.vfs = m.vfs
	job.paths = paths
	job.workers = make([dynamic]^thread.Thread, m.allocator)
	n := min(max(m.opts.threads, 1), max(os.get_processor_core_count(), 1), len(paths))
	sync.atomic_store(&job.left, n)
	m.warm = job
	for _ in 0 ..< n {
		w := thread.create_and_start_with_poly_data(job, warm_worker)
		if w == nil {
			sync.atomic_sub(&job.left, 1)
			continue
		}
		append(&job.workers, w)
	}
	m.warm_timer = prim.timer(m.reg.loop, WARM_POLL_MS, m, warm_tick)
}

@(private)
warm_worker :: proc(job: ^Warm_Job) {
	for {
		i := sync.atomic_add(&job.next, 1)
		if i >= len(job.paths) {
			break
		}
		fd, err := prim.open_file(job.vfs, job.paths[i], {})
		if err == .None {
			prim.close_file(job.vfs, fd)
		}
	}
	sync.atomic_sub(&job.left, 1)
}

@(private)
warm_tick :: proc(l: ^prim.Loop, data: rawptr) {
	m := (^Mount)(data)
	job := m.warm
	if job == nil {
		return
	}
	if sync.atomic_load(&job.left) > 0 {
		m.warm_timer = prim.timer(l, WARM_POLL_MS, m, warm_tick)
		return
	}
	warm_free(m)
	m.warmed = true
	mount_schedule(m, 0)
}

@(private)
warm_stop :: proc(m: ^Mount) {
	job := m.warm
	if job == nil {
		return
	}
	sync.atomic_store(&job.next, len(job.paths))
	if m.reg != nil && m.reg.loop != nil {
		prim.timer_cancel(m.reg.loop, m.warm_timer)
	}
	warm_free(m)
}

@(private)
warm_free :: proc(m: ^Mount) {
	job := m.warm
	for w in job.workers {
		thread.join(w)
		thread.destroy(w)
	}
	delete(job.workers)
	for p in job.paths {
		delete(p, m.allocator)
	}
	delete(job.paths)
	free(job, m.allocator)
	m.warm = nil
}
