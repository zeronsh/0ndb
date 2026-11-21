package main

import "core:encoding/json"
import "core:os"
import "core:strconv"
import "../capi/api"
import "../prim"

Client :: struct {
	fd:   Sock,
	rbuf: [dynamic]u8,
	tag:  u64,
}

Reply :: struct {
	status:  api.Status,
	payload: string,
	value:   json.Value,
}

socket_path :: proc(allocator := context.allocator) -> string {
	dir, err := prim.runtime_dir(context.temp_allocator)
	if err != .None {
		fail(.Io, "cannot determine the runtime directory")
	}
	p, _ := prim.path_join(allocator, dir, "daemon.sock")
	return p
}

home_dir :: proc(allocator := context.allocator) -> string {
	d, err := prim.data_dir(allocator)
	if err != .None {
		fail(.Io, "cannot determine the data directory (set ONDB_HOME)")
	}
	return d
}

client_connect :: proc(c: ^Client, autostart := true) -> bool {
	path := socket_path(context.temp_allocator)
	fd, ok := sock_connect(path)
	if !ok && autostart {
		if !_spawn_daemon() {
			return false
		}
		fd, ok = sock_connect(path)
	}
	if !ok {
		return false
	}
	c.fd = fd
	c.rbuf = make([dynamic]u8)
	hello: [5]u8
	copy(hello[:4], MAGIC)
	hello[4] = PROTO_VERSION
	return _write_all(c.fd, hello[:])
}

client_close :: proc(c: ^Client) {
	if c.fd != NO_SOCK {
		sock_close(c.fd)
		c.fd = NO_SOCK
	}
	delete(c.rbuf)
}

@(private)
_spawn_daemon :: proc() -> bool {
	exe, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil {
		return false
	}
	home := home_dir(context.temp_allocator)
	prim.mkdir_all(prim.os_vfs(), home, 0o700)
	log_path, _ := prim.path_join(context.temp_allocator, home, "daemon.log")
	return spawn_daemon(exe, log_path)
}

@(private)
_write_all :: proc(fd: Sock, data: []u8) -> bool {
	return sock_write_all(fd, data)
}

client_send :: proc(c: ^Client, kind: Frame_Kind, parts: ..[]u8) -> bool {
	buf := make([dynamic]u8, context.temp_allocator)
	frame_put(&buf, kind, ..parts)
	return _write_all(c.fd, buf[:])
}

client_read :: proc(c: ^Client, timeout_ms: i64 = -1) -> (kind: Frame_Kind, payload: []u8, ok: bool) {
	for {
		k, p, used, have, bad := frame_next(c.rbuf[:])
		if bad {
			return .None, nil, false
		}
		if have {
			out := make([]u8, len(p), context.temp_allocator)
			copy(out, p)
			remove_range(&c.rbuf, 0, used)
			return k, out, true
		}
		if timeout_ms >= 0 && !sock_wait(c.fd, timeout_ms) {
			return .None, nil, false
		}
		buf: [65536]u8
		n, st := sock_read(c.fd, buf[:])
		if st == .Again {
			continue
		}
		if st != .Ok {
			return .None, nil, false
		}
		append(&c.rbuf, ..buf[:n])
	}
}

client_call :: proc(c: ^Client, req: string, timeout_ms: i64 = 0) -> Reply {
	c.tag += 1
	tag := u64_bytes(c.tag)
	flags := [1]u8{1}
	to: [8]u8
	prim.put_u64le(to[:], u64(timeout_ms))
	if !client_send(c, .Call, tag[:], flags[:], to[:], transmute([]u8)req) {
		fail(.Daemon, "lost the connection to the daemon")
	}
	for {
		k, p, ok := client_read(c)
		if !ok {
			fail(.Daemon, "lost the connection to the daemon")
		}
		if k != .Result || len(p) < 9 || prim.get_u64le(p[:8]) != c.tag {
			continue
		}
		r := Reply{status = api.Status(p[8]), payload = string(p[9:])}
		v, err := json.parse(p[9:], json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if err == .None {
			r.value = v
		}
		return r
	}
}

client_subscribe :: proc(c: ^Client, req: string) -> u64 {
	c.tag += 1
	tag := u64_bytes(c.tag)
	flags := [1]u8{1}
	if !client_send(c, .Subscribe, tag[:], flags[:], transmute([]u8)req) {
		fail(.Daemon, "lost the connection to the daemon")
	}
	return c.tag
}

Request :: struct {
	buf: [dynamic]u8,
}

req_begin :: proc(op: string) -> Request {
	r := Request{buf = make([dynamic]u8, context.temp_allocator)}
	append(&r.buf, `{"op":`)
	api.json_string(&r.buf, op)
	return r
}

req_str :: proc(r: ^Request, key: string, v: string) {
	append(&r.buf, ',')
	api.json_string(&r.buf, key)
	append(&r.buf, ':')
	api.json_string(&r.buf, v)
}

req_opt :: proc(r: ^Request, key: string, v: string) {
	if len(v) > 0 {
		req_str(r, key, v)
	}
}

req_int :: proc(r: ^Request, key: string, v: i64) {
	append(&r.buf, ',')
	api.json_string(&r.buf, key)
	b: [32]u8
	put(&r.buf, ":", strconv.write_int(b[:], v, 10))
}

req_bool :: proc(r: ^Request, key: string, v: bool) {
	append(&r.buf, ',')
	api.json_string(&r.buf, key)
	append(&r.buf, ":true" if v else ":false")
}

req_raw :: proc(r: ^Request, key: string, raw: string) {
	append(&r.buf, ',')
	api.json_string(&r.buf, key)
	put(&r.buf, ":", raw)
}

req_end :: proc(r: ^Request) -> string {
	append(&r.buf, '}')
	return string(r.buf[:])
}
