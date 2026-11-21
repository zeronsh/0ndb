package engine

import "core:crypto/blake2b"
import "../fs"
import "../http"
import "../prim"

@(private)
Plug_State :: struct {
	curl:      http.Curl,
	curl_on:   bool,
	reg:       fs.Registry,
	reg_on:    bool,
	mounts:    [dynamic]^Mounted,
}

@(private)
Mounted :: struct {
	object: Object,
	mount:  fs.Mount,
}

default_spawner :: proc "contextless" () -> Spawner {
	return Spawner{spawn = _default_spawn}
}

@(private)
_default_spawn :: proc(data: rawptr, argv: []string, cwd: string, env: []string, new_group: bool) -> (prim.Child, prim.Error) {
	return prim.spawn(argv, cwd, env, new_group)
}

spawner :: proc(e: ^Engine) -> Spawner {
	if e.cfg.spawner.spawn != nil {
		return e.cfg.spawner
	}
	return default_spawner()
}

http_client :: proc(e: ^Engine) -> (c: ^http.Client, err: Error) {
	if e.cfg.http.start != nil {
		return &e.cfg.http, .None
	}
	if !e.plug.curl_on {
		if !http.curl_init(&e.plug.curl, e.loop, e.allocator) {
			return nil, .Unsupported
		}
		e.plug.curl_on = true
		e.cfg.http = http.curl_client(&e.plug.curl)
	}
	return &e.cfg.http, .None
}

registry :: proc(e: ^Engine) -> (reg: ^fs.Registry, err: Error) {
	if !e.plug.reg_on {
		run := _join(context.temp_allocator, e.dir, "run") or_return
		_ferr(fs.registry_init(&e.plug.reg, e.base, run, e.allocator)) or_return
		e.plug.reg_on = true
		if e.cfg.write_observer.start != nil {
			if oerr := fs.registry_set_observer(&e.plug.reg, e.cfg.write_observer); oerr != .None {
				_log(e, .Warn, "write observer unavailable")
			}
		}
		if aerr := fs.registry_attach(&e.plug.reg, e.loop, _on_mount_ready, e); aerr != .None {
			return nil, _ferr(aerr)
		}
		e.plug.mounts = make([dynamic]^Mounted, e.allocator)
	}
	return &e.plug.reg, .None
}

tree_mount :: proc(e: ^Engine, o: Object, root: string, opts := fs.DEFAULT_MOUNT) -> (m: ^fs.Mount, err: Error) {
	reg := registry(e) or_return
	hist := tree_history(e, o) or_return
	defer if err != .None {
		tree_release(e, o)
	}
	db := device_odb(e) or_return
	mid := _mount_id(o.id, root)
	hx := prim.id_hex(mid)
	state := _join(context.temp_allocator, e.dir, "worktrees", string(hx[:])) or_return
	_perr(prim.mkdir_all(e.base, state, 0o700)) or_return
	mt := new(Mounted, e.allocator)
	mt.object = o
	if merr := fs.mount_open(&mt.mount, reg, hist, db, mid, root, state, e.self, opts, e.allocator); merr != .None {
		free(mt, e.allocator)
		return nil, _ferr(merr)
	}
	append(&e.plug.mounts, mt)
	return &mt.mount, .None
}

tree_unmount :: proc(e: ^Engine, m: ^fs.Mount) {
	for mt, i in e.plug.mounts {
		if &mt.mount == m {
			fs.mount_close(&mt.mount)
			tree_release(e, mt.object)
			ordered_remove(&e.plug.mounts, i)
			free(mt, e.allocator)
			return
		}
	}
}

@(private)
_mount_id :: proc(tree: prim.Id, root: string) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	t := tree
	blake2b.update(&ctx, t[:])
	blake2b.update(&ctx, transmute([]u8)root)
	blake2b.final(&ctx, id[:])
	return
}

@(private)
_on_mount_ready :: proc(m: ^fs.Mount, data: rawptr) {
	e := (^Engine)(data)
	for mt in e.plug.mounts {
		if &mt.mount == m {
			touched(e, mt.object)
			return
		}
	}
}

@(private)
_mounts_commit :: proc(e: ^Engine) {
	if !e.plug.reg_on {
		return
	}
	for mt in e.plug.mounts {
		if h, ok := e.handles[mt.object.id]; ok && h.w_open && _own_len(h) > h.published {
			h.local = true
		}
	}
}

@(private)
_plugs_close :: proc(e: ^Engine) {
	if e.plug.reg_on {
		for mt in e.plug.mounts {
			fs.mount_close(&mt.mount)
			free(mt, e.allocator)
		}
		delete(e.plug.mounts)
		fs.registry_destroy(&e.plug.reg)
		e.plug.reg_on = false
	}
	if e.plug.curl_on {
		http.curl_destroy(&e.plug.curl)
		e.plug.curl_on = false
	}
}
