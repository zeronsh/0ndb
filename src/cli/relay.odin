package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "../capi/api"
import eng "../engine"
import "../fs"
import "../prim"
import osync "../sync"

Relay_Main :: struct {
	loop:     prim.Loop,
	relay:    osync.Relay,
	sa:       osync.Space_Authorizer,
	ca:       eng.Cap_Authorizer,
	sig:      Signals,
	stopping: bool,
	settle:   prim.Timer,
	settling: bool,
}

RELAY_SETTLE_MS :: 2000

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
			return usage_error("usage: 0ndb relay [allow SPACE [QUOTA] | key] [--listen ADDR,...] [--dir DIR] [--open] [--quota BYTES]")
		}
	}
	m := new(Relay_Main)
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
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
	if err := osync.space_authorizer_init(&m.sa, prim.os_vfs(), allow, flag_bool(a, "open"), quota); err != .None {
		return report_error(.Io, "cannot read %s", allow)
	}
	eng.cap_authorizer_init(&m.ca, osync.space_authorizer(&m.sa), quota)
	cfg := osync.relay_config(dir)
	cfg.pack = true
	cfg.kernel_tls = true
	cfg.open = flag_bool(a, "open")
	cfg.default_quota = quota
	cfg.authorizer = eng.cap_authorizer(&m.ca)
	if err := osync.relay_init(&m.relay, &m.loop, cfg); err != .None {
		if err == .Busy {
			return report_error(.Busy, "another relay is running in %s", dir)
		}
		return report_error(.Io, "cannot open the relay in %s (%v)", dir, err)
	}
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
	os.flush(os.stdout)
	for !m.stopping {
		if prim.loop_step(&m.loop, true) != .None {
			break
		}
		if m.settling {
			m.settling = false
			continue
		}
		if m.settle != 0 {
			prim.timer_cancel(&m.loop, m.settle)
		}
		m.settle = prim.timer(&m.loop, RELAY_SETTLE_MS, m, proc(l: ^prim.Loop, data: rawptr) {
			x := (^Relay_Main)(data)
			x.settle = 0
			x.settling = true
			idle_release()
		})
	}
	st := osync.relay_stats(&m.relay)
	osync.relay_destroy(&m.relay)
	eng.cap_authorizer_destroy(&m.ca)
	osync.space_authorizer_destroy(&m.sa)
	signals_close(&m.sig)
	prim.loop_destroy(&m.loop)
	fmt.printfln("relay stopped (%d appends, %s in, %s out)", st.appends, bytes_human(i64(st.bytes_in)), bytes_human(i64(st.bytes_out)))
	return 0
}

op_verify :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	root := trim_slash(api.a_str(c, "root"))
	m: ^api.Mounted
	for x in c.api.mounts {
		if x.root == root {
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
			got, derr := prim.read_file(prim.os_vfs(), disk, context.temp_allocator)
			if derr != .None || string(got) != string(want) {
				append(bad, p)
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
