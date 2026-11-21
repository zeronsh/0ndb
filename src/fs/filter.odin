package fs

import "base:runtime"
import "core:io"
import "core:strings"
import "core:thread"
import "../prim"

Filter_Cmd :: enum u8 {
	Clean,
	Smudge,
}

Filter_Input :: struct {
	data: []u8,
	fd:   prim.Fd,
	vfs:  prim.Vfs,
}

@(private)
Filter_Proc :: struct {
	driver:  ^Filter_Driver,
	child:   prim.Child,
	caps:    bit_set[Filter_Cmd],
	broken:  bool,
	started: bool,
}

@(private)
PKT_MAX :: 65516

@(private)
filter_find :: proc(m: ^Mount, name: string) -> ^Filter_Driver {
	for &d in m.ignore.git.filters {
		if d.name == name {
			if len(d.clean) == 0 && len(d.smudge) == 0 && len(d.process) == 0 {
				return nil
			}
			return &d
		}
	}
	return nil
}

@(private)
sq_quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '\'')
	for c in transmute([]u8)s {
		if c == '\'' || c == '!' {
			strings.write_string(b, "'\\")
			strings.write_byte(b, c)
			strings.write_byte(b, '\'')
		} else {
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '\'')
}

@(private)
filter_argv :: proc(cmd: string, rel: string, allocator: runtime.Allocator) -> []string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(cmd) {
		if cmd[i] == '%' && i + 1 < len(cmd) && cmd[i + 1] == 'f' {
			sq_quote(&b, rel)
			i += 2
			continue
		}
		strings.write_byte(&b, cmd[i])
		i += 1
	}
	full := strings.to_string(b)
	meta := false
	for c in transmute([]u8)cmd {
		switch c {
		case '|', '&', ';', '<', '>', '(', ')', '$', '`', '\\', '"', '*', '?', '[', '#', '~', '=', '%', '\n':
			meta = true
		}
	}
	if !meta {
		out := make([dynamic]string, allocator)
		cur := strings.builder_make(allocator)
		quoted := false
		has := false
		for c in transmute([]u8)full {
			switch {
			case c == '\'':
				quoted = !quoted
				has = true
			case !quoted && (c == ' ' || c == '\t'):
				if has {
					append(&out, strings.clone(strings.to_string(cur), allocator))
					strings.builder_reset(&cur)
					has = false
				}
			case:
				strings.write_byte(&cur, c)
				has = true
			}
		}
		if has {
			append(&out, strings.clone(strings.to_string(cur), allocator))
		}
		if len(out) > 0 {
			out[0] = filter_program(out[0], allocator)
			return out[:]
		}
	}
	out := make([]string, 3, allocator)
	out[0] = shell_path(allocator)
	out[1] = "-c"
	out[2] = full
	return out
}

@(private)
filter_program :: proc(name: string, allocator: runtime.Allocator) -> string {
	when ODIN_OS == .Windows {
		for c in transmute([]u8)name {
			if c == '/' || c == '\\' || c == ':' {
				return name
			}
		}
		buf: [prim.PATH_MAX]u8
		prefix, ok := git_prefix(buf[:])
		if !ok {
			return name
		}
		has_ext := strings.last_index_byte(name, '.') > 0
		for dir in ([]string{"mingw64\\bin", "usr\\bin", "cmd"}) {
			for ext in ([]string{"", ".exe"}) {
				if len(ext) > 0 && has_ext {
					continue
				}
				pbuf: prim.Path_Buf
				d, dok := path_join_buf(pbuf[:], prefix, dir)
				if !dok {
					continue
				}
				fbuf: prim.Path_Buf
				f, fok := path_join_buf(fbuf[:], d, strings.concatenate({name, ext}, context.temp_allocator))
				if fok && prim.exists(prim.os_vfs(), f) {
					if st, serr := prim.lstat(prim.os_vfs(), f); serr == .None && st.kind == .File {
						return strings.clone(f, allocator)
					}
				}
			}
		}
		return name
	} else {
		return name
	}
}

@(private)
filter_env :: proc(allocator: runtime.Allocator) -> []string {
	when ODIN_OS == .Windows {
		buf: [prim.PATH_MAX]u8
		prefix, ok := git_prefix(buf[:])
		if !ok {
			return nil
		}
		env := prim.environ(allocator)
		out := make([dynamic]string, 0, len(env) + 1, allocator)
		extra := strings.concatenate({prefix, "\\mingw64\\bin;", prefix, "\\usr\\bin;", prefix, "\\cmd"}, allocator)
		found := false
		for kv in env {
			if len(kv) > 5 && ascii_fold_eq(kv[:5], "PATH=") {
				append(&out, strings.concatenate({kv[:5], extra, ";", kv[5:]}, allocator))
				found = true
			} else {
				append(&out, kv)
			}
		}
		if !found {
			append(&out, strings.concatenate({"PATH=", extra}, allocator))
		}
		return out[:]
	} else {
		return nil
	}
}

@(private)
shell_path :: proc(allocator: runtime.Allocator) -> string {
	when ODIN_OS == .Windows {
		buf: [prim.PATH_MAX]u8
		if prefix, ok := git_prefix(buf[:]); ok {
			for rel in ([]string{"usr/bin/sh.exe", "bin/sh.exe"}) {
				pbuf: prim.Path_Buf
				if p, pok := path_join_buf(pbuf[:], prefix, rel); pok && prim.exists(prim.os_vfs(), p) {
					return strings.clone(p, allocator)
				}
			}
		}
		return "sh.exe"
	} else {
		return "/bin/sh"
	}
}

@(private)
feed_input :: proc(in_: Filter_Input, emit: proc(data: rawptr, chunk: []u8) -> bool, data: rawptr) -> bool {
	if in_.fd == prim.INVALID_FD {
		off := 0
		for off < len(in_.data) {
			n := min(len(in_.data) - off, PKT_MAX)
			if !emit(data, in_.data[off:off + n]) {
				return false
			}
			off += n
		}
		return true
	}
	buf: [PKT_MAX]u8
	off: i64
	for {
		n, err := prim.read_at(in_.vfs, in_.fd, buf[:], off)
		if err != .None {
			return false
		}
		if n <= 0 {
			return true
		}
		if !emit(data, buf[:n]) {
			return false
		}
		off += i64(n)
	}
}

@(private)
pkt_write :: proc(fd: prim.Fd, payload: []u8) -> bool {
	hdr: [4]u8
	n := len(payload) + 4
	hex := "0123456789abcdef"
	hdr[0] = hex[(n >> 12) & 15]
	hdr[1] = hex[(n >> 8) & 15]
	hdr[2] = hex[(n >> 4) & 15]
	hdr[3] = hex[n & 15]
	return child_write_all(fd, hdr[:]) && child_write_all(fd, payload)
}

@(private)
pkt_text :: proc(fd: prim.Fd, line: string) -> bool {
	return pkt_write(fd, transmute([]u8)line)
}

@(private)
pkt_flush :: proc(fd: prim.Fd) -> bool {
	f := [4]u8{'0', '0', '0', '0'}
	return child_write_all(fd, f[:])
}

@(private)
read_full :: proc(fd: prim.Fd, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		n, err := child_read(fd, buf[off:])
		if err != .None || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

@(private)
pkt_read :: proc(fd: prim.Fd, buf: ^[PKT_MAX + 4]u8) -> (payload: []u8, flush: bool, ok: bool) {
	hdr: [4]u8
	if !read_full(fd, hdr[:]) {
		return nil, false, false
	}
	n := 0
	for c in hdr {
		v: int
		switch c {
		case '0' ..= '9':
			v = int(c - '0')
		case 'a' ..= 'f':
			v = int(c - 'a' + 10)
		case 'A' ..= 'F':
			v = int(c - 'A' + 10)
		case:
			return nil, false, false
		}
		n = n * 16 + v
	}
	if n == 0 {
		return nil, true, true
	}
	if n < 4 || n - 4 > PKT_MAX {
		return nil, false, false
	}
	if !read_full(fd, buf[:n - 4]) {
		return nil, false, false
	}
	return buf[:n - 4], false, true
}

@(private)
pkt_read_status :: proc(fd: prim.Fd) -> (status: string, ok: bool) {
	buf: [PKT_MAX + 4]u8
	for {
		p, flush, rok := pkt_read(fd, &buf)
		if !rok {
			return "", false
		}
		if flush {
			return status, true
		}
		line := strings.trim_right(string(p), "\n")
		if strings.has_prefix(line, "status=") {
			status = strings.clone(line[7:], context.temp_allocator)
		}
	}
}

@(private)
filter_proc_start :: proc(m: ^Mount, fp: ^Filter_Proc) -> bool {
	fp.started = true
	argv := filter_argv(fp.driver.process, "", context.temp_allocator)
	child, err := prim.spawn(argv, m.root, filter_env(context.temp_allocator), false, {.Stdin, .Stdout})
	if err != .None {
		fp.broken = true
		return false
	}
	fp.child = child
	in_ := child.stdin
	out := child.stdout
	if !pkt_text(in_, "git-filter-client\n") || !pkt_text(in_, "version=2\n") || !pkt_flush(in_) {
		filter_proc_kill(fp)
		return false
	}
	buf: [PKT_MAX + 4]u8
	server, version := false, false
	for {
		p, flush, ok := pkt_read(out, &buf)
		if !ok {
			filter_proc_kill(fp)
			return false
		}
		if flush {
			break
		}
		line := strings.trim_right(string(p), "\n")
		server ||= line == "git-filter-server"
		version ||= line == "version=2"
	}
	if !server || !version {
		filter_proc_kill(fp)
		return false
	}
	if !pkt_text(in_, "capability=clean\n") || !pkt_text(in_, "capability=smudge\n") || !pkt_flush(in_) {
		filter_proc_kill(fp)
		return false
	}
	for {
		p, flush, ok := pkt_read(out, &buf)
		if !ok {
			filter_proc_kill(fp)
			return false
		}
		if flush {
			break
		}
		line := strings.trim_right(string(p), "\n")
		if line == "capability=clean" {
			fp.caps += {.Clean}
		} else if line == "capability=smudge" {
			fp.caps += {.Smudge}
		}
	}
	return true
}

@(private)
filter_proc_kill :: proc(fp: ^Filter_Proc) {
	fp.broken = true
	if fp.child.pid != 0 {
		prim.child_kill(&fp.child)
		prim.child_close(&fp.child)
		prim.reap(fp.child.pid, true)
		fp.child = {}
	}
}

filter_proc_stop :: proc(fp: ^Filter_Proc) {
	if fp.child.pid != 0 {
		prim.child_close(&fp.child)
		prim.reap(fp.child.pid, true)
		fp.child = {}
	}
}

@(private)
Pkt_Emit :: struct {
	fd: prim.Fd,
}

@(private)
filter_via_process :: proc(m: ^Mount, fp: ^Filter_Proc, cmd: Filter_Cmd, rel: string, in_: Filter_Input, out: io.Stream) -> (ok: bool, handled: bool) {
	if fp.broken {
		return false, true
	}
	if !fp.started && !filter_proc_start(m, fp) {
		return false, true
	}
	if cmd not_in fp.caps {
		return false, false
	}
	w := fp.child.stdin
	r := fp.child.stdout
	verb := "command=clean\n" if cmd == .Clean else "command=smudge\n"
	pb := strings.builder_make(context.temp_allocator)
	strings.write_string(&pb, "pathname=")
	strings.write_string(&pb, rel)
	strings.write_byte(&pb, '\n')
	if !pkt_text(w, verb) || !pkt_text(w, strings.to_string(pb)) || !pkt_flush(w) {
		filter_proc_kill(fp)
		return false, true
	}
	em := Pkt_Emit{w}
	if !feed_input(in_, proc(data: rawptr, chunk: []u8) -> bool {
			return pkt_write((^Pkt_Emit)(data).fd, chunk)
		}, &em) || !pkt_flush(w) {
		filter_proc_kill(fp)
		return false, true
	}
	status, sok := pkt_read_status(r)
	if !sok {
		filter_proc_kill(fp)
		return false, true
	}
	if status == "abort" {
		fp.caps -= {cmd}
		return false, true
	}
	if status != "success" {
		return false, true
	}
	buf: [PKT_MAX + 4]u8
	for {
		p, flush, pok := pkt_read(r, &buf)
		if !pok {
			filter_proc_kill(fp)
			return false, true
		}
		if flush {
			break
		}
		if _, werr := io.write(out, p); werr != nil {
			filter_proc_kill(fp)
			return false, true
		}
	}
	final, fok := pkt_read_status(r)
	if !fok {
		filter_proc_kill(fp)
		return false, true
	}
	if final == "abort" {
		fp.caps -= {cmd}
		return false, true
	}
	return final == "" || final == "success", true
}

@(private)
Oneshot_Writer :: struct {
	in_: Filter_Input,
	fd:  prim.Fd,
	ok:  bool,
}

@(private)
filter_oneshot :: proc(m: ^Mount, cmd_line: string, rel: string, in_: Filter_Input, out: io.Stream) -> bool {
	argv := filter_argv(cmd_line, rel, context.temp_allocator)
	child, err := prim.spawn(argv, m.root, filter_env(context.temp_allocator), false, {.Stdin, .Stdout})
	if err != .None {
		return false
	}
	ow := new(Oneshot_Writer, runtime.heap_allocator())
	ow^ = {in_ = in_, fd = child.stdin}
	th := thread.create_and_start_with_data(ow, proc(data: rawptr) {
		w := (^Oneshot_Writer)(data)
		w.ok = feed_input(w.in_, proc(d: rawptr, chunk: []u8) -> bool {
			return child_write_all((^Oneshot_Writer)(d).fd, chunk)
		}, w)
		prim.close(w.fd)
	}, context)
	child.stdin = prim.INVALID_FD
	ok := th != nil
	buf: [PKT_MAX]u8
	for ok {
		n, rerr := child_read(child.stdout, buf[:])
		if rerr != .None {
			ok = false
			break
		}
		if n <= 0 {
			break
		}
		if _, werr := io.write(out, buf[:n]); werr != nil {
			ok = false
		}
	}
	if th != nil {
		thread.join(th)
		thread.destroy(th)
		ok = ok && ow.ok
	} else {
		prim.close(ow.fd)
	}
	free(ow, runtime.heap_allocator())
	prim.child_close(&child)
	status, _, _ := prim.reap(child.pid, true)
	return ok && status.code == 0
}

filter_apply :: proc(m: ^Mount, driver: ^Filter_Driver, cmd: Filter_Cmd, rel: string, in_: Filter_Input, out: io.Stream) -> bool {
	if len(driver.process) > 0 {
		attr_begin(m)
		defer attr_end(m)
		fp := attr_filter_proc(m, driver)
		if fp == nil {
			return false
		}
		ok, _ := filter_via_process(m, fp, cmd, rel, in_, out)
		return ok
	}
	line := driver.clean if cmd == .Clean else driver.smudge
	if len(line) == 0 {
		return false
	}
	return filter_oneshot(m, line, rel, in_, out)
}

@(private)
Buf_Sink :: struct {
	buf: [dynamic]u8,
}

@(private)
buf_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Buf_Sink)(data)
	#partial switch mode {
	case .Write:
		append(&s.buf, ..p)
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}
