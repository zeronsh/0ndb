package sim

import "core:debug/trace"
import "core:fmt"
import "core:slice"
import "core:strings"

@(private = "file")
SITE_DEPTH :: 6

@(private = "file")
SITE_SKIP :: 2

@(private = "file")
SITE_TOP :: 30

@(private = "file")
Site_Key :: [SITE_DEPTH]rawptr

@(private = "file")
Site_Count :: struct {
	reads: u64,
	bytes: u64,
}

@(private = "file")
Read_Sites :: struct {
	on:    bool,
	sites: map[Site_Key]Site_Count,
	paths: map[string]Site_Count,
	reads: u64,
	bytes: u64,
}

@(private = "file", thread_local)
_rs: Read_Sites

@(init)
_read_sites_init :: proc "contextless" () {
	register_world(5, _rs_init, _rs_destroy)
	register_disk_read(0, _rs_read)
}

@(private = "file")
_rs_init :: proc(w: ^World) {
	_rs.on = env_u64("SIM_READ_SITES", 0) != 0
	if !_rs.on {
		return
	}
	_rs.sites = make(map[Site_Key]Site_Count, w.allocator)
	_rs.paths = make(map[string]Site_Count, w.allocator)
	_rs.reads = 0
	_rs.bytes = 0
}

@(private = "file")
_rs_read :: proc(d: ^Disk, path: string, off: i64, n: int) {
	if !_rs.on {
		return
	}
	key: Site_Key
	bt := trace.capture(SITE_SKIP)
	for i in 0 ..< min(SITE_DEPTH, bt.len) {
		key[i] = rawptr(bt.trace[i])
	}
	if s, ok := &_rs.sites[key]; ok {
		s.reads += 1
		s.bytes += u64(n)
	} else {
		_rs.sites[key] = Site_Count{1, u64(n)}
	}
	label := _rs_label(d, path)
	p, found := &_rs.paths[label]
	if !found {
		_rs.paths[strings.clone(label, _rs.paths.allocator)] = {}
		p = &_rs.paths[label]
	}
	p.reads += 1
	p.bytes += u64(n)
	_rs.reads += 1
	_rs.bytes += u64(n)
}

@(private = "file")
_rs_label :: proc(d: ^Disk, path: string) -> string {
	base := path
	if i := strings.last_index_byte(path, '/'); i >= 0 && len(path) - i > 12 {
		base = path[:i + 1]
	}
	return fmt.tprintf("%s:%s", d.name, base)
}

@(private = "file")
_rs_destroy :: proc(w: ^World) {
	if !_rs.on {
		return
	}
	fmt.eprintfln("read sites: %d reads, %d bytes, %d sites", _rs.reads, _rs.bytes, len(_rs.sites))
	Row :: struct {
		key: Site_Key,
		c:   Site_Count,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	for k, c in _rs.sites {
		append(&rows, Row{k, c})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		return a.c.reads > b.c.reads
	})
	for r, i in rows {
		if i >= SITE_TOP {
			break
		}
		frames := make([dynamic]trace.Capture_Entry, context.temp_allocator)
		for f in r.key {
			if f != nil {
				append(&frames, trace.Capture_Entry(f))
			}
		}
		locs, err := trace.resolve(frames[:], context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		if err == .None {
			for l, j in locs {
				file := l.file_path
				if k := strings.last_index_byte(file, '/'); k >= 0 {
					file = file[k + 1:]
				}
				fmt.sbprintf(&b, "%s%s %s:%d", "" if j == 0 else " < ", l.procedure, file, l.line)
			}
		}
		fmt.eprintfln("read site %2d: %7d reads %10d bytes  %s", i, r.c.reads, r.c.bytes, strings.to_string(b))
	}
	prows := make([dynamic]struct {
			p: string,
			c: Site_Count,
		}, context.temp_allocator)
	for p, c in _rs.paths {
		append(&prows, struct {
				p: string,
				c: Site_Count,
			}{p, c})
	}
	slice.sort_by(prows[:], proc(a, b: struct {
				p: string,
				c: Site_Count,
			}) -> bool {
		return a.c.reads > b.c.reads
	})
	for r, i in prows {
		if i >= 15 {
			break
		}
		fmt.eprintfln("read path %2d: %7d reads %10d bytes  %s", i, r.c.reads, r.c.bytes, r.p)
	}
	for k in _rs.paths {
		delete(k, _rs.paths.allocator)
	}
	delete(_rs.sites)
	delete(_rs.paths)
	_rs = {}
}
