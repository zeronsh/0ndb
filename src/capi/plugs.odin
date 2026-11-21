package capi

import "base:runtime"
import "core:mem"
import "core:strings"
import "./api"
import eng "../engine"
import "../fs"
import "../http"
import "../prim"
import "../search"
import osync "../sync"

C_Stat :: struct {
	size:     i64,
	mode:     u32,
	kind:     u32,
	ino:      u64,
	dev:      u64,
	nlink:    u64,
	mtime_ns: i64,
	ctime_ns: i64,
}

C_Dirent :: struct {
	name:     cstring,
	name_len: uint,
	ino:      u64,
	kind:     u32,
}

C_Vfs :: struct {
	size:       u32,
	ud:         rawptr,
	open:       proc "c" (ud: rawptr, path: cstring, len: uint, flags: u32, mode: u32, fd: ^i32) -> i32,
	close:      proc "c" (ud: rawptr, fd: i32) -> i32,
	read_at:    proc "c" (ud: rawptr, fd: i32, buf: [^]u8, len: uint, off: i64, n: ^uint) -> i32,
	write_at:   proc "c" (ud: rawptr, fd: i32, src: [^]u8, len: uint, off: i64) -> i32,
	datasync:   proc "c" (ud: rawptr, fd: i32) -> i32,
	fullsync:   proc "c" (ud: rawptr, fd: i32) -> i32,
	truncate:   proc "c" (ud: rawptr, fd: i32, size: i64) -> i32,
	punch_hole: proc "c" (ud: rawptr, fd: i32, off: i64, size: i64) -> i32,
	lock:       proc "c" (ud: rawptr, fd: i32) -> i32,
	fstat:      proc "c" (ud: rawptr, fd: i32, st: ^C_Stat) -> i32,
	stat:       proc "c" (ud: rawptr, path: cstring, len: uint, follow: i32, st: ^C_Stat) -> i32,
	rename:     proc "c" (ud: rawptr, from: cstring, from_len: uint, to: cstring, to_len: uint) -> i32,
	unlink:     proc "c" (ud: rawptr, path: cstring, len: uint) -> i32,
	rmdir:      proc "c" (ud: rawptr, path: cstring, len: uint) -> i32,
	mkdir:      proc "c" (ud: rawptr, path: cstring, len: uint, mode: u32) -> i32,
	symlink:    proc "c" (ud: rawptr, target: cstring, target_len: uint, path: cstring, len: uint) -> i32,
	readlink:   proc "c" (ud: rawptr, path: cstring, len: uint, buf: [^]u8, cap: uint, n: ^uint) -> i32,
	fchmod:     proc "c" (ud: rawptr, fd: i32, mode: u32) -> i32,
	set_times:  proc "c" (ud: rawptr, path: cstring, len: uint, atime_ns: i64, mtime_ns: i64) -> i32,
	dir_open:   proc "c" (ud: rawptr, path: cstring, len: uint, dir: ^rawptr) -> i32,
	dir_next:   proc "c" (ud: rawptr, dir: rawptr, ent: ^C_Dirent) -> i32,
	dir_close:  proc "c" (ud: rawptr, dir: rawptr),
	caps:       proc "c" (ud: rawptr, fd: i32) -> u32,
}

C_Identity :: struct {
	id:   [16]u8,
	sign: [32]u8,
	box:  [32]u8,
}

C_Content_Key :: struct {
	key:   [32]u8,
	epoch: u32,
}

WRAP_LEN :: osync.WRAP_LEN

C_Keyring :: struct {
	size:     u32,
	ud:       rawptr,
	identity: proc "c" (ud: rawptr, out: ^C_Identity),
	sign:     proc "c" (ud: rawptr, msg: [^]u8, len: uint, sig: ^[64]u8) -> i32,
	wrap:     proc "c" (ud: rawptr, recipient: ^C_Identity, key: ^C_Content_Key, out: ^[WRAP_LEN]u8) -> i32,
	unwrap:   proc "c" (ud: rawptr, wrapped: [^]u8, len: uint, key: ^C_Content_Key) -> i32,
	verify:   proc "c" (ud: rawptr, signer: ^C_Identity, msg: [^]u8, len: uint, sig: [^]u8, sig_len: uint) -> i32,
}

C_Credentials :: struct {
	size:      u32,
	ud:        rawptr,
	available: proc "c" (ud: rawptr, space: ^[16]u8) -> i32,
	produce:   proc "c" (ud: rawptr, space: ^[16]u8, binding: [^]u8, binding_len: uint, out: [^]u8, cap: uint, len: ^uint) -> i32,
}

C_Peer :: struct {
	space:     [16]u8,
	relay:     cstring,
	relay_len: uint,
	relay_key: [32]u8,
}

C_Transport :: struct {
	size:  u32,
	ud:    rawptr,
	open:  proc "c" (ud: rawptr, h: ^Handle, link: u64, peer: ^C_Peer, conn: ^rawptr) -> i32,
	send:  proc "c" (ud: rawptr, conn: rawptr, data: [^]u8, len: uint, sent: ^uint) -> i32,
	close: proc "c" (ud: rawptr, conn: rawptr),
}

C_Clock :: struct {
	size:    u32,
	ud:      rawptr,
	mono_ns: proc "c" (ud: rawptr) -> i64,
	wall_ns: proc "c" (ud: rawptr) -> i64,
}

C_Random :: struct {
	size: u32,
	ud:   rawptr,
	fill: proc "c" (ud: rawptr, out: [^]u8, len: uint),
}

C_Child :: struct {
	pid:    i32,
	stdin:  i32,
	stdout: i32,
	stderr: i32,
	group:  i32,
}

SPAWN_NEW_GROUP :: u32(1)
SPAWN_OBSERVE :: u32(2)

C_Spawner :: struct {
	size:  u32,
	ud:    rawptr,
	spawn: proc "c" (ud: rawptr, argv: [^]cstring, argc: uint, cwd: cstring, env: [^]cstring, envc: uint, flags: u32, out: ^C_Child) -> i32,
}

C_Header :: struct {
	name:      cstring,
	name_len:  uint,
	value:     cstring,
	value_len: uint,
}

C_Slice :: struct {
	ptr: [^]u8,
	len: uint,
}

C_Http_Request :: struct {
	method:       cstring,
	method_len:   uint,
	url:          cstring,
	url_len:      uint,
	headers:      [^]C_Header,
	header_count: uint,
	body:         [^]C_Slice,
	body_count:   uint,
	body_len:     i64,
	streamed:     i32,
	version:      u32,
	connect_ms:   i64,
	stall_ms:     i64,
	timeout_ms:   i64,
	follow:       i32,
}

C_Http :: struct {
	size:   u32,
	ud:     rawptr,
	start:  proc "c" (ud: rawptr, h: ^Handle, id: u64, req: ^C_Http_Request) -> i32,
	cancel: proc "c" (ud: rawptr, id: u64),
	resume: proc "c" (ud: rawptr, id: u64),
}

C_Write_Observer :: struct {
	size:   u32,
	ud:     rawptr,
	start:  proc "c" (ud: rawptr, h: ^Handle) -> i32,
	stop:   proc "c" (ud: rawptr, h: ^Handle),
	writer: proc "c" (ud: rawptr, path: cstring, len: uint, pid: ^i32) -> i32,
}

C_Embedder :: struct {
	size:  u32,
	ud:    rawptr,
	dim:   u32,
	embed: proc "c" (ud: rawptr, kind: u32, text: [^]u8, len: uint, out: [^]f32, dim: uint) -> i32,
}

C_Search_Remote :: struct {
	size:   u32,
	ud:     rawptr,
	query:  proc "c" (ud: rawptr, h: ^Handle, id: u64, payload: [^]u8, len: uint) -> i32,
	cancel: proc "c" (ud: rawptr, h: ^Handle, id: u64),
}

C_Log :: struct {
	size:  u32,
	ud:    rawptr,
	write: proc "c" (ud: rawptr, level: i32, msg: cstring, len: uint),
}

Cred_Space :: struct {
	h:     ^Handle,
	space: [16]u8,
}

Http_Req :: struct {
	id:     u64,
	sink:   http.Sink,
	reader: http.Body_Reader,
}

Plugs :: struct {
	vfs:         C_Vfs,
	vfs_procs:   prim.Vfs_Procs,
	keyring:     C_Keyring,
	credentials: C_Credentials,
	cred_spaces: [dynamic]^Cred_Space,
	transport:   C_Transport,
	clock:       C_Clock,
	random:      C_Random,
	spawner:     C_Spawner,
	http:        C_Http,
	http_reqs:   [dynamic]Http_Req,
	http_next:   u64,
	observer:    C_Write_Observer,
	registry:    ^fs.Registry,
	embedder:    C_Embedder,
	log:         C_Log,
	remote:      C_Search_Remote,
	account:     Account_Plugs,
}

@(private)
_copy_table :: proc(dst: ^$T, src: ^T) -> bool {
	if src == nil {
		return false
	}
	if src.size < u32(offset_of(T, ud) + size_of(rawptr)) {
		return false
	}
	n := min(int(src.size), size_of(T))
	dst^ = {}
	mem.copy(dst, src, n)
	dst.size = u32(size_of(T))
	return true
}

@(private)
_has :: proc(cfg: ^Config, field: uintptr) -> bool {
	return uintptr(cfg.size) >= field + size_of(rawptr)
}

plugs_install :: proc(h: ^Handle, cfg: ^Config, ec: ^eng.Config) -> api.Status {
	p := &h.plugs
	p.cred_spaces = make([dynamic]^Cred_Space, h.allocator)
	p.http_reqs = make([dynamic]Http_Req, h.allocator)
	if _has(cfg, offset_of(Config, vfs)) && cfg.vfs != nil {
		if !_copy_table(&p.vfs, cfg.vfs) || !_vfs_complete(&p.vfs) {
			return .Invalid
		}
		p.vfs_procs = _VFS_PROCS
		ec.vfs = prim.Vfs{procs = &p.vfs_procs, data = &p.vfs}
	}
	if _has(cfg, offset_of(Config, keyring)) && cfg.keyring != nil {
		if !_copy_table(&p.keyring, cfg.keyring) || p.keyring.identity == nil || p.keyring.sign == nil || p.keyring.wrap == nil || p.keyring.unwrap == nil {
			return .Invalid
		}
		ec.keyring = osync.Keyring{data = &p.keyring, identity = _kr_identity, sign = _kr_sign, wrap = _kr_wrap, unwrap = _kr_unwrap, verify = _kr_verify if p.keyring.verify != nil else nil}
	}
	if _has(cfg, offset_of(Config, credentials)) && cfg.credentials != nil {
		if !_copy_table(&p.credentials, cfg.credentials) || p.credentials.available == nil || p.credentials.produce == nil {
			return .Invalid
		}
		ec.credentials = eng.Credentials_Source{data = h, produce = _cred_source}
	}
	if _has(cfg, offset_of(Config, transport)) && cfg.transport != nil {
		if !_copy_table(&p.transport, cfg.transport) || p.transport.open == nil || p.transport.send == nil || p.transport.close == nil {
			return .Invalid
		}
		ec.transport = eng.Transport{data = h, open = _tr_open, send = _tr_send, close = _tr_close}
	}
	if _has(cfg, offset_of(Config, clock)) && cfg.clock != nil {
		if !_copy_table(&p.clock, cfg.clock) {
			return .Invalid
		}
		ec.clock = prim.Clock{data = &p.clock, mono_ns = _clock_mono if p.clock.mono_ns != nil else nil, wall_ns = _clock_wall if p.clock.wall_ns != nil else nil}
	}
	if _has(cfg, offset_of(Config, random)) && cfg.random != nil {
		if !_copy_table(&p.random, cfg.random) || p.random.fill == nil {
			return .Invalid
		}
		ec.random = prim.Random{data = &p.random, fill = _random_fill}
	}
	if _has(cfg, offset_of(Config, spawner)) && cfg.spawner != nil {
		if !_copy_table(&p.spawner, cfg.spawner) || p.spawner.spawn == nil {
			return .Invalid
		}
		ec.spawner = eng.Spawner{data = &p.spawner, spawn = _spawn}
	}
	if _has(cfg, offset_of(Config, http)) && cfg.http != nil {
		if !_copy_table(&p.http, cfg.http) || p.http.start == nil || p.http.cancel == nil {
			return .Invalid
		}
		ec.http = http.Client{data = h, start = _http_start, cancel = _http_cancel, resume = _http_resume}
	}
	if _has(cfg, offset_of(Config, write_observer)) && cfg.write_observer != nil {
		if !_copy_table(&p.observer, cfg.write_observer) {
			return .Invalid
		}
		ec.write_observer = fs.Write_Observer{data = h, start = _obs_start, stop = _obs_stop, changed = _obs_changed if p.observer.writer != nil else nil}
	}
	if _has(cfg, offset_of(Config, embedder)) && cfg.embedder != nil {
		if !_copy_table(&p.embedder, cfg.embedder) || p.embedder.embed == nil || p.embedder.dim == 0 {
			return .Invalid
		}
		ec.embedder = search.Embedder{dim = int(p.embedder.dim), embed = _embed, data = &p.embedder}
	}
	if !account_plugs_setup(&p.account, cfg, ec) {
		return .Invalid
	}
	if _has(cfg, offset_of(Config, search_remote)) && cfg.search_remote != nil {
		if !_copy_table(&p.remote, cfg.search_remote) || p.remote.query == nil {
			return .Invalid
		}
		ec.search_remote = eng.Search_Remote{data = h, query = _remote_query, cancel = _remote_cancel}
	}
	if _has(cfg, offset_of(Config, log)) && cfg.log != nil {
		if !_copy_table(&p.log, cfg.log) || p.log.write == nil {
			return .Invalid
		}
		ec.log = eng.Log{data = &p.log, write = _log_write}
	}
	return .Ok
}

plugs_attach :: proc(h: ^Handle) {}

plugs_detach :: proc(h: ^Handle) {
	p := &h.plugs
	for r in p.http_reqs {
		if p.http.cancel != nil {
			p.http.cancel(p.http.ud, r.id)
		}
	}
	clear(&p.http_reqs)
}

plugs_destroy :: proc(h: ^Handle) {
	p := &h.plugs
	for c in p.cred_spaces {
		free(c, h.allocator)
	}
	delete(p.cred_spaces)
	delete(p.http_reqs)
}

@(private)
_cstr :: proc(s: string) -> (cstring, uint) {
	return strings.clone_to_cstring(s, context.temp_allocator), uint(len(s))
}

@(private)
_perr :: proc "contextless" (code: i32) -> prim.Error {
	if code <= 0 {
		return .None
	}
	if code > i32(max(prim.Error)) {
		return .Io
	}
	return prim.Error(code)
}

@(private)
_vfs_complete :: proc(v: ^C_Vfs) -> bool {
	return v.open != nil && v.close != nil && v.read_at != nil && v.write_at != nil && v.datasync != nil && v.fstat != nil && v.stat != nil && v.rename != nil && v.unlink != nil && v.mkdir != nil && v.dir_open != nil && v.dir_next != nil && v.dir_close != nil
}

@(private)
_stat_from :: proc "contextless" (s: C_Stat) -> prim.Stat {
	k := prim.File_Kind.Unknown
	if s.kind <= u32(max(prim.File_Kind)) {
		k = prim.File_Kind(s.kind)
	}
	return prim.Stat{size = s.size, mode = s.mode, kind = k, ino = s.ino, dev = s.dev, nlink = s.nlink, mtime_ns = s.mtime_ns, ctime_ns = s.ctime_ns}
}

@(private)
_VFS_PROCS := prim.Vfs_Procs {
	open = proc(data: rawptr, path: string, flags: prim.Open_Flags, mode: u32) -> (prim.Fd, prim.Error) {
		v := (^C_Vfs)(data)
		p, n := _cstr(path)
		fd: i32 = -1
		err := _perr(v.open(v.ud, p, n, u32(transmute(u8)flags), mode, &fd))
		return prim.Fd(fd), err
	},
	close = proc(data: rawptr, fd: prim.Fd) -> prim.Error {
		v := (^C_Vfs)(data)
		return _perr(v.close(v.ud, i32(fd)))
	},
	read_at = proc(data: rawptr, fd: prim.Fd, buf: []u8, off: i64) -> (int, prim.Error) {
		v := (^C_Vfs)(data)
		n: uint
		err := _perr(v.read_at(v.ud, i32(fd), raw_data(buf), uint(len(buf)), off, &n))
		return int(min(n, uint(len(buf)))), err
	},
	write_at = proc(data: rawptr, fd: prim.Fd, src: []u8, off: i64) -> prim.Error {
		v := (^C_Vfs)(data)
		return _perr(v.write_at(v.ud, i32(fd), raw_data(src), uint(len(src)), off))
	},
	datasync = proc(data: rawptr, fd: prim.Fd) -> prim.Error {
		v := (^C_Vfs)(data)
		return _perr(v.datasync(v.ud, i32(fd)))
	},
	fullsync = proc(data: rawptr, fd: prim.Fd) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.fullsync == nil {
			return _perr(v.datasync(v.ud, i32(fd)))
		}
		return _perr(v.fullsync(v.ud, i32(fd)))
	},
	truncate = proc(data: rawptr, fd: prim.Fd, size: i64) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.truncate == nil {
			return .Unsupported
		}
		return _perr(v.truncate(v.ud, i32(fd), size))
	},
	punch_hole = proc(data: rawptr, fd: prim.Fd, off: i64, size: i64) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.punch_hole == nil {
			return .Unsupported
		}
		return _perr(v.punch_hole(v.ud, i32(fd), off, size))
	},
	lock = proc(data: rawptr, fd: prim.Fd) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.lock == nil {
			return .None
		}
		return _perr(v.lock(v.ud, i32(fd)))
	},
	fstat = proc(data: rawptr, fd: prim.Fd) -> (prim.Stat, prim.Error) {
		v := (^C_Vfs)(data)
		st: C_Stat
		err := _perr(v.fstat(v.ud, i32(fd), &st))
		return _stat_from(st), err
	},
	stat = proc(data: rawptr, path: string, follow: bool) -> (prim.Stat, prim.Error) {
		v := (^C_Vfs)(data)
		p, n := _cstr(path)
		st: C_Stat
		err := _perr(v.stat(v.ud, p, n, 1 if follow else 0, &st))
		return _stat_from(st), err
	},
	rename = proc(data: rawptr, old: string, new: string) -> prim.Error {
		v := (^C_Vfs)(data)
		a, an := _cstr(old)
		b, bn := _cstr(new)
		return _perr(v.rename(v.ud, a, an, b, bn))
	},
	unlink = proc(data: rawptr, path: string) -> prim.Error {
		v := (^C_Vfs)(data)
		p, n := _cstr(path)
		return _perr(v.unlink(v.ud, p, n))
	},
	rmdir = proc(data: rawptr, path: string) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.rmdir == nil {
			return .Unsupported
		}
		p, n := _cstr(path)
		return _perr(v.rmdir(v.ud, p, n))
	},
	mkdir = proc(data: rawptr, path: string, mode: u32) -> prim.Error {
		v := (^C_Vfs)(data)
		p, n := _cstr(path)
		return _perr(v.mkdir(v.ud, p, n, mode))
	},
	symlink = proc(data: rawptr, target: string, path: string) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.symlink == nil {
			return .Unsupported
		}
		a, an := _cstr(target)
		b, bn := _cstr(path)
		return _perr(v.symlink(v.ud, a, an, b, bn))
	},
	readlink = proc(data: rawptr, path: string, buf: []u8) -> (int, prim.Error) {
		v := (^C_Vfs)(data)
		if v.readlink == nil {
			return 0, .Unsupported
		}
		p, n := _cstr(path)
		got: uint
		err := _perr(v.readlink(v.ud, p, n, raw_data(buf), uint(len(buf)), &got))
		return int(min(got, uint(len(buf)))), err
	},
	fchmod = proc(data: rawptr, fd: prim.Fd, mode: u32) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.fchmod == nil {
			return .Unsupported
		}
		return _perr(v.fchmod(v.ud, i32(fd), mode))
	},
	set_times = proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> prim.Error {
		v := (^C_Vfs)(data)
		if v.set_times == nil {
			return .Unsupported
		}
		p, n := _cstr(path)
		return _perr(v.set_times(v.ud, p, n, atime_ns, mtime_ns))
	},
	dir_open = proc(data: rawptr, d: ^prim.Dir, path: string) -> prim.Error {
		v := (^C_Vfs)(data)
		p, n := _cstr(path)
		handle: rawptr
		err := _perr(v.dir_open(v.ud, p, n, &handle))
		if err == .None {
			d.handle = handle
			d.fd = prim.INVALID_FD
		}
		return err
	},
	dir_next = proc(data: rawptr, d: ^prim.Dir) -> (prim.Dir_Entry, bool, prim.Error) {
		v := (^C_Vfs)(data)
		ent: C_Dirent
		r := v.dir_next(v.ud, d.handle, &ent)
		if r < 0 {
			return {}, false, _perr(-r)
		}
		if r == 0 {
			return {}, false, .None
		}
		k := prim.File_Kind.Unknown
		if ent.kind <= u32(max(prim.File_Kind)) {
			k = prim.File_Kind(ent.kind)
		}
		name := strings.string_from_ptr((^u8)(ent.name), int(ent.name_len)) if ent.name != nil else ""
		return prim.Dir_Entry{name = name, ino = ent.ino, kind = k}, true, .None
	},
	dir_close = proc(data: rawptr, d: ^prim.Dir) {
		v := (^C_Vfs)(data)
		if d.handle != nil {
			v.dir_close(v.ud, d.handle)
			d.handle = nil
		}
	},
	caps = proc(data: rawptr, fd: prim.Fd) -> prim.Vfs_Caps {
		v := (^C_Vfs)(data)
		if v.caps == nil {
			return {}
		}
		return transmute(prim.Vfs_Caps)u8(v.caps(v.ud, i32(fd)))
	},
}

@(private)
_id_to_c :: proc "contextless" (id: osync.Identity) -> (c: C_Identity) {
	c.id = ([16]u8)(id.id)
	c.sign = id.sign
	c.box = id.box
	return
}

@(private)
_kr_identity :: proc(data: rawptr) -> osync.Identity {
	k := (^C_Keyring)(data)
	c: C_Identity
	k.identity(k.ud, &c)
	return osync.Identity{id = prim.Id(c.id), sign = c.sign, box = c.box}
}

@(private)
_kr_sign :: proc(data: rawptr, msg: []u8, sig: ^[64]u8) -> osync.Error {
	k := (^C_Keyring)(data)
	return .None if k.sign(k.ud, raw_data(msg), uint(len(msg)), sig) == 0 else .Auth
}

@(private)
_kr_wrap :: proc(data: rawptr, recipient: ^osync.Identity, key: ^osync.Content_Key, out: ^[osync.WRAP_LEN]u8) -> osync.Error {
	k := (^C_Keyring)(data)
	r := _id_to_c(recipient^)
	ck := C_Content_Key{key = key.key, epoch = key.epoch}
	defer mem.zero_explicit(&ck, size_of(ck))
	return .None if k.wrap(k.ud, &r, &ck, out) == 0 else .Auth
}

@(private)
_kr_unwrap :: proc(data: rawptr, wrapped: []u8, key: ^osync.Content_Key) -> osync.Error {
	k := (^C_Keyring)(data)
	ck: C_Content_Key
	defer mem.zero_explicit(&ck, size_of(ck))
	if k.unwrap(k.ud, raw_data(wrapped), uint(len(wrapped)), &ck) != 0 {
		return .Auth
	}
	key.key = ck.key
	key.epoch = ck.epoch
	return .None
}

@(private)
_kr_verify :: proc(data: rawptr, signer: ^osync.Identity, msg: []u8, sig: []u8) -> bool {
	k := (^C_Keyring)(data)
	s := _id_to_c(signer^)
	return k.verify(k.ud, &s, raw_data(msg), uint(len(msg)), raw_data(sig), uint(len(sig))) == 0
}

@(private)
_cred_source :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	h := (^Handle)(data)
	p := &h.plugs
	sp := ([16]u8)(space)
	if p.credentials.available(p.credentials.ud, &sp) == 0 {
		return {}, false
	}
	for c in p.cred_spaces {
		if c.space == sp {
			return osync.Credentials{data = c, produce = _cred_produce}, true
		}
	}
	c := new(Cred_Space, h.allocator)
	c.h = h
	c.space = sp
	append(&p.cred_spaces, c)
	return osync.Credentials{data = c, produce = _cred_produce}, true
}

@(private)
_cred_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	c := (^Cred_Space)(data)
	p := &c.h.plugs
	buf: [osync.CREDENTIAL_MAX]u8
	n: uint
	if p.credentials.produce(p.credentials.ud, &c.space, raw_data(binding), uint(len(binding)), raw_data(buf[:]), uint(len(buf)), &n) != 0 {
		return .Auth
	}
	if n > uint(len(buf)) {
		return .Too_Large
	}
	append(out, ..buf[:n])
	mem.zero_explicit(&buf, size_of(buf))
	return .None
}

@(private)
_tr_open :: proc(data: rawptr, e: ^eng.Engine, link: eng.Link, peer: eng.Peer) -> (conn: rawptr, err: eng.Error) {
	h := (^Handle)(data)
	p := &h.plugs
	cp := C_Peer{space = ([16]u8)(peer.space), relay_key = peer.relay_public}
	cp.relay, cp.relay_len = _cstr(peer.relay)
	c: rawptr
	if st := p.transport.open(p.transport.ud, h, u64(link), &cp, &c); st != 0 {
		return nil, .Offline
	}
	return c, .None
}

@(private)
_tr_send :: proc(data: rawptr, conn: rawptr, bytes: []u8) -> (int, eng.Error) {
	h := (^Handle)(data)
	p := &h.plugs
	sent: uint
	st := p.transport.send(p.transport.ud, conn, raw_data(bytes), uint(len(bytes)), &sent)
	n := int(min(sent, uint(len(bytes))))
	switch st {
	case 0:
		return n, .None
	case i32(api.Status.Busy):
		return n, .Busy
	}
	return n, .Closed
}

@(private)
_tr_close :: proc(data: rawptr, conn: rawptr) {
	h := (^Handle)(data)
	p := &h.plugs
	p.transport.close(p.transport.ud, conn)
}

@(export, link_name = "ondb_link_up")
ondb_link_up :: proc "c" (h: ^Handle, link: u64, binding: [^]u8, len: uint) -> i32 {
	if h == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	b: []u8
	if binding != nil {
		b = binding[:len]
	}
	return i32(api.status_of(eng.link_up(&h.s.e, eng.Link(link), b)))
}

@(export, link_name = "ondb_link_input")
ondb_link_input :: proc "c" (h: ^Handle, link: u64, data: [^]u8, len: uint) -> i32 {
	if h == nil || (data == nil && len > 0) {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return i32(api.status_of(eng.link_input(&h.s.e, eng.Link(link), data[:len])))
}

@(export, link_name = "ondb_link_writable")
ondb_link_writable :: proc "c" (h: ^Handle, link: u64) {
	if h == nil {
		return
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	eng.link_writable(&h.s.e, eng.Link(link))
}

@(export, link_name = "ondb_link_down")
ondb_link_down :: proc "c" (h: ^Handle, link: u64) {
	if h == nil {
		return
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	eng.link_down(&h.s.e, eng.Link(link))
}

@(private)
_clock_mono :: proc(data: rawptr) -> i64 {
	c := (^C_Clock)(data)
	return c.mono_ns(c.ud)
}

@(private)
_clock_wall :: proc(data: rawptr) -> i64 {
	c := (^C_Clock)(data)
	return c.wall_ns(c.ud)
}

@(private)
_random_fill :: proc(data: rawptr, out: []u8) {
	r := (^C_Random)(data)
	r.fill(r.ud, raw_data(out), uint(len(out)))
}

@(private)
_spawn :: proc(data: rawptr, argv: []string, cwd: string, env: []string, new_group: bool) -> (prim.Child, prim.Error) {
	return spawn_with(data, argv, cwd, env, SPAWN_NEW_GROUP if new_group else 0)
}

spawn_with :: proc(data: rawptr, argv: []string, cwd: string, env: []string, flags: u32) -> (prim.Child, prim.Error) {
	s := (^C_Spawner)(data)
	av := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		av[i], _ = _cstr(a)
	}
	ev := make([]cstring, len(env) + 1, context.temp_allocator)
	for x, i in env {
		ev[i], _ = _cstr(x)
	}
	wd: cstring
	if len(cwd) > 0 {
		wd, _ = _cstr(cwd)
	}
	out := C_Child{pid = -1, stdin = -1, stdout = -1, stderr = -1}
	err := _perr(s.spawn(s.ud, raw_data(av), uint(len(argv)), wd, raw_data(ev), uint(len(env)), flags, &out))
	if err != .None {
		return {}, err
	}
	return prim.Child{pid = prim.Pid(out.pid), stdin = prim.Fd(out.stdin), stdout = prim.Fd(out.stdout), stderr = prim.Fd(out.stderr), group = out.group != 0}, .None
}

@(private)
_http_find :: proc(p: ^Plugs, id: u64) -> int {
	for r, i in p.http_reqs {
		if r.id == id {
			return i
		}
	}
	return -1
}

@(private)
_http_start :: proc(data: rawptr, req: ^http.Request, sink: http.Sink) -> (http.Id, http.Error) {
	h := (^Handle)(data)
	p := &h.plugs
	p.http_next += 1
	id := p.http_next
	cr: C_Http_Request
	cr.method, cr.method_len = _cstr(req.method)
	cr.url, cr.url_len = _cstr(req.url)
	hs := make([]C_Header, len(req.headers), context.temp_allocator)
	for x, i in req.headers {
		hs[i].name, hs[i].name_len = _cstr(x.name)
		hs[i].value, hs[i].value_len = _cstr(x.value)
	}
	cr.headers = raw_data(hs)
	cr.header_count = uint(len(hs))
	bs := make([]C_Slice, len(req.body), context.temp_allocator)
	for b, i in req.body {
		bs[i] = C_Slice{raw_data(b), uint(len(b))}
	}
	cr.body = raw_data(bs)
	cr.body_count = uint(len(bs))
	cr.body_len = req.body_len if req.reader.read != nil else i64(http.body_len(req.body))
	cr.streamed = 1 if req.reader.read != nil else 0
	cr.version = u32(req.version)
	cr.connect_ms = req.connect_ms
	cr.stall_ms = req.stall_ms
	cr.timeout_ms = req.timeout_ms
	cr.follow = 1 if req.follow else 0
	append(&p.http_reqs, Http_Req{id = id, sink = sink, reader = req.reader})
	if p.http.start(p.http.ud, h, id, &cr) != 0 {
		if i := _http_find(p, id); i >= 0 {
			unordered_remove(&p.http_reqs, i)
		}
		return 0, .Connect
	}
	return http.Id(id), .None
}

@(private)
_http_cancel :: proc(data: rawptr, id: http.Id) {
	h := (^Handle)(data)
	p := &h.plugs
	if i := _http_find(p, u64(id)); i >= 0 {
		unordered_remove(&p.http_reqs, i)
		p.http.cancel(p.http.ud, u64(id))
	}
}

@(private)
_http_resume :: proc(data: rawptr, id: http.Id) {
	h := (^Handle)(data)
	p := &h.plugs
	if p.http.resume != nil && _http_find(p, u64(id)) >= 0 {
		p.http.resume(p.http.ud, u64(id))
	}
}

@(export, link_name = "ondb_http_head")
ondb_http_head :: proc "c" (h: ^Handle, id: u64, status: i32, headers: [^]C_Header, count: uint) -> i32 {
	if h == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := &h.plugs
	i := _http_find(p, id)
	if i < 0 {
		return i32(api.Status.Not_Found)
	}
	hs := make([]http.Header, count, context.temp_allocator)
	for j in 0 ..< int(count) {
		x := headers[j]
		hs[j] = http.Header{name = strings.string_from_ptr((^u8)(x.name), int(x.name_len)), value = strings.string_from_ptr((^u8)(x.value), int(x.value_len))}
	}
	s := p.http_reqs[i].sink
	if s.head != nil {
		s.head(s.data, http.Id(id), int(status), hs)
	}
	return 0
}

@(export, link_name = "ondb_http_body")
ondb_http_body :: proc "c" (h: ^Handle, id: u64, chunk: [^]u8, len: uint) -> i32 {
	if h == nil || (chunk == nil && len > 0) {
		return -1
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := &h.plugs
	i := _http_find(p, id)
	if i < 0 {
		return -1
	}
	s := p.http_reqs[i].sink
	if s.body == nil {
		return 1
	}
	return 1 if s.body(s.data, http.Id(id), chunk[:len]) else 0
}

@(export, link_name = "ondb_http_done")
ondb_http_done :: proc "c" (h: ^Handle, id: u64, err: i32, detail: [^]u8, len: uint) {
	if h == nil {
		return
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p := &h.plugs
	i := _http_find(p, id)
	if i < 0 {
		return
	}
	s := p.http_reqs[i].sink
	unordered_remove(&p.http_reqs, i)
	e := http.Error.Other
	if err >= 0 && err <= i32(max(http.Error)) {
		e = http.Error(err)
	}
	d := ""
	if detail != nil {
		d = string(detail[:len])
	}
	if s.done != nil {
		s.done(s.data, http.Id(id), e, d)
	}
}

@(export, link_name = "ondb_http_read")
ondb_http_read :: proc "c" (h: ^Handle, id: u64, dst: [^]u8, cap: uint, n: ^uint) -> i32 {
	if h == nil || n == nil {
		return 3
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	n^ = 0
	p := &h.plugs
	i := _http_find(p, id)
	if i < 0 || p.http_reqs[i].reader.read == nil {
		return 3
	}
	r := p.http_reqs[i].reader
	got, st := r.read(r.data, http.Id(id), dst[:cap])
	n^ = uint(max(got, 0))
	return i32(st)
}

@(private)
_obs_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	h := (^Handle)(data)
	p := &h.plugs
	p.registry = reg
	if p.observer.start != nil && p.observer.start(p.observer.ud, h) != 0 {
		return .Unsupported
	}
	return .None
}

@(private)
_obs_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	h := (^Handle)(data)
	p := &h.plugs
	if p.observer.stop != nil {
		p.observer.stop(p.observer.ud, h)
	}
	p.registry = nil
}

@(private)
_scope_of :: proc(reg: ^fs.Registry, m: ^fs.Mount, pid: prim.Pid) -> ^fs.Scope {
	for i := len(reg.scopes) - 1; i >= 0; i -= 1 {
		s := reg.scopes[i]
		if s.closed || (m != nil && s.mount != m) {
			continue
		}
		for x in s.pids {
			if x == pid {
				return s
			}
		}
	}
	return nil
}

@(private)
_obs_changed :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	h := (^Handle)(data)
	p := &h.plugs
	abs := strings.concatenate({m.root, "/", rel}, context.temp_allocator)
	cp, n := _cstr(abs)
	pid: i32
	if p.observer.writer(p.observer.ud, cp, n, &pid) == 0 {
		return nil, false
	}
	s := _scope_of(m.reg, m, prim.Pid(pid))
	return s, true
}

@(export, link_name = "ondb_observed_write")
ondb_observed_write :: proc "c" (h: ^Handle, pid: i32, path: [^]u8, path_len: uint, closed: i32) -> i32 {
	if h == nil || path == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	reg := h.plugs.registry
	if reg == nil {
		return i32(api.Status.Closed)
	}
	abs := string(path[:path_len])
	best: ^fs.Mount
	for m in reg.mounts {
		r := m.root
		if strings.has_prefix(abs, r) && len(abs) > len(r) && abs[len(r)] == '/' && (best == nil || len(r) > len(best.root)) {
			best = m
		}
	}
	if best == nil {
		return i32(api.Status.Not_Found)
	}
	rel := abs[len(best.root) + 1:]
	if closed != 0 {
		fs.mount_closed(best, rel)
		return 0
	}
	fs.mount_mark_observed(best, rel, _scope_of(reg, best, prim.Pid(pid)))
	return 0
}

@(private)
_embed :: proc(data: rawptr, kind: u8, text: []u8, out: []f32) -> bool {
	e := (^C_Embedder)(data)
	return e.embed(e.ud, u32(kind), raw_data(text), uint(len(text)), raw_data(out), uint(len(out))) == 0
}

@(private)
_log_write :: proc(data: rawptr, level: eng.Log_Level, msg: string) {
	l := (^C_Log)(data)
	c, n := _cstr(msg)
	l.write(l.ud, i32(level), c, n)
}

@(private)
_remote_query :: proc(data: rawptr, e: ^eng.Engine, q: ^eng.Remote_Query) -> eng.Error {
	h := (^Handle)(data)
	b := eng.remote_query_encode(q, context.temp_allocator)
	if h.plugs.remote.query(h.plugs.remote.ud, h, q.id, raw_data(b), uint(len(b))) != 0 {
		return .Unsupported
	}
	return .None
}

@(private)
_remote_cancel :: proc(data: rawptr, e: ^eng.Engine, id: u64) {
	h := (^Handle)(data)
	if h.plugs.remote.cancel != nil {
		h.plugs.remote.cancel(h.plugs.remote.ud, h, id)
	}
}
