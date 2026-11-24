package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../capi/api"
import eng "../engine"
import "../fs"
import "../fstree"
import "../odb"
import "../prim"
import osync "../sync"

Relay_Main :: struct {
	loop:     prim.Loop,
	relay:    osync.Relay,
	al:       osync.Allow,
	ma:       osync.Member_Authorizer,
	ca:       osync.Cap_Authorizer,
	objects:  osync.Dir_Object_Store,
	sig:      Signals,
	stopping: bool,
	active:   bool,
	slow:     Slow_Objects,
}

OBJECTS_DELAY_MS :: #config(ONDB_OBJECTS_DELAY_MS, 0)
OBJECTS_BLOCK_MS :: #config(ONDB_OBJECTS_BLOCK_MS, 0)

Slow_Objects :: struct {
	inner: osync.Object_Store,
	loop:  ^prim.Loop,
}

Slow_Read :: struct {
	req:  ^osync.Object_Read,
	err:  osync.Error,
	data: []u8,
}

_slow_put :: proc(data: rawptr, key: string, bytes: []u8, done: osync.Storage_Done, ctx: rawptr) {
	so := (^Slow_Objects)(data)
	so.inner.put(so.inner.data, key, bytes, done, ctx)
}

_slow_read :: proc(data: rawptr, req: ^osync.Object_Read) {
	so := (^Slow_Objects)(data)
	q := new(Slow_Read)
	q.req = req
	inner := osync.Object_Read{key = req.key, off = req.off, n = req.n, ctx = q, done = proc(r: ^osync.Object_Read, err: osync.Error, bytes: []u8) {
		q := (^Slow_Read)(r.ctx)
		q.err = err
		q.data = make([]u8, len(bytes))
		copy(q.data, bytes)
	}}
	so.inner.read(so.inner.data, &inner)
	finish :: proc(l: ^prim.Loop, data: rawptr) {
		q := (^Slow_Read)(data)
		osync.object_read_done(q.req, q.err, q.data)
		delete(q.data)
		free(q)
	}
	if OBJECTS_BLOCK_MS > 0 {
		time.sleep(OBJECTS_BLOCK_MS * time.Millisecond)
		finish(so.loop, q)
	} else {
		prim.timer(so.loop, OBJECTS_DELAY_MS, q, finish)
	}
}

cmd_relay :: proc(a: ^Args) -> int {
	home := home_dir(context.temp_allocator)
	default_dir, _ := prim.path_join(context.temp_allocator, home, "relay")
	dir := flag_string(a, "dir", default_dir)
	if len(a.pos) > 0 {
		switch a.pos[0] {
		case "allow":
			if len(a.pos) < 2 {
				return usage_error("usage: 0ndb relay allow SPACE [QUOTA]")
			}
			if _, ok := prim.id_parse(a.pos[1]); !ok {
				return usage_error("SPACE is a 32-character space id")
			}
			prim.mkdir_all(prim.os_vfs(), dir, 0o700)
			path, _ := prim.path_join(context.temp_allocator, dir, "allow")
			old, _ := prim.read_file(prim.os_vfs(), path, context.temp_allocator)
			line := fmt.tprintf("%s %s\n", a.pos[1], a.pos[2] if len(a.pos) > 2 else "unlimited")
			data := strings.concatenate({string(old), line}, context.temp_allocator)
			if prim.replace_atomic(prim.os_vfs(), path, transmute([]u8)data) != .None {
				return report_error(.Io, "cannot write %s", path)
			}
			fmt.printfln("allowed %s", a.pos[1])
			return 0
		case "key":
			r: osync.Relay
			l: prim.Loop
			prim.loop_init(&l)
			defer prim.loop_destroy(&l)
			cfg := osync.relay_config(dir)
			cfg.open = true
			if err := osync.relay_init(&r, &l, cfg); err != .None {
				return report_error(.Busy if err == .Busy else .Io, "cannot open the relay in %s", dir)
			}
			k := osync.relay_public_key(&r)
			osync.relay_destroy(&r)
			fmt.println(hex_of(k[:]))
			return 0
		case:
			return usage_error("usage: 0ndb relay [allow SPACE [QUOTA] | key] [--listen ADDR,...] [--dir DIR] [--open] [--quota BYTES] [--objects DIR [--flush-ms MS] [--flush-max-ms MS] [--flush-mb MB] [--hot-kb KB]]")
		}
	}
	m := new(Relay_Main)
	ignore_broken_pipes()
	if prim.loop_init(&m.loop) != .None {
		return report_error(.Io, "cannot create the event loop")
	}
	quota: i64
	if q, ok := flag_value(a, "quota"); ok {
		v, qok := osync.parse_size(q)
		if !qok {
			return usage_error("--quota takes a size such as 10G or unlimited")
		}
		quota = v
	}
	if prim.mkdir_all(prim.os_vfs(), dir, 0o700) != .None {
		return report_error(.Io, "cannot create %s", dir)
	}
	allow, _ := prim.path_join(context.temp_allocator, dir, "allow")
	osync.allow_init(&m.al, prim.os_vfs(), strings.clone(allow))
	mdir, _ := prim.path_join(context.temp_allocator, dir, "members")
	if err := osync.member_authorizer_init(&m.ma, prim.os_vfs(), mdir, {}, flag_bool(a, "open"), quota, {}, &m.al); err != .None {
		return report_error(.Io, "cannot open %s", mdir)
	}
	osync.cap_authorizer_init(&m.ca, osync.member_authorizer(&m.ma), quota)
	m.ca.issuer_data = &m.ma
	m.ca.issuer_ok = proc(data: rawptr, space: prim.Id, issuer: osync.Public_Key) -> bool {
		return osync.member_authorizer_active((^osync.Member_Authorizer)(data), osync.Space_Id(space), issuer)
	}
	cfg := osync.relay_config(dir)
	cfg.pack = true
	cfg.kernel_tls = ODIN_OS == .Linux
	cfg.open = flag_bool(a, "open")
	cfg.default_quota = quota
	cfg.authorizer = osync.cap_authorizer(&m.ca)
	if odir, ok := flag_value(a, "objects"); ok {
		if prim.mkdir_all(prim.os_vfs(), odir, 0o700) != .None {
			return report_error(.Io, "cannot create %s", odir)
		}
		m.objects = osync.Dir_Object_Store{vfs = prim.os_vfs(), root = strings.clone(odir)}
		cfg.objects = osync.dir_object_store(&m.objects)
		when OBJECTS_DELAY_MS > 0 || OBJECTS_BLOCK_MS > 0 {
			m.slow = Slow_Objects{inner = cfg.objects, loop = &m.loop}
			cfg.objects = osync.Object_Store{data = &m.slow, put = _slow_put, read = _slow_read}
		}
		if v, vok := flag_value(a, "flush-ms"); vok {
			n, nok := strconv.parse_i64(v)
			if !nok || n <= 0 {
				return usage_error("--flush-ms takes a positive number of milliseconds")
			}
			cfg.flush_ms = n
		}
		if v, vok := flag_value(a, "flush-max-ms"); vok {
			n, nok := strconv.parse_i64(v)
			if !nok || n <= 0 {
				return usage_error("--flush-max-ms takes a positive number of milliseconds")
			}
			cfg.flush_max_ms = n
		}
		if v, vok := flag_value(a, "flush-mb"); vok {
			n, nok := strconv.parse_i64(v)
			if !nok || n <= 0 {
				return usage_error("--flush-mb takes a positive number of MiB")
			}
			cfg.flush_bytes = n << 20
		}
		if v, vok := flag_value(a, "hot-kb"); vok {
			n, nok := strconv.parse_i64(v)
			if !nok {
				return usage_error("--hot-kb takes a number of KiB, or -1 to keep everything in the pack")
			}
			cfg.hot = n << 10 if n > 0 else n
		}
	}
	if ierr := osync.relay_init(&m.relay, &m.loop, cfg); ierr != .None {
		if ierr == .Busy {
			return report_error(.Busy, "another relay is running in %s", dir)
		}
		return report_error(.Io, "cannot open the relay in %s (%v)", dir, ierr)
	}
	osync.member_authorizer_set_storage(&m.ma, osync.relay_storage(&m.relay))
	listens := strings.split(flag_string(a, "listen", "127.0.0.1:7420"), ",", context.temp_allocator)
	sock, _ := prim.path_join(context.temp_allocator, dir, "relay.sock")
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..listens)
	append(&all, strings.concatenate({"unix:", sock}, context.temp_allocator))
	for l in all {
		if len(l) == 0 {
			continue
		}
		if err := osync.relay_listen(&m.relay, l); err != .None {
			osync.relay_destroy(&m.relay)
			return report_error(.Io, "cannot listen on %s (%v)", l, err)
		}
	}
	if signals_open(&m.sig) {
		prim.watch(&m.loop, m.sig.fd, {.Read}, m, proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
			x := (^Relay_Main)(data)
			for {
				if _, ok := signals_read(&x.sig); !ok {
					break
				}
				x.stopping = true
			}
		})
	}
	k := osync.relay_public_key(&m.relay)
	fmt.printfln("0ndb relay %s on %s", VERSION, strings.join(all[:], " ", context.temp_allocator))
	fmt.printfln("relay key %s", hex_of(k[:]))
	fmt.printfln("mode %s · kernel tls %v · storage pack in %s", "open" if cfg.open else "allow-list", cfg.kernel_tls, dir)
	if cfg.objects.put != nil {
		fmt.printfln("object store %s · one write per space after %d ms quiet, %d ms at most, or %d MiB · pack keeps %d KiB per stream", m.objects.root, cfg.flush_ms if cfg.flush_ms > 0 else osync.TIER_WINDOW_DEFAULT, cfg.flush_max_ms if cfg.flush_max_ms > 0 else max(osync.TIER_MAX_DEFAULT, cfg.flush_ms), (cfg.flush_bytes if cfg.flush_bytes > 0 else osync.TIER_BYTES_DEFAULT) >> 20, (cfg.hot if cfg.hot > 0 else osync.TIER_HOT_DEFAULT) >> 10 if cfg.hot >= 0 else -1)
	}
	os.flush(os.stdout)
	m.active = true
	for !m.stopping {
		if m.active && prim.loop_idle(&m.loop) && osync.relay_quiet(&m.relay) {
			m.active = false
			idle_release()
		}
		if prim.loop_step(&m.loop, true) != .None {
			break
		}
		m.active = true
	}
	st := osync.relay_stats(&m.relay)
	osync.relay_destroy(&m.relay)
	osync.cap_authorizer_destroy(&m.ca)
	osync.member_authorizer_destroy(&m.ma)
	osync.allow_destroy(&m.al)
	signals_close(&m.sig)
	prim.loop_destroy(&m.loop)
	fmt.printfln("relay stopped (%d appends, %s in, %s out, %d object-store writes, %s)", st.appends, bytes_human(i64(st.bytes_in)), bytes_human(i64(st.bytes_out)), m.objects.puts, bytes_human(i64(m.objects.bytes)))
	if m.objects.gets > 0 {
		fmt.printfln("object-store reads %d (%s)", m.objects.gets, bytes_human(i64(m.objects.get_bytes)))
	}
	return 0
}

Verify_Node :: enum u8 {
	Text,
	Symlink,
	Opaque,
}

verify_node :: proc(c: ^api.Call, m: ^api.Mounted, rel, disk: string, st: prim.Stat) -> (kind: Verify_Node, ok: bool) {
	hist, herr := eng.tree_history(c.api.e, m.object)
	if herr != .None {
		return .Text, false
	}
	defer eng.tree_release(c.api.e, m.object)
	snap := fstree.current(&hist.tree)
	id, found, ferr := fstree.lookup(&snap, rel)
	if ferr != nil || !found {
		return .Text, false
	}
	info, iok, ierr := fstree.info(&snap, id, context.temp_allocator)
	if ierr != nil || !iok {
		return .Text, false
	}
	if info.kind == .Symlink {
		if st.kind != .Symlink {
			return .Symlink, false
		}
		lbuf: [prim.PATH_MAX]u8
		n, lerr := prim.readlink(prim.os_vfs(), disk, lbuf[:])
		return .Symlink, lerr == .None && info.target == string(lbuf[:n])
	}
	if .Opaque not_in info.flags {
		return .Text, true
	}
	reg, has, berr := fs.history_blob(hist, id)
	if berr != .None || !has || st.kind != .File {
		return .Opaque, false
	}
	oid, oerr := odb.hash_file(prim.os_vfs(), disk)
	return .Opaque, oerr == .None && oid == odb.Oid(reg.oid)
}

op_verify :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	root := trim_slash(api.a_str(c, "root"))
	m: ^api.Mounted
	for x in c.api.mounts {
		if fs.path_same(x.root, root) {
			m = x
		}
	}
	if m == nil {
		return .Not_Found
	}
	if fs.mount_sync(m.mount) != .None {
		return .Io
	}
	eng.flush(c.api.e)
	files := 0
	bad := make([dynamic]string, context.temp_allocator)
	walk :: proc(c: ^api.Call, m: ^api.Mounted, rel: string, files: ^int, bad: ^[dynamic]string) -> api.Status {
		names, err := eng.tree_list(c.api.e, m.object, rel, context.temp_allocator)
		if err == .Not_Found {
			return .Ok
		}
		if err != .None {
			return api.status_of(err)
		}
		for n in names {
			p := n if len(rel) == 0 else strings.concatenate({rel, "/", n}, context.temp_allocator)
			disk, _ := prim.path_join(context.temp_allocator, m.root, p)
			st, serr := prim.lstat(prim.os_vfs(), disk)
			if serr == .None && st.kind == .Dir {
				walk(c, m, p, files, bad) or_return
				continue
			}
			want, rerr := eng.tree_read(c.api.e, m.object, p, context.temp_allocator)
			if rerr != .None {
				continue
			}
			files^ += 1
			if serr == .None {
				if kind, same := verify_node(c, m, p, disk, st); kind != .Text {
					if !same {
						append(bad, p)
					}
					continue
				}
			}
			got, derr := prim.read_file(prim.os_vfs(), disk, context.temp_allocator)
			if derr != .None {
				append(bad, p)
			} else if string(got) != string(want) {
				clean, cok := fs.eol_clean(m.mount, p, got)
				if !cok || string(clean) != string(want) {
					append(bad, p)
				}
			}
		}
		return .Ok
	}
	walk(c, m, "", &files, &bad) or_return
	api.o_int(o, "files", files)
	api.o_arr(o, "mismatches", len(bad))
	for b in bad {
		api.o_str(o, "", b)
	}
	api.o_end(o)
	return .Ok
}
